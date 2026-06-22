open Containers
open Pera_core
open Pera_provider
open Pera_types

let src = Logs.Src.create "pera.driver.conversation_helpers" ~doc:"Conversation driver helpers"

module Log = (val Logs.src_log src : Logs.LOG)

(** {1 Mock tools} *)

(** Echo: return the [text] argument as-is. Mode: Parallel. *)
let echo_tool =
  Agent_types.Tool.create ~name:"echo" ~description:"Echo the text argument back."
    ~schema:
      (Json_schema.object_
         ~properties:
           [ ("text", Json_schema.string ~description:"Text to echo." ()) ]
         ~required:[ "text" ] ())
    ~parallel_safe:true
    ~execute:(fun ~ctx:_ ~args ~sw:_ ~cancel:_ ->
      let text =
        match Yojson.Safe.Util.member "text" args with
        | `String s -> s
        | _ -> "(no text)"
      in
      Ok (Agent_types.Tool_text text))

(** Counter: stateful incrementing integer. Mode: Sequential. *)
let counter_state = ref 0

let counter_tool =
  Agent_types.Tool.create ~name:"counter"
    ~description:"Return an incrementing integer as a string."
    ~schema:(Json_schema.object_ ~properties:[] ~required:[] ())
    ~parallel_safe:false
    ~execute:(fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
      incr counter_state;
      Ok (Agent_types.Tool_text (string_of_int !counter_state)))

(** {1 Event description} *)

let truncate max_len s =
  if String.length s <= max_len then s else String.sub s 0 max_len ^ "..."

(** Format a provider-level [assistant_message_event] as a one-liner. *)
let describe_provider_event = function
  | Types.AME_text_start _ -> "[text_start]"
  | Types.AME_text_delta { text; _ } ->
      Printf.sprintf "[text_delta] %s" (truncate 60 text)
  | Types.AME_thinking_start _ -> "[thinking_start]"
  | Types.AME_thinking_delta { text; _ } ->
      Printf.sprintf "[thinking_delta] %s" (truncate 60 text)
  | Types.AME_tool_call_start { name; id; _ } ->
      Printf.sprintf "[tool_call_start] name=%s id=%s" name id
  | Types.AME_tool_call_delta { index; arguments_fragment; _ } ->
      Printf.sprintf "[tool_call_delta] index=%d fragment=%s" index
        (truncate 40 arguments_fragment)
  | Types.AME_tool_call_end { index; _ } ->
      Printf.sprintf "[tool_call_end] index=%d" index
  | Types.AME_done _ -> "[done]"
  | Types.AME_error { message; _ } ->
      Printf.sprintf "[error] %s" message

(** Format an [agent_event] as a one-liner for driver output. *)
let describe_agent_event = function
  | Agent_types.AE_agent_start -> "[agent_start]"
  | Agent_types.AE_agent_end { messages } ->
      Printf.sprintf "[agent_end] messages=%d" (List.length messages)
  | Agent_types.AE_turn_start -> "[turn_start]"
  | Agent_types.AE_turn_end { tool_results; _ } ->
      Printf.sprintf "[turn_end] tool_results=%d" (List.length tool_results)
  | Agent_types.AE_message_start _ -> "[message_start]"
  | Agent_types.AE_message_update { event; _ } ->
      describe_provider_event event
  | Agent_types.AE_message_end _ -> "[message_end]"
  | Agent_types.AE_tool_execution_start { tool_name; tool_call_id; _ } ->
      Printf.sprintf "[tool_start] name=%s id=%s" tool_name tool_call_id
  | Agent_types.AE_tool_execution_update _ -> "[tool_update]"
  | Agent_types.AE_tool_execution_end { tool_name; is_error; _ } ->
      Printf.sprintf "[tool_end] name=%s error=%b" tool_name is_error
  | Agent_types.AE_compaction_start -> "[compaction_start]"
  | Agent_types.AE_compaction_end { summary } ->
      Printf.sprintf "[compaction_end] summary_len=%d" (String.length summary)
  | Agent_types.AE_compaction_error { message } ->
      Printf.sprintf "[compaction_error] %s" message

(** {1 Helpers} *)

(** Default convert_to_llm: project agent messages to provider messages. *)
let default_convert_to_llm msgs =
  List.map Agent_types.to_provider_message msgs

(** Build a user [agent_message]. *)
let make_user_message text =
  let um = Types.{ role = "user"; content = [ UText text ] } in
  Agent_types.Real (Provider.UserMessage um)

(** {1 Loop configuration} *)

let make_config ?(tools = []) ?(get_follow_up_messages = None) ~model stream_fn =
  Agent_loop.
    {
      model;
      system = "You are a helpful test assistant.";
      options =
        Provider.
          {
            max_tokens = 1024;
            temperature = None;
            cache_policy = Types.No_cache;
            cache_ttl = Types.Five_minutes;
          };
      stream_fn;
      convert_to_llm = default_convert_to_llm;
      tool_ctx = ();
      tools;
      tool_execution = `Parallel;
      transform_context = None;
      get_api_key = None;
      before_tool_call = None;
      after_tool_call = None;
      should_stop_after_turn = None;
      prepare_next_turn = None;
      get_steering_messages = None;
      get_follow_up_messages;
    }

(** {1 Scenario runner} *)

let run_scenario ~name ~messages ~sw ~check_result config =
  Printf.printf "\n=== Scenario: %s ===\n%!" name;
  let loop_stream = Agent_loop.run config ~messages ~sw in
  let events = ref [] in
  let iter_result =
    Event_stream.iter loop_stream ~f:(fun event ->
        events := !events @ [ event ];
        Printf.printf "  %s\n%!" (describe_agent_event event))
  in
  (* Print the final assistant text if present. *)
  let print_final_text msgs =
    let last_assistant =
      List.find_opt
        (fun msg ->
          match msg with
          | Agent_types.Real (Provider.AssistantMessage _) -> true
          | Agent_types.Real (Provider.UserMessage _) -> false
          | Agent_types.Real (Provider.ToolResultMessage _) -> false
          | Agent_types.Synthetic _ -> false)
        (List.rev msgs)
    in
    match last_assistant with
    | Some (Agent_types.Real (Provider.AssistantMessage am)) ->
        let text =
          List.filter_map
            (fun block ->
              match block with
              | Types.AText t -> Some t
              | Types.AThinking _ | Types.AToolCall _ -> None)
            am.Types.content
        in
        if not (List.is_empty text) then
          Printf.printf "  => text: %s\n%!" (String.concat "" text)
    | Some (Agent_types.Real (Provider.UserMessage _)) -> ()
    | Some (Agent_types.Real (Provider.ToolResultMessage _)) -> ()
    | Some (Agent_types.Synthetic _) -> ()
    | None -> ()
  in
  match iter_result with
  | Ok final_messages ->
      print_final_text final_messages;
      Printf.printf "  => final messages: %d\n%!" (List.length final_messages);
      let passed = check_result !events final_messages in
      if passed then Printf.printf "  PASS\n%!" else Printf.printf "  FAIL\n%!";
      passed
  | Error (err_msg, _stop_err) ->
      Log.err (fun m -> m "stream error: %s" err_msg);
      let passed = check_result !events [] in
      if passed then Printf.printf "  PASS\n%!" else Printf.printf "  FAIL\n%!";
      passed

(** {1 Scenarios} *)

(** Check that the last event is [AE_agent_end]. *)
let check_agent_end_is_last events =
  match List.last_opt events with
  | Some (Agent_types.AE_agent_end _) -> true
  | Some _ -> false
  | None -> false

(** Scenario 1: simple text response — no tools. *)
let scenario_simple_text ~model stream_fn sw =
  let messages = [ make_user_message "Please say exactly: Hello World" ] in
  let config = make_config ~model stream_fn in
  run_scenario ~name:"simple_text" ~messages ~sw config
    ~check_result:(fun events _final ->
      check_agent_end_is_last events)

(** Scenario 2: echo tool — expect tool call + result + final text turn. *)
let scenario_echo_tool ~model stream_fn sw =
  let messages = [ make_user_message "Use the echo tool with text: ping" ] in
  let config = make_config ~tools:[ echo_tool ] ~model stream_fn in
  run_scenario ~name:"echo_tool" ~messages ~sw config
    ~check_result:(fun events _final ->
      let has_tool_start =
        List.exists
          (function Agent_types.AE_tool_execution_start _ -> true | _ -> false)
          events
      in
      let has_tool_end =
        List.exists
          (function Agent_types.AE_tool_execution_end _ -> true | _ -> false)
          events
      in
      let agent_end_last = check_agent_end_is_last events in
      has_tool_start && has_tool_end && agent_end_last)

(** Scenario 3: multi-turn — inject a follow-up message after the first turn. *)
let scenario_multi_turn ~model stream_fn sw =
  let messages = [ make_user_message "What is 2+2?" ] in
  let followup_call_count = ref 0 in
  let get_follow_up_messages =
    Some
      (fun () ->
        incr followup_call_count;
        if Int.equal !followup_call_count 1 then
          [ make_user_message "What is that result times 3?" ]
        else [])
  in
  let config = make_config ~get_follow_up_messages ~model stream_fn in
  run_scenario ~name:"multi_turn" ~messages ~sw config
    ~check_result:(fun events _final ->
      let turn_count =
        List.length
          (List.filter
             (function Agent_types.AE_turn_start -> true | _ -> false)
             events)
      in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    turn_starts=%d\n%!" turn_count;
      Int.compare turn_count 2 >= 0 && agent_end_last)

(** Scenario 4: parallel echo — expect 2 tool executions. *)
let scenario_parallel_echo ~model stream_fn sw =
  let messages =
    [
      make_user_message
        "Use the echo tool twice: first with text alpha, then with text beta";
    ]
  in
  let config = make_config ~tools:[ echo_tool ] ~model stream_fn in
  run_scenario ~name:"parallel_echo" ~messages ~sw config
    ~check_result:(fun events _final ->
      let tool_start_count =
        List.length
          (List.filter
             (function
               | Agent_types.AE_tool_execution_start _ -> true | _ -> false)
             events)
      in
      let tool_end_count =
        List.length
          (List.filter
             (function
               | Agent_types.AE_tool_execution_end _ -> true | _ -> false)
             events)
      in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    tool_starts=%d tool_ends=%d\n%!" tool_start_count
        tool_end_count;
      Int.compare tool_start_count 2 >= 0
      && Int.equal tool_start_count tool_end_count
      && agent_end_last)

(** {1 Entry helpers} *)

type scenario_result = { name : string; passed : bool }

let run_all_scenarios ~model stream_fn sw =
  [
    {
      name = "simple_text";
      passed = scenario_simple_text ~model stream_fn sw;
    };
    {
      name = "echo_tool";
      passed = scenario_echo_tool ~model stream_fn sw;
    };
    {
      name = "multi_turn";
      passed = scenario_multi_turn ~model stream_fn sw;
    };
    {
      name = "parallel_echo";
      passed = scenario_parallel_echo ~model stream_fn sw;
    };
  ]

let run_named_scenario name ~model stream_fn sw =
  match name with
  | "simple_text" ->
      [ { name; passed = scenario_simple_text ~model stream_fn sw } ]
  | "echo_tool" ->
      [ { name; passed = scenario_echo_tool ~model stream_fn sw } ]
  | "multi_turn" ->
      [ { name; passed = scenario_multi_turn ~model stream_fn sw } ]
  | "parallel_echo" ->
      [ { name; passed = scenario_parallel_echo ~model stream_fn sw } ]
  | _ ->
      Log.err (fun m -> m "unknown scenario: %s" name);
      Log.err (fun m -> m "available: simple_text | echo_tool | multi_turn | parallel_echo");
      exit 1
