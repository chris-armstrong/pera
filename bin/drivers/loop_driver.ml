open Containers
open Pera_core
open Pera_core_test_util
open Pera_provider
open Pera_types

let src = Logs.Src.create "pera.driver.loop" ~doc:"Loop driver"

module Log = (val Logs.src_log src : Logs.LOG)

(** {1 Helpers} *)

(** Build a minimal [assistant_message] with the given text and stop_reason. *)
let make_assistant_message ?(stop_reason = Types.EndTurn) text =
  Types.
    {
      content = [ AText text ];
      stop_reason;
      provenance =
        {
          api = "faux";
          provider = "faux";
          model = "faux";
          error_message = None;
        };
      usage =
        {
          input_tokens = 0;
          output_tokens = 0;
          cache_read_tokens = 0;
          cache_write_tokens = 0;
          cost_usd = None;
        };
    }

(** Build an [agent_message] wrapping a user message. *)
let make_user_agent_message text =
  let um = Types.{ role = "user"; content = [ UText text ] } in
  Agent_types.Real (Provider.UserMessage um)

(** Build an assistant message with tool calls and ToolUse stop_reason. *)
let make_tool_use_message tool_calls =
  let content = List.map (fun tc -> Types.AToolCall tc) tool_calls in
  Types.
    {
      content;
      stop_reason = ToolUse;
      provenance =
        {
          api = "faux";
          provider = "faux";
          model = "faux";
          error_message = None;
        };
      usage =
        {
          input_tokens = 0;
          output_tokens = 0;
          cache_read_tokens = 0;
          cache_write_tokens = 0;
          cost_usd = None;
        };
    }

(** Build a tool call record. *)
let make_tool_call id name arguments = Types.{ id; name; arguments }

(** Default convert_to_llm: unwrap Real messages, refute Synthetic. *)
let default_convert_to_llm msgs =
  List.filter_map
    (fun msg ->
      match msg with
      | Agent_types.Real m -> Some m
      | Agent_types.Synthetic _ -> .)
    msgs

(** Default model for loop calls. *)
let test_model = Types.{ id = "faux-model"; api = "faux" }

(** Default options for loop calls. *)
let test_options = Provider.{ max_tokens = 1024; temperature = None }

(** Empty JSON schema for tools that take no args. *)
let empty_schema = Json_schema.object_ ~properties:[] ~required:[] ()

(** Build a loop config with the given stream_fn and optional overrides. *)
let make_config ?(tools = []) ?(tool_execution = `Parallel)
    ?(should_stop_after_turn = None) ?(prepare_next_turn = None)
    ?(get_steering_messages = None) ?(get_follow_up_messages = None)
    ?(before_tool_call = None) ?(after_tool_call = None) ?(get_api_key = None)
    stream_fn =
  Agent_loop.
    {
      model = test_model;
      system = "You are a test assistant.";
      options = test_options;
      stream_fn;
      convert_to_llm = default_convert_to_llm;
      tool_ctx = ();
      tools;
      tool_execution;
      transform_context = None;
      get_api_key;
      before_tool_call;
      after_tool_call;
      should_stop_after_turn;
      prepare_next_turn;
      get_steering_messages;
      get_follow_up_messages;
    }

(** Format an [agent_event] as a human-readable structured line. *)
let describe e = Format.asprintf "%a" Agent_types.pp_agent_event e

(** Run a loop config, printing each event and the final result.

    Returns [true] if the run completed without an unexpected exception and the
    given [check_result] function passes; [false] otherwise. *)
let run_scenario ~name ~messages ~sw config ~check_result =
  Printf.printf "\n=== Scenario: %s ===\n%!" name;
  Faux_provider.reset_recorded ();
  let loop_stream = Agent_loop.run config ~messages ~sw in
  let events = ref [] in
  let iter_result =
    Event_stream.iter loop_stream ~f:(fun event ->
        events := !events @ [ event ];
        Printf.printf "  %s\n%!" (describe event))
  in
  match iter_result with
  | Ok final_messages ->
      Printf.printf "  => final messages: %d\n%!" (List.length final_messages);
      let passed = check_result !events final_messages in
      if passed then Printf.printf "  PASS\n%!" else Printf.printf "  FAIL\n%!";
      passed
  | Error err ->
      Printf.printf "  => stream error: %s\n%!" err;
      let passed = check_result !events [] in
      if passed then Printf.printf "  PASS\n%!" else Printf.printf "  FAIL\n%!";
      passed

(** Check that the last event in a list is [AE_agent_end]. *)
let check_agent_end_is_last events =
  match List.last_opt events with
  | Some (Agent_types.AE_agent_end _) -> true
  | _ -> false

(** Count events matching a predicate. *)
let count_events pred events = List.length (List.filter pred events)

(** Check whether an event is [AE_tool_execution_start]. *)
let is_tool_start = function
  | Agent_types.AE_tool_execution_start _ -> true
  | _ -> false

(** Check whether an event is [AE_tool_execution_end]. *)
let is_tool_end = function
  | Agent_types.AE_tool_execution_end _ -> true
  | _ -> false

(** Check whether an event is [AE_turn_start]. *)
let is_turn_start = function Agent_types.AE_turn_start -> true | _ -> false

(** {1 Scenario 1: single_text_turn} *)

(** One turn, text only; expect the full lifecycle event sequence. *)
let scenario_single_text_turn sw =
  let partial_msg = make_assistant_message "" in
  let final_msg = make_assistant_message "Hello, world!" in
  let script =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = partial_msg };
              Types.AME_text_delta { text = "Hello, "; partial = partial_msg };
              Types.AME_text_delta { text = "world!"; partial = final_msg };
            ];
          final = final_msg;
        }
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let messages = [ make_user_agent_message "Say hello." ] in
  run_scenario ~name:"single_text_turn" ~messages ~sw config
    ~check_result:(fun events _final ->
      let has_agent_start =
        List.exists
          (function Agent_types.AE_agent_start -> true | _ -> false)
          events
      in
      let has_turn_start =
        List.exists
          (function Agent_types.AE_turn_start -> true | _ -> false)
          events
      in
      let has_message_start =
        List.exists
          (function Agent_types.AE_message_start _ -> true | _ -> false)
          events
      in
      let has_message_end =
        List.exists
          (function Agent_types.AE_message_end _ -> true | _ -> false)
          events
      in
      let has_turn_end =
        List.exists
          (function Agent_types.AE_turn_end _ -> true | _ -> false)
          events
      in
      let agent_end_last = check_agent_end_is_last events in
      has_agent_start && has_turn_start && has_message_start && has_message_end
      && has_turn_end && agent_end_last)

(** {1 Scenario 2: parallel_tool_calls} *)

(** Two parallel echo-tool calls; show both tool_execution_start/end events,
    tool results appended in source order, follow-up text turn ends with
    EndTurn.

    Expected M2 property: tool_execution_end events fire in completion order but
    tool_result messages are appended in source order. *)
let scenario_parallel_tool_calls sw =
  let tc1 = make_tool_call "id-1" "echo" (`Assoc [ ("text", `String "foo") ]) in
  let tc2 = make_tool_call "id-2" "echo" (`Assoc [ ("text", `String "bar") ]) in
  let tool_use_msg = make_tool_use_message [ tc1; tc2 ] in
  let followup_msg = make_assistant_message "Both echoes done." in
  (* Turn 1: two parallel tool calls *)
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_tool_call_start
                {
                  index = 0;
                  id = "id-1";
                  name = "echo";
                  partial = tool_use_msg;
                };
              Types.AME_tool_call_start
                {
                  index = 1;
                  id = "id-2";
                  name = "echo";
                  partial = tool_use_msg;
                };
            ];
          final = tool_use_msg;
        }
  in
  (* Turn 2: follow-up text response *)
  let script2 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = followup_msg };
              Types.AME_text_delta
                { text = "Both echoes done."; partial = followup_msg };
            ];
          final = followup_msg;
        }
  in
  (* Echo tool: returns the text argument *)
  let echo_tool =
    Agent_types.
      {
        name = "echo";
        description = "Echo the text argument back.";
        schema =
          Json_schema.object_
            ~properties:
              [ ("text", Json_schema.string ~description:"Text to echo." ()) ]
            ~required:[ "text" ] ();
        mode = `Parallel;
        execute =
          (fun ~ctx:_ ~args ~sw:_ ~cancel:_ ->
            let text =
              match Yojson.Safe.Util.member "text" args with
              | `String s -> s
              | _ -> "(no text)"
            in
            Ok (Agent_types.Tool_text text));
      }
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~tools:[ echo_tool ] stream_fn in
  let messages = [ make_user_agent_message "Echo foo and bar in parallel." ] in
  run_scenario ~name:"parallel_tool_calls" ~messages ~sw config
    ~check_result:(fun events _final ->
      let tool_starts = count_events is_tool_start events in
      let tool_ends = count_events is_tool_end events in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    tool_starts=%d tool_ends=%d\n%!" tool_starts tool_ends;
      Int.equal tool_starts 2 && Int.equal tool_ends 2 && agent_end_last)

(** {1 Scenario 3: sequential_tool_calls} *)

(** Two sequential tool calls (tool_execution = Sequential). *)
let scenario_sequential_tool_calls sw =
  let tc1 = make_tool_call "seq-1" "counter" (`Assoc [ ("step", `Int 1) ]) in
  let tc2 = make_tool_call "seq-2" "counter" (`Assoc [ ("step", `Int 2) ]) in
  let tool_use_msg = make_tool_use_message [ tc1; tc2 ] in
  let followup_msg = make_assistant_message "Sequential calls done." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_tool_call_start
                {
                  index = 0;
                  id = "seq-1";
                  name = "counter";
                  partial = tool_use_msg;
                };
              Types.AME_tool_call_start
                {
                  index = 1;
                  id = "seq-2";
                  name = "counter";
                  partial = tool_use_msg;
                };
            ];
          final = tool_use_msg;
        }
  in
  let script2 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = followup_msg };
              Types.AME_text_delta
                { text = "Sequential calls done."; partial = followup_msg };
            ];
          final = followup_msg;
        }
  in
  let call_order = ref [] in
  let counter_tool =
    Agent_types.
      {
        name = "counter";
        description = "Record invocation order.";
        schema =
          Json_schema.object_
            ~properties:
              [ ("step", Json_schema.object_ ~properties:[] ~required:[] ()) ]
            ~required:[] ();
        mode = `Sequential;
        execute =
          (fun ~ctx:_ ~args ~sw:_ ~cancel:_ ->
            let step =
              match Yojson.Safe.Util.member "step" args with
              | `Int n -> string_of_int n
              | _ -> "?"
            in
            call_order := !call_order @ [ step ];
            Ok (Agent_types.Tool_text ("step=" ^ step)));
      }
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config =
    make_config ~tools:[ counter_tool ] ~tool_execution:`Sequential stream_fn
  in
  let messages = [ make_user_agent_message "Run counter sequentially." ] in
  run_scenario ~name:"sequential_tool_calls" ~messages ~sw config
    ~check_result:(fun events _final ->
      let tool_starts = count_events is_tool_start events in
      let tool_ends = count_events is_tool_end events in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    call_order=%s\n%!" (String.concat "," !call_order);
      Int.equal tool_starts 2 && Int.equal tool_ends 2 && agent_end_last)

(** {1 Scenario 4: tool_error} *)

(** A tool that returns [Error]; expect AE_tool_execution_end with
    is_error=true. *)
let scenario_tool_error sw =
  let tc = make_tool_call "err-1" "failing_tool" (`Assoc []) in
  let tool_use_msg = make_tool_use_message [ tc ] in
  let followup_msg = make_assistant_message "I see the tool failed." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_tool_call_start
                {
                  index = 0;
                  id = "err-1";
                  name = "failing_tool";
                  partial = tool_use_msg;
                };
            ];
          final = tool_use_msg;
        }
  in
  let script2 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = followup_msg };
              Types.AME_text_delta
                { text = "I see the tool failed."; partial = followup_msg };
            ];
          final = followup_msg;
        }
  in
  let failing_tool =
    Agent_types.
      {
        name = "failing_tool";
        description = "Always returns an error.";
        schema = empty_schema;
        mode = `Parallel;
        execute =
          (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
            Error
              Types.{ message = "intentional failure"; is_user_error = false });
      }
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~tools:[ failing_tool ] stream_fn in
  let messages = [ make_user_agent_message "Try the failing tool." ] in
  run_scenario ~name:"tool_error" ~messages ~sw config
    ~check_result:(fun events _final ->
      let error_end_events =
        List.filter
          (function
            | Agent_types.AE_tool_execution_end { is_error = true; _ } -> true
            | _ -> false)
          events
      in
      let has_error_end = not (List.is_empty error_end_events) in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    error_tool_ends=%d\n%!" (List.length error_end_events);
      has_error_end && agent_end_last)

(** {1 Scenario 5: mid_stream_cancel} *)

(** Cancel the switch after AE_turn_start fires; expect clean AE_agent_end with
    Aborted stop_reason surfaced via the stream error.

    The loop emits AE_turn_end and AE_agent_end under Eio.Cancel.protect, so
    they appear after the switch exits. We drain the stream in a fresh switch to
    collect them. *)
let scenario_mid_stream_cancel () =
  Printf.printf "\n=== Scenario: mid_stream_cancel ===\n%!";
  Faux_provider.reset_recorded ();
  let events = ref [] in
  (* The pause resolves a sticky promise when the first event fires, then
     blocks forever — cancelled when the switch fails. *)
  let pause_reached_p, pause_reached_r = Eio.Promise.create () in
  let pause () =
    (try Eio.Promise.resolve pause_reached_r () with _ -> ());
    let never, _ = Eio.Promise.create () in
    Eio.Promise.await never
  in
  let partial_msg = make_assistant_message "" in
  let final_msg = make_assistant_message "streaming text" in
  let script =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = partial_msg };
              Types.AME_text_delta { text = "stream"; partial = final_msg };
            ];
          final = final_msg;
        }
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts ~pause [ script ] in
  let config = make_config stream_fn in
  let loop_stream_ref = ref None in
  (try
     Eio.Switch.run (fun sw ->
         let loop_stream =
           Agent_loop.run config
             ~messages:[ make_user_agent_message "Start streaming." ]
             ~sw
         in
         loop_stream_ref := Some loop_stream;
         Eio.Fiber.fork ~sw (fun () ->
             try
               ignore
                 (Event_stream.iter loop_stream ~f:(fun e ->
                      events := !events @ [ e ];
                      Printf.printf "  %s\n%!" (describe e)))
             with _ -> ());
         Eio.Promise.await pause_reached_p;
         Eio.Switch.fail sw (Failure "cancelled by test"))
   with Failure _ -> ());
  (* Drain any remaining events from the (now fully-closed) stream. *)
  (match !loop_stream_ref with
  | None -> ()
  | Some loop_stream ->
      Eio.Switch.run (fun _sw2 ->
          ignore
            (Event_stream.iter loop_stream ~f:(fun e ->
                 events := !events @ [ e ];
                 Printf.printf "  %s\n%!" (describe e)))));
  let ev = !events in
  let has_agent_end =
    List.exists (function Agent_types.AE_agent_end _ -> true | _ -> false) ev
  in
  let turn_count = count_events is_turn_start ev in
  Printf.printf "  => has_agent_end=%b turn_starts=%d\n%!" has_agent_end
    turn_count;
  let passed = has_agent_end && Int.equal turn_count 1 in
  if passed then Printf.printf "  PASS\n%!" else Printf.printf "  FAIL\n%!";
  passed

(** {1 Scenario 6: steering_message} *)

(** Inject a steering message between turns via [get_steering_messages]; expect
    two turns. *)
let scenario_steering_message sw =
  let turn1_msg = make_assistant_message "Turn 1 done." in
  let turn2_msg = make_assistant_message "Turn 2 with steering." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = turn1_msg };
              Types.AME_text_delta
                { text = "Turn 1 done."; partial = turn1_msg };
            ];
          final = turn1_msg;
        }
  in
  let script2 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = turn2_msg };
              Types.AME_text_delta
                { text = "Turn 2 with steering."; partial = turn2_msg };
            ];
          final = turn2_msg;
        }
  in
  (* Steering: return a message on the first call, then nothing. *)
  let steering_call_count = ref 0 in
  let get_steering_messages =
    Some
      (fun () ->
        incr steering_call_count;
        if Int.equal !steering_call_count 1 then
          [ make_user_agent_message "Steering: please continue." ]
        else [])
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~get_steering_messages stream_fn in
  let messages = [ make_user_agent_message "Start." ] in
  run_scenario ~name:"steering_message" ~messages ~sw config
    ~check_result:(fun events _final ->
      let turn_count = count_events is_turn_start events in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    turn_starts=%d\n%!" turn_count;
      Int.equal turn_count 2 && agent_end_last)

(** {1 Scenario 7: follow_up_message} *)

(** Return a follow-up message via [get_follow_up_messages]; expect the outer
    loop to restart, producing two turns total. *)
let scenario_follow_up_message sw =
  let turn1_msg = make_assistant_message "First answer." in
  let turn2_msg = make_assistant_message "Follow-up answer." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = turn1_msg };
              Types.AME_text_delta
                { text = "First answer."; partial = turn1_msg };
            ];
          final = turn1_msg;
        }
  in
  let script2 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = turn2_msg };
              Types.AME_text_delta
                { text = "Follow-up answer."; partial = turn2_msg };
            ];
          final = turn2_msg;
        }
  in
  (* Follow-up: return a message once, then nothing. *)
  let followup_call_count = ref 0 in
  let get_follow_up_messages =
    Some
      (fun () ->
        incr followup_call_count;
        if Int.equal !followup_call_count 1 then
          [ make_user_agent_message "Follow-up: tell me more." ]
        else [])
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~get_follow_up_messages stream_fn in
  let messages = [ make_user_agent_message "Initial question." ] in
  run_scenario ~name:"follow_up_message" ~messages ~sw config
    ~check_result:(fun events _final ->
      let turn_count = count_events is_turn_start events in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    turn_starts=%d\n%!" turn_count;
      Int.equal turn_count 2 && agent_end_last)

(** {1 All scenarios} *)

type scenario_result = { name : string; passed : bool }
(** The list of named scenarios that can be selected by argv[1]. *)

(** Run all scenarios and return a list of results. *)
let run_all_scenarios sw =
  [
    { name = "single_text_turn"; passed = scenario_single_text_turn sw };
    { name = "parallel_tool_calls"; passed = scenario_parallel_tool_calls sw };
    {
      name = "sequential_tool_calls";
      passed = scenario_sequential_tool_calls sw;
    };
    { name = "tool_error"; passed = scenario_tool_error sw };
    (* mid_stream_cancel manages its own switch internally *)
    { name = "mid_stream_cancel"; passed = scenario_mid_stream_cancel () };
    { name = "steering_message"; passed = scenario_steering_message sw };
    { name = "follow_up_message"; passed = scenario_follow_up_message sw };
  ]

(** Run a single named scenario. Returns a list with one result, or an error
    message if the name is not recognised. *)
let run_named_scenario name sw =
  match name with
  | "single_text_turn" -> [ { name; passed = scenario_single_text_turn sw } ]
  | "parallel_tool_calls" ->
      [ { name; passed = scenario_parallel_tool_calls sw } ]
  | "sequential_tool_calls" ->
      [ { name; passed = scenario_sequential_tool_calls sw } ]
  | "tool_error" -> [ { name; passed = scenario_tool_error sw } ]
  | "mid_stream_cancel" -> [ { name; passed = scenario_mid_stream_cancel () } ]
  | "steering_message" -> [ { name; passed = scenario_steering_message sw } ]
  | "follow_up_message" -> [ { name; passed = scenario_follow_up_message sw } ]
  | _ ->
      Log.err (fun m -> m "unknown scenario: %s" name);
      Log.err (fun m ->
          m "available: single_text_turn | parallel_tool_calls | \
             sequential_tool_calls | tool_error | mid_stream_cancel | \
             steering_message | follow_up_message");
      exit 1

(** {1 Entry point} *)

let () =
  Driver_log.setup ();
  let argv = Sys.argv in
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let results =
    if Array.length argv > 1 then run_named_scenario argv.(1) sw
    else run_all_scenarios sw
  in
  Printf.printf "\n=== Summary ===\n%!";
  List.iter
    (fun { name; passed } ->
      Printf.printf "  %-30s %s\n%!" name (if passed then "PASS" else "FAIL"))
    results;
  let all_passed = List.for_all (fun { passed; _ } -> passed) results in
  if all_passed then exit 0 else exit 1
