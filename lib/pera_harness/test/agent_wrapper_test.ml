open Containers [@@warning "-33"]
open Pera_harness
open Pera_core_test_util

(* ── Inlined helpers (from agent_loop_helpers, not in public library) ────── *)

let test_model =
  Pera_types.Types.{ id = "test-model"; protocol = "faux"; context_window = 200_000 }

let test_options =
  Pera_connector.Connector.
    {
      max_tokens = 1024;
      temperature = None;
      cache_policy = Pera_types.Types.No_cache;
      cache_ttl = Pera_types.Types.Five_minutes;
      thinking_budget_tokens = None;
    }

let default_convert_to_llm msgs =
  List.map Pera_core.Agent_types.to_provider_message msgs

let make_assistant_message ?(stop_reason = Pera_types.Types.EndTurn) content =
  Pera_types.Types.
    {
      content;
      stop_reason;
      provenance =
        {
          protocol = "faux";
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

let make_text_assistant_message text =
  make_assistant_message [ Pera_types.Types.AText text ]

let make_tool_use_assistant_message tool_calls =
  let content = List.map (fun tc -> Pera_types.Types.AToolCall tc) tool_calls in
  make_assistant_message ~stop_reason:Pera_types.Types.ToolUse content

let make_tool_call id name arguments = Pera_types.Types.{ id; name; arguments }

let make_user_agent_message text =
  let um = Pera_types.Types.{ role = "user"; content = [ UText text ] } in
  Pera_core.Agent_types.Real (Pera_connector.Connector.UserMessage um)

let make_text_turn_script text =
  let partial_msg = make_text_assistant_message "" in
  let final_msg = make_text_assistant_message text in
  Faux_provider.Turn
    Faux_provider.
      {
        events =
          [
            Pera_types.Types.AME_text_start { partial = partial_msg };
            Pera_types.Types.AME_text_delta { text; partial = final_msg };
          ];
        final = final_msg;
      }

let make_tool_use_turn_script tool_calls =
  let final_msg = make_tool_use_assistant_message tool_calls in
  let first_tc =
    List.nth_opt tool_calls 0
    |> Option.get_exn_or
         "make_tool_use_turn_script: tool_calls must be non-empty"
  in
  Faux_provider.Turn
    Faux_provider.
      {
        events =
          [
            Pera_types.Types.AME_tool_call_start
              {
                index = 0;
                id = first_tc.Pera_types.Types.id;
                name = first_tc.Pera_types.Types.name;
                partial = make_tool_use_assistant_message tool_calls;
              };
          ];
        final = final_msg;
      }

let empty_schema =
  Pera_connector.Json_schema.object_ ~properties:[] ~required:[] ()

(* ── Config helper ───────────────────────────────────────────────────────── *)

let make_config ?(tools = []) stream_fn =
  Pera_core.Agent_loop.
    {
      model = test_model;
      system = "test system";
      options = test_options;
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
      get_follow_up_messages = None;
    }

(** Collect all events delivered to a subscriber into a list ref. *)
let collect_into buf event = buf := !buf @ [ event ]

(* ── Tests ───────────────────────────────────────────────────────────────── *)

(** Test 1: subscriber receives all events *)
let test_subscriber_receives_all_events () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "hello" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  let received = ref [] in
  let _unsub = Agent_wrapper.subscribe wrapper (collect_into received) in
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "hi" ];
  let has_agent_start =
    List.exists
      (function Pera_core.Agent_types.AE_agent_start -> true | _ -> false)
      !received
  in
  let has_agent_end =
    List.exists
      (function Pera_core.Agent_types.AE_agent_end _ -> true | _ -> false)
      !received
  in
  Alcotest.(check bool) "received AE_agent_start" true has_agent_start;
  Alcotest.(check bool) "received AE_agent_end" true has_agent_end;
  Alcotest.(check bool)
    "received at least 3 events" true
    (List.length !received >= 3)

(** Test 2: multiple subscribers both receive every event *)
let test_multiple_subscribers_all_notified () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "world" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  let buf1 = ref [] in
  let buf2 = ref [] in
  let _u1 = Agent_wrapper.subscribe wrapper (collect_into buf1) in
  let _u2 = Agent_wrapper.subscribe wrapper (collect_into buf2) in
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "go" ];
  Alcotest.(check bool)
    "both subscribers got events" true
    (List.length !buf1 > 0 && List.length !buf2 > 0);
  Alcotest.(check int)
    "both subscribers received same count" (List.length !buf1)
    (List.length !buf2)

(** Test 3: unsubscribing stops notifications *)
let test_unsubscribe_stops_notifications () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "test" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  let called = ref false in
  let unsub = Agent_wrapper.subscribe wrapper (fun _event -> called := true) in
  unsub ();
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "hi" ];
  Alcotest.(check bool) "unsubscribed callback not called" false !called

(** Test 4: concurrent sends both complete (neither rejected) *)
let test_concurrent_sends_both_complete () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script1 = make_text_turn_script "first" in
  let script2 = make_text_turn_script "second" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  let completed1 = ref false in
  let completed2 = ref false in
  Eio.Fiber.both
    (fun () ->
      Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "msg1" ];
      completed1 := true)
    (fun () ->
      Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "msg2" ];
      completed2 := true);
  Alcotest.(check bool) "first send completed" true !completed1;
  Alcotest.(check bool) "second send completed" true !completed2

(** Test 5: two sequential sends produce events from both turns in order *)
let test_second_send_runs_after_first_completes () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script1 = make_text_turn_script "reply1" in
  let script2 = make_text_turn_script "reply2" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  let events_turn1 = ref [] in
  let events_turn2 = ref [] in
  let current_buf = ref events_turn1 in
  let _unsub =
    Agent_wrapper.subscribe wrapper (fun event ->
        !current_buf := !(!current_buf) @ [ event ])
  in
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "first" ];
  current_buf := events_turn2;
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "second" ];
  let count_agent_end events =
    List.length
      (List.filter
         (function Pera_core.Agent_types.AE_agent_end _ -> true | _ -> false)
         events)
  in
  Alcotest.(check int) "turn1 has agent_end" 1 (count_agent_end !events_turn1);
  Alcotest.(check int) "turn2 has agent_end" 1 (count_agent_end !events_turn2)

(** Test 6: is_streaming is true during send (checked from subscriber) *)
let test_is_streaming_true_during_send () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "ok" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  let seen_streaming = ref false in
  let _unsub =
    Agent_wrapper.subscribe wrapper (fun _event ->
        if Agent_wrapper.is_streaming wrapper then seen_streaming := true)
  in
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "hi" ];
  Alcotest.(check bool) "is_streaming was true during send" true !seen_streaming

(** Test 7: is_streaming is false before and after send *)
let test_is_streaming_false_before_and_after_send () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "ok" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  Alcotest.(check bool)
    "is_streaming false before send" false
    (Agent_wrapper.is_streaming wrapper);
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "hi" ];
  Alcotest.(check bool)
    "is_streaming false after send" false
    (Agent_wrapper.is_streaming wrapper)

(** Test 8: pending_tool_call_names updated at AE_tool_execution_start *)
let test_pending_tool_calls_updated_during_execution () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let tool =
    Pera_core.Agent_types.Tool.create ~name:"echo" ~description:"echo tool"
      ~schema:empty_schema ~parallel_safe:true
      ~execute:(fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
        Ok (Pera_core.Agent_types.Tool_text "done"))
  in
  let tc = make_tool_call "tc-1" "echo" (`Assoc []) in
  let script1 = make_tool_use_turn_script [ tc ] in
  let script2 = make_text_turn_script "finished" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~tools:[ tool ] stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  let seen_pending = ref [] in
  let _unsub =
    Agent_wrapper.subscribe wrapper (fun event ->
        match event with
        | Pera_core.Agent_types.AE_tool_execution_start _ ->
            seen_pending := Agent_wrapper.pending_tool_call_names wrapper
        | _ -> ())
  in
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "go" ];
  Alcotest.(check bool)
    "echo in pending at tool_execution_start" true
    (List.mem ~eq:String.equal "echo" !seen_pending)

(** Test 9: pending_tool_calls keyed by id for duplicate tool names. Two
    parallel calls to the same tool name (distinct tool_call_ids). A barrier
    ensures both tools start before either completes, so we can verify that
    ending one leaves the other in pending_tool_call_names. This proves removal
    is by tool_call_id, not by tool_name. *)
let test_pending_tool_calls_keyed_by_id_for_duplicate_names () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  (* Barrier: both tool calls signal "started", then both wait for release. *)
  let started_count = ref 0 in
  let release_p, release_r = Eio.Promise.create () in
  let tool =
    Pera_core.Agent_types.Tool.create ~name:"echo" ~description:"echo tool"
      ~schema:empty_schema ~parallel_safe:true
      ~execute:(fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
        incr started_count;
        (* Once both tools have started, release the barrier from the
              main fiber so both can complete. *)
        if Int.equal !started_count 2 then Eio.Promise.resolve release_r ();
        (* Wait for the release signal before returning — this keeps
              both tools "in flight" simultaneously. *)
        Eio.Promise.await release_p;
        Ok (Pera_core.Agent_types.Tool_text "done"))
  in
  let tc1 = make_tool_call "tc-a" "echo" (`Assoc []) in
  let tc2 = make_tool_call "tc-b" "echo" (`Assoc []) in
  let final_msg = make_tool_use_assistant_message [ tc1; tc2 ] in
  let tool_use_script =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Pera_types.Types.AME_tool_call_start
                {
                  index = 0;
                  id = "tc-a";
                  name = "echo";
                  partial = make_tool_use_assistant_message [ tc1; tc2 ];
                };
            ];
          final = final_msg;
        }
  in
  let end_script = make_text_turn_script "done" in
  let stream_fn =
    Faux_provider.stream_fn_of_scripts [ tool_use_script; end_script ]
  in
  let config = make_config ~tools:[ tool ] stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  let end_count = ref 0 in
  let pending_after_first_end = ref [] in
  let _unsub =
    Agent_wrapper.subscribe wrapper (fun event ->
        match event with
        | Pera_core.Agent_types.AE_tool_execution_end _ ->
            incr end_count;
            if Int.equal !end_count 1 then
              pending_after_first_end :=
                Agent_wrapper.pending_tool_call_names wrapper
        | _ -> ())
  in
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "go" ];
  (* Both ends must have fired *)
  Alcotest.(check int) "two end events" 2 !end_count;
  (* After all ends, pending must be empty *)
  Alcotest.(check (list string))
    "pending empty after all ends" []
    (Agent_wrapper.pending_tool_call_names wrapper);
  (* After the FIRST end, the second tool must still be pending.
     This proves removal is by id (not by name — which would clear both). *)
  Alcotest.(check bool)
    "echo still pending after first end (id-keyed removal)" true
    (List.mem ~eq:String.equal "echo" !pending_after_first_end)

(** Test 10: current_messages updated from AE_agent_end *)
let test_current_messages_updated_after_send () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "reply" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  Agent_wrapper.send wrapper ~messages:[ make_user_agent_message "hi" ];
  let msgs = Agent_wrapper.current_messages wrapper in
  Alcotest.(check bool)
    "current_messages non-empty after send" true
    (List.length msgs >= 2)

(** Test 11: current_messages empty before first send *)
let test_current_messages_empty_before_first_send () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let stream_fn = Faux_provider.stream_fn_of_scripts [] in
  let config = make_config stream_fn in
  let wrapper = Agent_wrapper.create ~config ~sw in
  Alcotest.(check int)
    "current_messages empty before send" 0
    (List.length (Agent_wrapper.current_messages wrapper))

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "agent_wrapper"
    [
      ( "subscriptions",
        [
          Alcotest.test_case "subscriber receives all events" `Quick
            test_subscriber_receives_all_events;
          Alcotest.test_case "multiple subscribers all notified" `Quick
            test_multiple_subscribers_all_notified;
          Alcotest.test_case "unsubscribe stops notifications" `Quick
            test_unsubscribe_stops_notifications;
        ] );
      ( "concurrency",
        [
          Alcotest.test_case "concurrent sends both complete" `Quick
            test_concurrent_sends_both_complete;
          Alcotest.test_case "second send runs after first completes" `Quick
            test_second_send_runs_after_first_completes;
        ] );
      ( "observable_state",
        [
          Alcotest.test_case "is_streaming true during send" `Quick
            test_is_streaming_true_during_send;
          Alcotest.test_case "is_streaming false before and after send" `Quick
            test_is_streaming_false_before_and_after_send;
          Alcotest.test_case
            "pending_tool_calls updated at tool_execution_start" `Quick
            test_pending_tool_calls_updated_during_execution;
          Alcotest.test_case
            "pending_tool_calls keyed by id for duplicate names" `Quick
            test_pending_tool_calls_keyed_by_id_for_duplicate_names;
          Alcotest.test_case "current_messages updated after send" `Quick
            test_current_messages_updated_after_send;
          Alcotest.test_case "current_messages empty before first send" `Quick
            test_current_messages_empty_before_first_send;
        ] );
    ]
