open Containers

(** {1 Hook context types} *)

type 'ctx should_stop_ctx = {
  message : Agent_types.agent_message;
  tool_results : Pera_types.Types.tool_result_content list;
  messages : Agent_types.agent_message list;
  tool_ctx : 'ctx;
  emit : Agent_types.agent_event -> unit;
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
  options : Pera_connector.Connector.simple_stream_options;
  stream_fn : Agent_types.stream_fn;
  convert_to_llm :
    Agent_types.agent_message list -> Pera_connector.Connector.message list;
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
  | Pera_types.Types.Error _ | Pera_types.Types.Aborted -> true
  | Pera_types.Types.EndTurn | Pera_types.Types.ToolUse
  | Pera_types.Types.MaxTokens | Pera_types.Types.StopSequence ->
      false

(** Push one event into the output stream. *)
let push_event out_stream event =
  Pera_connector.Event_stream.push out_stream event

(** Apply a [turn_update] to the mutable loop state refs. Any [None] field means
    "keep current value". *)
let apply_turn_update ~model_ref ~messages_ref ~current_thinking_budget
    (update : Agent_types.turn_update) =
  Option.iter (fun m -> model_ref := m) update.model;
  (match update.thinking with
   | Agent_types.Inherit -> ()
   | Agent_types.Budget n -> current_thinking_budget := Some n
   | Agent_types.Disabled -> current_thinking_budget := None);
  Option.iter (fun msgs -> messages_ref := msgs) update.messages

(** Build the provider context for one LLM call.

    Applies [transform_context] (if set) and then [convert_to_llm] to produce
    the provider-level message list. *)
let build_provider_context ~system ~transform_context ~convert_to_llm
    ~tools messages =
  let transformed =
    match transform_context with None -> messages | Some f -> f messages
  in
  let provider_messages = convert_to_llm transformed in
  Pera_connector.Connector.
    { system; messages = provider_messages; tools }

(** Invoke [get_api_key] if set. The return value is not used by the loop; the
    call exists to satisfy provider contracts. *)
let invoke_get_api_key get_api_key =
  Option.iter (fun f -> ignore (f ~provider:"anthropic")) get_api_key

(** {1 Provider stream consumption} *)

(** Stream one turn from the provider into [out_stream].

    Emits [AE_message_start], one [AE_message_update] per event, and
    [AE_message_end]. Returns the final [assistant_message].

    On a transport error the returned message carries [stop_reason = Error]. On
    cancellation ([Eio.Cancel.Cancelled]), the returned message carries
    [stop_reason = Aborted] and [AE_message_end] is emitted under
    [Eio.Cancel.protect] so the caller can proceed to its terminal event
    emissions without itself suspending in a cancelled context. *)
let consume_provider_stream ~provider_stream out_stream =
  let partial_ref = ref empty_assistant_message in
  let emitted_start = ref false in
  let cancelled = ref false in
  (try
     let _iter_result =
       Pera_connector.Event_stream.iter provider_stream ~f:(fun event ->
           let partial = partial_of_event event in
           partial_ref := partial;
           let agent_msg =
             Agent_types.Real (Pera_connector.Connector.AssistantMessage partial)
           in
           if not !emitted_start then begin
             emitted_start := true;
             push_event out_stream
               (Agent_types.AE_message_start { message = agent_msg })
           end;
           push_event out_stream
             (Agent_types.AE_message_update { message = agent_msg; event }))
     in
     ()
   with Eio.Cancel.Cancelled _ -> cancelled := true);
  let final_msg =
    if !cancelled then
      (* Cancellation mid-stream: report Aborted to the caller so it can
         proceed with its normal terminal path without suspending. *)
      { !partial_ref with stop_reason = Pera_types.Types.Aborted }
    else begin
      (* Wait for the final result from the provider stream. *)
      let stream_result = Pera_connector.Event_stream.result provider_stream in
      match stream_result with
      | Ok final -> final
      | Error (err_msg, stop_err) ->
          {
            !partial_ref with
            stop_reason = Pera_types.Types.Error stop_err;
            provenance =
              { !partial_ref.provenance with error_message = Some err_msg };
          }
    end
  in
  let final_agent_msg =
    Agent_types.Real (Pera_connector.Connector.AssistantMessage final_msg)
  in
  (* Emit AE_message_end under cancel protection so this emission succeeds even
     when the switch has been cancelled. push_event is non-blocking if the
     stream has capacity, so protect is a belt-and-suspenders guard. *)
  Eio.Cancel.protect (fun () ->
      push_event out_stream
        (Agent_types.AE_message_end { message = final_agent_msg }));
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
    unless any called tool has [parallel_safe = false], in which case the whole
    batch is forced sequential. *)
let effective_execution_mode config tool_calls =
  let any_not_parallel_safe =
    List.exists
      (fun (tc : Pera_types.Types.tool_call) ->
        match
          List.find_opt
            (fun (t : 'ctx Agent_types.tool) ->
              String.equal (Agent_types.Tool.name t) tc.name)
            config.tools
        with
        | Some tool -> not (Agent_types.Tool.parallel_safe tool)
        | None -> false)
      tool_calls
  in
  if any_not_parallel_safe then `Sequential else config.tool_execution

(** Execute a single tool call, performing validation, hook invocation, and
    error handling. Emits [AE_tool_execution_start] and [AE_tool_execution_end]
    events. Returns the [tool_result_content]. *)
let execute_one_tool ~config ~sw ~out_stream ~final_agent_msg
    (tc : Pera_types.Types.tool_call) =
  let tool_call_id = tc.id in
  let tool_name = tc.name in
  (* [fail_tool msg] emits an error execution-end event and returns the error
     result.  Used as the early-exit payload in the [let*] chain below.
     Note: [AE_tool_execution_start] is intentionally NOT emitted on this path —
     the start event fires only when all checks pass (Step 4). *)
  let fail_tool msg =
    let content = `String msg in
    let result = Pera_types.Types.{ tool_call_id; content; is_error = true } in
    push_event out_stream
      (Agent_types.AE_tool_execution_end
         { tool_call_id; tool_name; result = content; is_error = true });
    result
  in
  (* Each step either short-circuits via [Error early_result] (using [fail_tool])
     or continues via [Ok ...].  Both branches carry [tool_result_content], so
     the outcome is resolved at the end with the or-pattern
     [match r with Ok r | Error r -> r].  This eliminates three levels of nested
     [match] while keeping the side-effect order unchanged. *)
  let outcome =
    let open Result.Syntax in
    (* Step 1: look up tool by name *)
    let* tool =
      match
        List.find_opt
          (fun (t : 'ctx Agent_types.tool) ->
            String.equal (Agent_types.Tool.name t) tool_name)
          config.tools
      with
      | Some t -> Ok t
      | None -> Error (fail_tool (Printf.sprintf "Unknown tool: %s" tool_name))
    in
    (* Step 2: validate args *)
    let* () =
      Pera_connector.Json_schema.validate (Agent_types.Tool.schema tool)
        tc.arguments
      |> Result.map_err (fun err ->
          fail_tool (Printf.sprintf "Schema validation failed: %s" err))
    in
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
    let* () =
      match before_result with
      | Agent_types.Allow -> Ok ()
      | Agent_types.Deny msg -> Error (fail_tool msg)
    in
    (* Step 4: emit execution start — only reached after all checks pass *)
    push_event out_stream
      (Agent_types.AE_tool_execution_start
         { tool_call_id; tool_name; args = tc.arguments });
    (* Step 5: execute the tool, catching exceptions *)
    let execute_result =
      match
        Eio.Cancel.sub (fun cancel ->
            Agent_types.Tool.execute tool ~ctx:config.tool_ctx
              ~args:tc.arguments ~sw ~cancel)
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
    (* Step 6: call after_tool_call if set *)
    Option.iter
      (fun f ->
        f
          {
            tool_call = tc;
            result = execute_result;
            tool_ctx = config.tool_ctx;
          })
      config.after_tool_call;
    (* Step 7: emit execution end *)
    push_event out_stream
      (Agent_types.AE_tool_execution_end
         { tool_call_id; tool_name; result = execute_result.content; is_error });
    Ok execute_result
  in
  match outcome with Ok result | Error result -> result

(** Execute a list of tool calls sequentially, in source order. *)
let execute_tools_sequential ~config ~sw ~out_stream ~final_agent_msg tool_calls
    =
  List.map
    (execute_one_tool ~config ~sw ~out_stream ~final_agent_msg)
    tool_calls

(** Execute a list of tool calls in parallel under a sub-switch. Events fire in
    completion order; results are returned in source order.

    If the outer switch is cancelled while tool fibres are running, the
    sub-switch is cancelled (so blocked tool fibres get [Eio.Cancel.Cancelled]
    at their next suspension point). Whatever results completed before
    cancellation are captured and returned in source order; the
    [Eio.Cancel.Cancelled] exception is then re-raised so the caller can take
    its terminal path. *)
let execute_tools_parallel ~config ~sw ~out_stream ~final_agent_msg tool_calls =
  let n = List.length tool_calls in
  let results = Array.make n None in
  let cancelled_exn = ref None in
  (try
     Eio.Switch.run (fun sub_sw ->
         List.iteri
           (fun i tc ->
             Eio.Fiber.fork ~sw:sub_sw (fun () ->
                 let result =
                   execute_one_tool ~config ~sw ~out_stream ~final_agent_msg tc
                 in
                 results.(i) <- Some result))
           tool_calls)
   with Eio.Cancel.Cancelled _ as exn -> cancelled_exn := Some exn);
  let partial_results = Array.to_list results |> List.filter_map (fun x -> x) in
  (* Re-raise cancellation after collecting partial results, so the caller
     knows to take its terminal path. *)
  Option.iter raise !cancelled_exn;
  partial_results

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
let rec run_inner ~config ~model_ref ~options_ref ~current_thinking_budget
    ~messages_ref ~pending ~sw out_stream =
  (* Hook helpers — defined once, called in the [Ok tool_results] branch below.
     Each captures [config], [model_ref], [messages_ref], and [options_ref] by
     closure so call sites stay concise. *)
  let invoke_should_stop ~final_agent_msg ~tool_results =
    match config.should_stop_after_turn with
    | None -> false
    | Some f ->
        f
          {
            message = final_agent_msg;
            tool_results;
            messages = !messages_ref;
            tool_ctx = config.tool_ctx;
            emit = (fun ev -> push_event out_stream ev);
          }
  in
  let invoke_prepare_next_turn ~final_agent_msg ~tool_results =
    match config.prepare_next_turn with
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
        Option.iter
          (apply_turn_update ~model_ref ~messages_ref ~current_thinking_budget)
          (f ctx)
  in
  let get_steering_messages () =
    match config.get_steering_messages with None -> [] | Some f -> f ()
  in
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
        Pera_connector.Connector.
          {
            name = Agent_types.Tool.name tool;
            description = Agent_types.Tool.description tool;
            schema = Agent_types.Tool.schema tool;
          })
      config.tools
  in
  let provider_context =
    build_provider_context ~system:config.system
      ~transform_context:config.transform_context
      ~convert_to_llm:config.convert_to_llm ~tools:tool_schemas
      !messages_ref
  in
  invoke_get_api_key config.get_api_key;
  let current_options =
    let opts : Pera_connector.Connector.simple_stream_options = !options_ref in
    { opts with thinking_budget_tokens = !current_thinking_budget } in
  let provider_stream =
    config.stream_fn ~model:!model_ref ~context:provider_context
      ~options:current_options ~sw
  in
  (* Step 4: consume the provider stream, emitting message lifecycle events *)
  let final_msg = consume_provider_stream ~provider_stream out_stream in
  let final_agent_msg =
    Agent_types.Real (Pera_connector.Connector.AssistantMessage final_msg)
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
    (* Step 6b: execute tool calls if stop_reason = ToolUse.
       If tool execution is cancelled mid-batch (Eio.Cancel.Cancelled propagates
       from execute_tools_parallel), we capture whichever results completed and
       emit AE_turn_end with them before taking the terminal path. The
       Eio.Cancel.Cancelled exception is caught here to allow clean teardown;
       the caller (run_outer, run) handles any residual cancellation. *)
    let tool_results_result =
      match final_msg.stop_reason with
      | Pera_types.Types.ToolUse -> (
          let tc_list = tool_calls_of_message final_msg in
          match
            execute_tool_calls ~config ~sw ~out_stream ~final_agent_msg tc_list
          with
          | results ->
              let result_msgs =
                List.map
                  (fun tr ->
                    Agent_types.Real
                      (Pera_connector.Connector.ToolResultMessage tr))
                  results
              in
              messages_ref := !messages_ref @ result_msgs;
              Ok results
          | exception (Eio.Cancel.Cancelled _ as _exn) ->
              (* Partial results already populated in execute_tools_parallel;
                  here we use what completed before cancellation: empty list
                  since we re-raised and didn't get the return value. Signal
                  terminal via Error so the caller takes the Terminate path. *)
              Error [])
      | Pera_types.Types.EndTurn | Pera_types.Types.MaxTokens
      | Pera_types.Types.StopSequence | Pera_types.Types.Error _
      | Pera_types.Types.Aborted ->
          Ok []
    in
    match tool_results_result with
    | Error partial_results ->
        (* Cancelled during tool execution: emit AE_turn_end with whatever
           completed, then terminate the run. Use Eio.Cancel.protect so the
           event emission succeeds even in the cancelled context. *)
        Eio.Cancel.protect (fun () ->
            push_event out_stream
              (Agent_types.AE_turn_end
                 { message = final_agent_msg; tool_results = partial_results }));
        `Terminate
    | Ok tool_results ->
        (* Step 7: emit AE_turn_end *)
        push_event out_stream
          (Agent_types.AE_turn_end { message = final_agent_msg; tool_results });
        (* Step 9: check should_stop_after_turn *)
        if invoke_should_stop ~final_agent_msg ~tool_results then `Stop
        else begin
          (* Step 10: call prepare_next_turn *)
          invoke_prepare_next_turn ~final_agent_msg ~tool_results;
          (* Step 11: get steering messages *)
          let steering = get_steering_messages () in
          let had_tool_calls =
            match final_msg.stop_reason with
            | Pera_types.Types.ToolUse -> true
            | Pera_types.Types.EndTurn | Pera_types.Types.MaxTokens
            | Pera_types.Types.StopSequence | Pera_types.Types.Error _
            | Pera_types.Types.Aborted ->
                false
          in
          if List.is_empty steering && not had_tool_calls then
            (* No steering and no tool calls — exit the inner loop *)
            `Stop
          else
            (* Tool calls or steering messages: continue the inner loop *)
            run_inner ~config ~model_ref ~options_ref ~current_thinking_budget
              ~messages_ref
              ~pending:steering ~sw out_stream
        end
  end

(** Run the outer loop.

    Calls [run_inner] with [pending] as the initial messages. After the inner
    loop exits, checks [get_follow_up_messages]: if non-empty, restarts the
    inner loop; otherwise emits [AE_agent_end] and closes the stream. *)
let rec run_outer ~config ~model_ref ~options_ref ~current_thinking_budget
    ~messages_ref ~pending ~sw out_stream =
  let outcome =
    run_inner ~config ~model_ref ~options_ref ~current_thinking_budget
      ~messages_ref ~pending ~sw out_stream
  in
  match outcome with
  | `Terminate ->
      (* Use Cancel.protect so cleanup events fire even under a cancelled switch. *)
      Eio.Cancel.protect (fun () ->
          let final_messages = !messages_ref in
          push_event out_stream
            (Agent_types.AE_agent_end { messages = final_messages });
          Pera_connector.Event_stream.close out_stream final_messages)
  | `Stop ->
      let follow_ups =
        match config.get_follow_up_messages with None -> [] | Some f -> f ()
      in
      if List.is_empty follow_ups then begin
        let final_messages = !messages_ref in
        push_event out_stream
          (Agent_types.AE_agent_end { messages = final_messages });
        Pera_connector.Event_stream.close out_stream final_messages
      end
      else
        run_outer ~config ~model_ref ~options_ref ~current_thinking_budget
          ~messages_ref ~pending:follow_ups ~sw out_stream

(** {1 Entry point} *)

let run config ~messages ~sw =
  let out_stream = Pera_connector.Event_stream.create ~capacity:32 in
  Eio.Fiber.fork ~sw (fun () ->
      let model_ref = ref config.model in
      let options_ref = ref config.options in
      let current_thinking_budget = ref config.options.thinking_budget_tokens in
      let messages_ref = ref messages in
      push_event out_stream Agent_types.AE_agent_start;
      match
        run_outer ~config ~model_ref ~options_ref ~current_thinking_budget
          ~messages_ref ~pending:[] ~sw out_stream
      with
      | () -> ()
      | exception exn ->
          (* Any exception escaping run_outer (cancellation, unexpected error,
              etc.) must not leave the output stream unclosed, as the consumer
              would then block forever.  Emit AE_agent_end and close the stream
              under Eio.Cancel.protect so these operations succeed even when
              the switch has been cancelled. *)
          let err_msg = Printexc.to_string exn in
          Eio.Cancel.protect (fun () ->
              let final_messages = !messages_ref in
              push_event out_stream
                (Agent_types.AE_agent_end { messages = final_messages });
              Pera_connector.Event_stream.close_internal_error out_stream
                err_msg));
  out_stream
