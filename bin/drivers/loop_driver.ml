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

(** Default convert_to_llm: project agent messages to provider messages. *)
let default_convert_to_llm msgs = List.map Agent_types.to_provider_message msgs

(** Default model for loop calls. *)
let test_model =
  Types.{ id = "faux-model"; api = "faux"; context_window = 200_000 }

(** Default options for loop calls. *)
let test_options =
  Provider.
    {
      max_tokens = 1024;
      temperature = None;
      cache_policy = Types.No_cache;
      cache_ttl = Types.Five_minutes;
    }

(** Empty JSON schema for tools that take no args. *)
let empty_schema = Json_schema.object_ ~properties:[] ~required:[] ()

(** Build a loop config with the given stream_fn and optional overrides. *)
let make_config ?(tools = []) ?(tool_execution = `Parallel)
    ?(should_stop_after_turn = None) ?(prepare_next_turn = None)
    ?(get_steering_messages = None) ?(get_follow_up_messages = None)
    ?(before_tool_call = None) ?(after_tool_call = None) ?(get_api_key = None)
    ?(transform_context = None) stream_fn =
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
      transform_context;
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
  | Error (err_msg, _stop_err) ->
      Printf.printf "  => stream error: %s\n%!" err_msg;
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
  let echo_tool = Conversation_driver_helpers.echo_tool in
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
    Agent_types.Tool.create ~name:"counter"
      ~description:"Record invocation order."
      ~schema:
        (Json_schema.object_
           ~properties:
             [ ("step", Json_schema.object_ ~properties:[] ~required:[] ()) ]
           ~required:[] ())
      ~parallel_safe:false
      ~execute:(fun ~ctx:_ ~args ~sw:_ ~cancel:_ ->
        let step =
          match Yojson.Safe.Util.member "step" args with
          | `Int n -> string_of_int n
          | _ -> "?"
        in
        call_order := !call_order @ [ step ];
        Ok (Agent_types.Tool_text ("step=" ^ step)))
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
    Agent_types.Tool.create ~name:"failing_tool"
      ~description:"Always returns an error."
      ~schema:empty_schema ~parallel_safe:true
      ~execute:(fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
        Error Types.{ message = "intentional failure"; is_user_error = false })
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

(** {1 Scenario 8: should_stop_after_turn_halts_loop} *)

(** should_stop_after_turn returning true on the first call halts the inner loop
    after exactly one turn; the second Faux script is never consumed. *)
let scenario_should_stop_after_turn_halts_loop sw =
  let turn1_msg = make_assistant_message "Turn 1." in
  let turn2_msg = make_assistant_message "Turn 2." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = turn1_msg };
              Types.AME_text_delta { text = "Turn 1."; partial = turn1_msg };
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
              Types.AME_text_delta { text = "Turn 2."; partial = turn2_msg };
            ];
          final = turn2_msg;
        }
  in
  let stop_count = ref 0 in
  let should_stop_after_turn =
    Some
      (fun _ctx ->
        incr stop_count;
        true)
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~should_stop_after_turn stream_fn in
  let messages = [ make_user_agent_message "Go." ] in
  run_scenario ~name:"should_stop_after_turn_halts_loop" ~messages ~sw config
    ~check_result:(fun events _final ->
      let turn_count = count_events is_turn_start events in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    turn_starts=%d stop_calls=%d\n%!" turn_count
        !stop_count;
      Int.equal turn_count 1 && agent_end_last)

(** {1 Scenario 9: before_tool_call_allow} *)

(** before_tool_call returning Allow lets the tool execute normally. *)
let scenario_before_tool_call_allow sw =
  let tc =
    make_tool_call "allow-1" "echo" (`Assoc [ ("text", `String "hello") ])
  in
  let tool_use_msg = make_tool_use_message [ tc ] in
  let followup_msg = make_assistant_message "Echo done." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_tool_call_start
                {
                  index = 0;
                  id = "allow-1";
                  name = "echo";
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
                { text = "Echo done."; partial = followup_msg };
            ];
          final = followup_msg;
        }
  in
  let echo_tool = Conversation_driver_helpers.echo_tool in
  let before_tool_call = Some (fun _ctx -> Agent_types.Allow) in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~tools:[ echo_tool ] ~before_tool_call stream_fn in
  let messages = [ make_user_agent_message "Echo hello." ] in
  run_scenario ~name:"before_tool_call_allow" ~messages ~sw config
    ~check_result:(fun events _final ->
      let has_success =
        List.exists
          (function
            | Agent_types.AE_tool_execution_end { is_error = false; _ } -> true
            | _ -> false)
          events
      in
      let agent_end_last = check_agent_end_is_last events in
      has_success && agent_end_last)

(** {1 Scenario 10: before_tool_call_deny} *)

(** before_tool_call returning Deny emits AE_tool_execution_end with
    is_error=true and the deny message as result; the loop then continues with
    the next turn. AE_tool_execution_start is not emitted because the deny
    short-circuits before step 4. *)
let scenario_before_tool_call_deny sw =
  let tc =
    make_tool_call "deny-1" "echo" (`Assoc [ ("text", `String "hello") ])
  in
  let tool_use_msg = make_tool_use_message [ tc ] in
  let followup_msg = make_assistant_message "Tool was blocked." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_tool_call_start
                {
                  index = 0;
                  id = "deny-1";
                  name = "echo";
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
                { text = "Tool was blocked."; partial = followup_msg };
            ];
          final = followup_msg;
        }
  in
  let echo_tool = Conversation_driver_helpers.echo_tool in
  let before_tool_call =
    Some (fun _ctx -> Agent_types.Deny "blocked by policy")
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~tools:[ echo_tool ] ~before_tool_call stream_fn in
  let messages = [ make_user_agent_message "Echo hello." ] in
  run_scenario ~name:"before_tool_call_deny" ~messages ~sw config
    ~check_result:(fun events _final ->
      let has_deny_error =
        List.exists
          (function
            | Agent_types.AE_tool_execution_end
                { is_error = true; result = `String s; _ } ->
                String.equal s "blocked by policy"
            | _ -> false)
          events
      in
      let has_no_start = not (List.exists is_tool_start events) in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    has_deny_error=%b has_no_start=%b\n%!" has_deny_error
        has_no_start;
      has_deny_error && has_no_start && agent_end_last)

(** {1 Scenario 11: after_tool_call_fires} *)

(** after_tool_call is called once after the echo tool executes; the recorded
    tool_call_id matches. *)
let scenario_after_tool_call_fires sw =
  let tc =
    make_tool_call "after-1" "echo" (`Assoc [ ("text", `String "hi") ])
  in
  let tool_use_msg = make_tool_use_message [ tc ] in
  let followup_msg = make_assistant_message "Done." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_tool_call_start
                {
                  index = 0;
                  id = "after-1";
                  name = "echo";
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
              Types.AME_text_delta { text = "Done."; partial = followup_msg };
            ];
          final = followup_msg;
        }
  in
  let echo_tool = Conversation_driver_helpers.echo_tool in
  let recorded_ids = ref [] in
  let after_tool_call =
    Some
      (fun (ctx : unit Agent_loop.after_tool_call_ctx) ->
        recorded_ids := !recorded_ids @ [ ctx.tool_call.Pera_types.Types.id ])
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~tools:[ echo_tool ] ~after_tool_call stream_fn in
  let messages = [ make_user_agent_message "Echo hi." ] in
  run_scenario ~name:"after_tool_call_fires" ~messages ~sw config
    ~check_result:(fun events _final ->
      let ids = !recorded_ids in
      Printf.printf "    recorded_ids=[%s]\n%!" (String.concat ";" ids);
      let agent_end_last = check_agent_end_is_last events in
      (match ids with [ id ] -> String.equal id "after-1" | _ -> false)
      && agent_end_last)

(** {1 Scenario 12: transform_context_applied} *)

(** transform_context appends a synthetic user message before every LLM call;
    the injected message appears in the first recorded provider context. *)
let scenario_transform_context_applied sw =
  let final_msg = make_assistant_message "Done." in
  let script =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = final_msg };
              Types.AME_text_delta { text = "Done."; partial = final_msg };
            ];
          final = final_msg;
        }
  in
  let injected =
    Agent_types.Real
      (Provider.UserMessage
         Types.{ role = "user"; content = [ Types.UText "INJECTED" ] })
  in
  let transform_context = Some (fun msgs -> msgs @ [ injected ]) in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config ~transform_context stream_fn in
  let messages = [ make_user_agent_message "Test." ] in
  run_scenario ~name:"transform_context_applied" ~messages ~sw config
    ~check_result:(fun _events _final ->
      let contexts = Faux_provider.recorded_contexts () in
      match contexts with
      | [] ->
          Printf.printf "    no recorded contexts\n%!";
          false
      | ctx :: _ ->
          let found =
            List.exists
              (function
                | Provider.UserMessage um ->
                    List.exists
                      (function
                        | Types.UText s -> String.equal s "INJECTED"
                        | _ -> false)
                      um.Types.content
                | _ -> false)
              ctx.Provider.messages
          in
          Printf.printf "    injected_found=%b\n%!" found;
          found)

(** {1 Scenario 13: prepare_next_turn_update} *)

(** prepare_next_turn returning Some with a model override causes the second LLM
    call to use the updated model. Verified by wrapping stream_fn to capture
    each model argument (Faux_provider only records contexts, not models). A
    steering message forces the second turn so that prepare_next_turn actually
    fires. *)
let scenario_prepare_next_turn_update sw =
  let turn1_msg = make_assistant_message "Turn 1." in
  let turn2_msg = make_assistant_message "Turn 2." in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_text_start { partial = turn1_msg };
              Types.AME_text_delta { text = "Turn 1."; partial = turn1_msg };
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
              Types.AME_text_delta { text = "Turn 2."; partial = turn2_msg };
            ];
          final = turn2_msg;
        }
  in
  let recorded_models : Types.model list ref = ref [] in
  let base_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let stream_fn ~model ~context ~options ~sw =
    recorded_models := !recorded_models @ [ model ];
    base_fn ~model ~context ~options ~sw
  in
  let prepare_next_turn =
    Some
      (fun _ctx ->
        Some
          Agent_types.
            {
              messages = None;
              model =
                Some
                  Types.
                    {
                      id = "prepared-model";
                      api = "faux";
                      context_window = 200_000;
                    };
              thinking = None;
            })
  in
  let steering_count = ref 0 in
  let get_steering_messages =
    Some
      (fun () ->
        incr steering_count;
        if Int.equal !steering_count 1 then
          [ make_user_agent_message "continue" ]
        else [])
  in
  let config =
    make_config ~prepare_next_turn ~get_steering_messages stream_fn
  in
  let messages = [ make_user_agent_message "Start." ] in
  run_scenario ~name:"prepare_next_turn_update" ~messages ~sw config
    ~check_result:(fun events _final ->
      let models = !recorded_models in
      Printf.printf "    model_calls=%d\n%!" (List.length models);
      match models with
      | [ _; second ] ->
          Printf.printf "    second_model=%s\n%!" second.Types.id;
          let agent_end_last = check_agent_end_is_last events in
          String.equal second.Types.id "prepared-model" && agent_end_last
      | _ -> false)

(** {1 Scenario 14: thinking_blocks} *)

(** A Faux turn emitting AME_thinking_start + AME_thinking_delta flows through
    the loop and appears as AThinking content in AE_message_end. *)
let scenario_thinking_blocks sw =
  let partial_msg = make_assistant_message "" in
  let final_msg =
    Types.
      {
        content =
          [
            AThinking { text = "thinking step"; signature = None };
            AText "answer";
          ];
        stop_reason = EndTurn;
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
  in
  let script =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Types.AME_thinking_start { partial = partial_msg };
              Types.AME_thinking_delta
                { text = "thinking step"; partial = partial_msg };
              Types.AME_text_start { partial = partial_msg };
              Types.AME_text_delta { text = "answer"; partial = final_msg };
            ];
          final = final_msg;
        }
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let messages = [ make_user_agent_message "Reason carefully." ] in
  run_scenario ~name:"thinking_blocks" ~messages ~sw config
    ~check_result:(fun events _final ->
      let has_thinking_in_message =
        List.exists
          (function
            | Agent_types.AE_message_end
                { message = Real (Provider.AssistantMessage am) } ->
                List.exists
                  (function Types.AThinking _ -> true | _ -> false)
                  am.content
            | _ -> false)
          events
      in
      let agent_end_last = check_agent_end_is_last events in
      Printf.printf "    thinking_in_message=%b\n%!" has_thinking_in_message;
      has_thinking_in_message && agent_end_last)

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
    {
      name = "should_stop_after_turn_halts_loop";
      passed = scenario_should_stop_after_turn_halts_loop sw;
    };
    {
      name = "before_tool_call_allow";
      passed = scenario_before_tool_call_allow sw;
    };
    {
      name = "before_tool_call_deny";
      passed = scenario_before_tool_call_deny sw;
    };
    {
      name = "after_tool_call_fires";
      passed = scenario_after_tool_call_fires sw;
    };
    {
      name = "transform_context_applied";
      passed = scenario_transform_context_applied sw;
    };
    {
      name = "prepare_next_turn_update";
      passed = scenario_prepare_next_turn_update sw;
    };
    { name = "thinking_blocks"; passed = scenario_thinking_blocks sw };
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
  | "should_stop_after_turn_halts_loop" ->
      [ { name; passed = scenario_should_stop_after_turn_halts_loop sw } ]
  | "before_tool_call_allow" ->
      [ { name; passed = scenario_before_tool_call_allow sw } ]
  | "before_tool_call_deny" ->
      [ { name; passed = scenario_before_tool_call_deny sw } ]
  | "after_tool_call_fires" ->
      [ { name; passed = scenario_after_tool_call_fires sw } ]
  | "transform_context_applied" ->
      [ { name; passed = scenario_transform_context_applied sw } ]
  | "prepare_next_turn_update" ->
      [ { name; passed = scenario_prepare_next_turn_update sw } ]
  | "thinking_blocks" -> [ { name; passed = scenario_thinking_blocks sw } ]
  | _ ->
      Log.err (fun m -> m "unknown scenario: %s" name);
      Log.err (fun m ->
          m
            "available: single_text_turn | parallel_tool_calls | \
             sequential_tool_calls | tool_error | mid_stream_cancel | \
             steering_message | follow_up_message | \
             should_stop_after_turn_halts_loop | before_tool_call_allow | \
             before_tool_call_deny | after_tool_call_fires | \
             transform_context_applied | prepare_next_turn_update | \
             thinking_blocks");
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
