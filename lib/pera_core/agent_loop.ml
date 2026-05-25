open Containers

(** {1 Hook context types} *)

type 'ctx should_stop_ctx = {
  message : Agent_types.agent_message;
  tool_results : Pera_types.Types.tool_result_content list;
  messages : Agent_types.agent_message list;
  tool_ctx : 'ctx;
}

type 'ctx prepare_ctx = {
  message : Agent_types.agent_message;
  tool_results : Pera_types.Types.tool_result_content list;
  messages : Agent_types.agent_message list;
  tool_ctx : 'ctx;
}

type 'ctx before_tool_call_ctx = {
  message : Agent_types.agent_message;
  tool_call : Pera_types.Types.tool_call;
  validated_args : Yojson.Safe.t;
  tool_ctx : 'ctx;
}

type 'ctx after_tool_call_ctx = {
  tool_call : Pera_types.Types.tool_call;
  result : Pera_types.Types.tool_result_content;
  tool_ctx : 'ctx;
}

(** {1 Loop configuration} *)

type 'ctx agent_loop_config = {
  model : Pera_types.Types.model;
  system : string;
  options : Pera_provider.Provider.simple_stream_options;
  stream_fn : Agent_types.stream_fn;
  convert_to_llm :
    Agent_types.agent_message list -> Pera_provider.Provider.message list;
  tool_ctx : 'ctx;
  tools : 'ctx Agent_types.tool list;
  tool_execution : [ `Sequential | `Parallel ];
  transform_context :
    (Agent_types.agent_message list -> Agent_types.agent_message list) option;
  get_api_key : (provider:string -> string option) option;
  before_tool_call :
    ('ctx before_tool_call_ctx -> Agent_types.before_tool_call_result) option;
  after_tool_call : ('ctx after_tool_call_ctx -> unit) option;
  should_stop_after_turn : ('ctx should_stop_ctx -> bool) option;
  prepare_next_turn :
    ('ctx prepare_ctx -> Agent_types.turn_update option) option;
  get_steering_messages : (unit -> Agent_types.agent_message list) option;
  get_follow_up_messages : (unit -> Agent_types.agent_message list) option;
}

(** {1 Helpers} *)

(** An empty assistant_message used as the initial partial state when streaming
    begins. *)
let empty_assistant_message =
  Pera_types.Types.
    {
      content = [];
      stop_reason = EndTurn;
      provenance = { api = ""; provider = ""; model = ""; error_message = None };
      usage =
        {
          input_tokens = 0;
          output_tokens = 0;
          cache_read_tokens = 0;
          cache_write_tokens = 0;
          cost_usd = None;
        };
    }

(** Extract the partial [assistant_message] carried by a streaming event. *)
let partial_of_event (event : Pera_types.Types.assistant_message_event) =
  match event with
  | AME_text_start { partial }
  | AME_text_delta { partial; _ }
  | AME_thinking_start { partial }
  | AME_thinking_delta { partial; _ }
  | AME_tool_call_start { partial; _ }
  | AME_tool_call_delta { partial; _ }
  | AME_tool_call_end { partial; _ }
  | AME_error { partial; _ } ->
      partial
  | AME_done { message } -> message

(** [stop_reason_is_terminal r] is [true] when [r] indicates a fatal stop that
    should terminate the whole run (Error or Aborted). *)
let stop_reason_is_terminal (stop_reason : Pera_types.Types.stop_reason) =
  match stop_reason with
  | Pera_types.Types.Error | Pera_types.Types.Aborted -> true
  | Pera_types.Types.EndTurn | Pera_types.Types.ToolUse
  | Pera_types.Types.MaxTokens | Pera_types.Types.StopSequence ->
      false

(** Push one event into the output stream. *)
let push_event out_stream event =
  Pera_provider.Event_stream.push out_stream event

(** Apply a [turn_update] to the mutable loop state refs. Any [None] field means
    "keep current value". *)
let apply_turn_update ~model_ref ~messages_ref
    (update : Agent_types.turn_update) =
  Option.iter (fun m -> model_ref := m) update.model;
  (* thinking flag update deferred to Stage 7 when options are fully wired *)
  ignore update.thinking;
  Option.iter (fun msgs -> messages_ref := msgs) update.messages

(** Build the provider context for one LLM call.

    Applies [transform_context] (if set) and then [convert_to_llm] to produce
    the provider-level message list. *)
let build_provider_context ~system ~transform_context ~convert_to_llm ~thinking
    ~tools messages =
  let transformed =
    match transform_context with None -> messages | Some f -> f messages
  in
  let provider_messages = convert_to_llm transformed in
  Pera_provider.Provider.
    { system; messages = provider_messages; tools; thinking }

(** Invoke [get_api_key] if set. The return value is not used by the loop; the
    call exists to satisfy provider contracts. *)
let invoke_get_api_key get_api_key =
  Option.iter (fun f -> ignore (f ~provider:"anthropic")) get_api_key

(** {1 Provider stream consumption} *)

(** Stream one turn from the provider into [out_stream].

    Emits [AE_message_start], one [AE_message_update] per event, and
    [AE_message_end]. Returns the final [assistant_message]. On a transport
    error the returned message carries [stop_reason = Error]. *)
let consume_provider_stream ~provider_stream out_stream =
  let partial_ref = ref empty_assistant_message in
  let emitted_start = ref false in
  let _iter_result =
    Pera_provider.Event_stream.iter provider_stream ~f:(fun event ->
        let partial = partial_of_event event in
        partial_ref := partial;
        let agent_msg =
          Agent_types.Real (Pera_provider.Provider.AssistantMessage partial)
        in
        if not !emitted_start then begin
          emitted_start := true;
          push_event out_stream
            (Agent_types.AE_message_start { message = agent_msg })
        end;
        push_event out_stream
          (Agent_types.AE_message_update { message = agent_msg; event }))
  in
  let stream_result = Pera_provider.Event_stream.result provider_stream in
  let final_msg =
    match stream_result with
    | Ok final -> final
    | Error _err -> { !partial_ref with stop_reason = Pera_types.Types.Error }
  in
  let final_agent_msg =
    Agent_types.Real (Pera_provider.Provider.AssistantMessage final_msg)
  in
  push_event out_stream
    (Agent_types.AE_message_end { message = final_agent_msg });
  final_msg

(** {1 Tool execution} *)

(** Extract all [AToolCall] blocks from an [assistant_message]. *)
let tool_calls_of_message (msg : Pera_types.Types.assistant_message) =
  List.filter_map
    (fun content ->
      match content with
      | Pera_types.Types.AToolCall tc -> Some tc
      | Pera_types.Types.AText _ | Pera_types.Types.AThinking _ -> None)
    msg.content

(** Determine whether the batch should run sequentially: config default is used
    unless any called tool has mode [\`Sequential], in which case the whole
    batch is forced sequential. *)
let effective_execution_mode config tool_calls =
  let any_sequential =
    List.exists
      (fun (tc : Pera_types.Types.tool_call) ->
        match
          List.find_opt
            (fun (t : 'ctx Agent_types.tool) -> String.equal t.name tc.name)
            config.tools
        with
        | Some tool -> (
            match tool.mode with `Sequential -> true | `Parallel -> false)
        | None -> false)
      tool_calls
  in
  if any_sequential then `Sequential else config.tool_execution

(** Execute a single tool call, performing validation, hook invocation, and
    error handling. Emits [AE_tool_execution_start] and [AE_tool_execution_end]
    events. Returns the [tool_result_content]. *)
let execute_one_tool ~config ~sw ~out_stream ~final_agent_msg
    (tc : Pera_types.Types.tool_call) =
  let tool_call_id = tc.id in
  let tool_name = tc.name in
  (* Step 1: look up tool by name *)
  let tool_opt =
    List.find_opt
      (fun (t : 'ctx Agent_types.tool) -> String.equal t.name tool_name)
      config.tools
  in
  match tool_opt with
  | None ->
      let content = `String (Printf.sprintf "Unknown tool: %s" tool_name) in
      let result =
        Pera_types.Types.{ tool_call_id; content; is_error = true }
      in
      push_event out_stream
        (Agent_types.AE_tool_execution_end
           { tool_call_id; tool_name; result = content; is_error = true });
      result
  | Some tool -> (
      (* Step 2: validate args *)
      let validated_args_result =
        Pera_provider.Json_schema.validate tool.schema tc.arguments
      in
      match validated_args_result with
      | Error err ->
          let content =
            `String (Printf.sprintf "Schema validation failed: %s" err)
          in
          let result =
            Pera_types.Types.{ tool_call_id; content; is_error = true }
          in
          push_event out_stream
            (Agent_types.AE_tool_execution_end
               { tool_call_id; tool_name; result = content; is_error = true });
          result
      | Ok () -> (
          (* Step 3: call before_tool_call if set *)
          let before_result =
            match config.before_tool_call with
            | None -> Agent_types.Allow
            | Some f ->
                f
                  {
                    message = final_agent_msg;
                    tool_call = tc;
                    validated_args = tc.arguments;
                    tool_ctx = config.tool_ctx;
                  }
          in
          match before_result with
          | Agent_types.Deny msg ->
              let content = `String msg in
              let result =
                Pera_types.Types.{ tool_call_id; content; is_error = true }
              in
              push_event out_stream
                (Agent_types.AE_tool_execution_end
                   {
                     tool_call_id;
                     tool_name;
                     result = content;
                     is_error = true;
                   });
              result
          | Agent_types.Allow ->
              (* Step 4: emit execution start *)
              push_event out_stream
                (Agent_types.AE_tool_execution_start
                   { tool_call_id; tool_name; args = tc.arguments });
              (* Step 5: execute the tool, catching exceptions *)
              let execute_result =
                match
                  Eio.Cancel.sub (fun cancel ->
                      tool.execute ~ctx:config.tool_ctx ~args:tc.arguments ~sw
                        ~cancel)
                with
                | Ok output ->
                    Agent_types.tool_output_to_result_content ~tool_call_id
                      ~is_error:false output
                | Error { message; _ } ->
                    let content = `String message in
                    Pera_types.Types.{ tool_call_id; content; is_error = true }
                | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                | exception exn ->
                    let content =
                      `String
                        (Printf.sprintf "Tool raised exception: %s"
                           (Printexc.to_string exn))
                    in
                    Pera_types.Types.{ tool_call_id; content; is_error = true }
              in
              let is_error = execute_result.Pera_types.Types.is_error in
              (* Step 7: call after_tool_call if set *)
              Option.iter
                (fun f ->
                  f
                    {
                      tool_call = tc;
                      result = execute_result;
                      tool_ctx = config.tool_ctx;
                    })
                config.after_tool_call;
              (* Step 8: emit execution end *)
              push_event out_stream
                (Agent_types.AE_tool_execution_end
                   {
                     tool_call_id;
                     tool_name;
                     result = execute_result.content;
                     is_error;
                   });
              execute_result))

(** Execute a list of tool calls sequentially, in source order. *)
let execute_tools_sequential ~config ~sw ~out_stream ~final_agent_msg tool_calls
    =
  List.map
    (execute_one_tool ~config ~sw ~out_stream ~final_agent_msg)
    tool_calls

(** Execute a list of tool calls in parallel under a sub-switch. Events fire in
    completion order; results are returned in source order. *)
let execute_tools_parallel ~config ~sw ~out_stream ~final_agent_msg tool_calls =
  let n = List.length tool_calls in
  let results = Array.make n None in
  Eio.Switch.run (fun sub_sw ->
      List.iteri
        (fun i tc ->
          Eio.Fiber.fork ~sw:sub_sw (fun () ->
              let result =
                execute_one_tool ~config ~sw ~out_stream ~final_agent_msg tc
              in
              results.(i) <- Some result))
        tool_calls);
  Array.to_list results |> List.filter_map (fun x -> x)

(** Execute tool calls according to the effective mode (sequential or parallel).
    Returns the list of [tool_result_content] in source order. *)
let execute_tool_calls ~config ~sw ~out_stream ~final_agent_msg tool_calls =
  let mode = effective_execution_mode config tool_calls in
  match mode with
  | `Sequential ->
      execute_tools_sequential ~config ~sw ~out_stream ~final_agent_msg
        tool_calls
  | `Parallel ->
      execute_tools_parallel ~config ~sw ~out_stream ~final_agent_msg tool_calls

(** {1 Inner and outer loops} *)

(** Run the inner loop under the given mutable state refs.

    [pending] is the list of [agent_message] values to inject before this
    iteration's LLM call. For the initial call these come from the outer loop;
    for subsequent calls they are steering messages. *)
let rec run_inner ~config ~model_ref ~options_ref ~messages_ref ~pending ~sw
    out_stream =
  (* Step 1: append pending messages to the history *)
  let appended_messages =
    if List.is_empty pending then !messages_ref else !messages_ref @ pending
  in
  messages_ref := appended_messages;
  (* Step 2: emit AE_turn_start *)
  push_event out_stream Agent_types.AE_turn_start;
  (* Step 3: build provider context and call stream_fn *)
  let tool_schemas =
    List.map
      (fun (tool : 'ctx Agent_types.tool) ->
        Pera_provider.Provider.
          {
            name = tool.name;
            description = tool.description;
            schema = tool.schema;
          })
      config.tools
  in
  let provider_context =
    build_provider_context ~system:config.system
      ~transform_context:config.transform_context
      ~convert_to_llm:config.convert_to_llm ~thinking:false ~tools:tool_schemas
      !messages_ref
  in
  invoke_get_api_key config.get_api_key;
  let provider_stream =
    config.stream_fn ~model:!model_ref ~context:provider_context
      ~options:!options_ref ~sw
  in
  (* Step 4: consume the provider stream, emitting message lifecycle events *)
  let final_msg = consume_provider_stream ~provider_stream out_stream in
  let final_agent_msg =
    Agent_types.Real (Pera_provider.Provider.AssistantMessage final_msg)
  in
  (* Step 5: append the final assistant message to history *)
  messages_ref := !messages_ref @ [ final_agent_msg ];
  (* Step 6: check stop_reason — Error or Aborted terminates the whole run *)
  if stop_reason_is_terminal final_msg.stop_reason then begin
    push_event out_stream
      (Agent_types.AE_turn_end { message = final_agent_msg; tool_results = [] });
    `Terminate
  end
  else begin
    (* Step 6b: execute tool calls if stop_reason = ToolUse *)
    let tool_results =
      match final_msg.stop_reason with
      | Pera_types.Types.ToolUse ->
          let tc_list = tool_calls_of_message final_msg in
          let results =
            execute_tool_calls ~config ~sw ~out_stream ~final_agent_msg tc_list
          in
          (* Append tool results to messages as ToolResultMessage entries *)
          let result_msgs =
            List.map
              (fun tr ->
                Agent_types.Real (Pera_provider.Provider.ToolResultMessage tr))
              results
          in
          messages_ref := !messages_ref @ result_msgs;
          results
      | Pera_types.Types.EndTurn | Pera_types.Types.MaxTokens
      | Pera_types.Types.StopSequence | Pera_types.Types.Error
      | Pera_types.Types.Aborted ->
          []
    in
    (* Step 7: emit AE_turn_end *)
    push_event out_stream
      (Agent_types.AE_turn_end { message = final_agent_msg; tool_results });
    (* Step 9: check should_stop_after_turn *)
    let should_stop =
      match config.should_stop_after_turn with
      | None -> false
      | Some f ->
          f
            {
              message = final_agent_msg;
              tool_results;
              messages = !messages_ref;
              tool_ctx = config.tool_ctx;
            }
    in
    if should_stop then `Stop
    else begin
      (* Step 10: call prepare_next_turn *)
      (match config.prepare_next_turn with
      | None -> ()
      | Some f ->
          let ctx =
            {
              message = final_agent_msg;
              tool_results;
              messages = !messages_ref;
              tool_ctx = config.tool_ctx;
            }
          in
          let update_opt = f ctx in
          Option.iter (apply_turn_update ~model_ref ~messages_ref) update_opt);
      (* Step 11: call get_steering_messages *)
      let steering =
        match config.get_steering_messages with None -> [] | Some f -> f ()
      in
      let had_tool_calls =
        match final_msg.stop_reason with
        | Pera_types.Types.ToolUse -> true
        | Pera_types.Types.EndTurn | Pera_types.Types.MaxTokens
        | Pera_types.Types.StopSequence | Pera_types.Types.Error
        | Pera_types.Types.Aborted ->
            false
      in
      if List.is_empty steering && not had_tool_calls then
        (* No steering and no tool calls — exit the inner loop *)
        `Stop
      else
        (* Tool calls or steering messages: continue the inner loop *)
        run_inner ~config ~model_ref ~options_ref ~messages_ref
          ~pending:steering ~sw out_stream
    end
  end

(** Run the outer loop.

    Calls [run_inner] with [pending] as the initial messages. After the inner
    loop exits, checks [get_follow_up_messages]: if non-empty, restarts the
    inner loop; otherwise emits [AE_agent_end] and closes the stream. *)
let rec run_outer ~config ~model_ref ~options_ref ~messages_ref ~pending ~sw
    out_stream =
  let outcome =
    run_inner ~config ~model_ref ~options_ref ~messages_ref ~pending ~sw
      out_stream
  in
  match outcome with
  | `Terminate ->
      let final_messages = !messages_ref in
      push_event out_stream
        (Agent_types.AE_agent_end { messages = final_messages });
      Pera_provider.Event_stream.close out_stream final_messages
  | `Stop ->
      let follow_ups =
        match config.get_follow_up_messages with None -> [] | Some f -> f ()
      in
      if List.is_empty follow_ups then begin
        let final_messages = !messages_ref in
        push_event out_stream
          (Agent_types.AE_agent_end { messages = final_messages });
        Pera_provider.Event_stream.close out_stream final_messages
      end
      else
        run_outer ~config ~model_ref ~options_ref ~messages_ref
          ~pending:follow_ups ~sw out_stream

(** {1 Entry point} *)

let run config ~messages ~sw =
  let out_stream = Pera_provider.Event_stream.create ~capacity:32 in
  Eio.Fiber.fork ~sw (fun () ->
      let model_ref = ref config.model in
      let options_ref = ref config.options in
      let messages_ref = ref messages in
      push_event out_stream Agent_types.AE_agent_start;
      run_outer ~config ~model_ref ~options_ref ~messages_ref ~pending:[] ~sw
        out_stream);
  out_stream
