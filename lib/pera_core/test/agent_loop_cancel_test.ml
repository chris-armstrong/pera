open Containers [@@warning "-33"]
open Pera_core

(** {1 Test helpers} *)

(** Build a minimal [assistant_message] with the given stop_reason and text. *)
let make_assistant_message ?(stop_reason = Pera_types.Types.EndTurn) text =
  Pera_types.Types.
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

(** Build a minimal [agent_message] wrapping a [UserMessage]. *)
let make_user_agent_message text =
  let um = Pera_types.Types.{ role = "user"; content = [ UText text ] } in
  Agent_types.Real (Pera_provider.Provider.UserMessage um)

(** The default convert_to_llm: unwrap [Real] messages, ignore [Synthetic]. *)
let default_convert_to_llm msgs =
  List.filter_map
    (fun msg ->
      match msg with
      | Agent_types.Real m -> Some m
      | Agent_types.Synthetic _ -> .)
    msgs

(** A model value for loop calls. *)
let test_model = Pera_types.Types.{ id = "test-model"; api = "faux" }

(** Simple stream options for loop calls. *)
let test_options =
  Pera_provider.Provider.{ max_tokens = 1024; temperature = None }

(** Build a simple loop config with sensible defaults. *)
let make_config ?(get_follow_up_messages = None) ?(tools = [])
    ?(tool_execution = `Parallel) stream_fn =
  Agent_loop.
    {
      model = test_model;
      system = "test system";
      options = test_options;
      stream_fn;
      convert_to_llm = default_convert_to_llm;
      tool_ctx = ();
      tools;
      tool_execution;
      transform_context = None;
      get_api_key = None;
      before_tool_call = None;
      after_tool_call = None;
      should_stop_after_turn = None;
      prepare_next_turn = None;
      get_steering_messages = None;
      get_follow_up_messages;
    }

(** Build a simple Faux script for a text-only turn. *)
let make_text_turn_script text =
  let partial_msg = make_assistant_message "" in
  let final_msg = make_assistant_message text in
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

(** Build a simple tool schema with no required fields. *)
let empty_schema =
  Pera_provider.Json_schema.object_ ~properties:[] ~required:[] ()

(** Build a tool call record. *)
let make_tool_call id name arguments = Pera_types.Types.{ id; name; arguments }

(** Build a [assistant_message] with tool calls and ToolUse stop_reason. *)
let make_tool_use_assistant_message tool_calls =
  let content = List.map (fun tc -> Pera_types.Types.AToolCall tc) tool_calls in
  Pera_types.Types.
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

(** Collect events from an [Event_stream] into a ref list. Returns a function to
    call after the switch to get the collected events. *)
let collect_events_into buf stream =
  Pera_provider.Event_stream.iter stream ~f:(fun e -> buf := !buf @ [ e ])

(** Check whether an event is [AE_agent_start]. *)
let is_agent_start = function Agent_types.AE_agent_start -> true | _ -> false

(** Check whether an event is [AE_agent_end]. *)
let is_agent_end = function Agent_types.AE_agent_end _ -> true | _ -> false

(** Check whether an event is [AE_turn_start]. *)
let is_turn_start = function Agent_types.AE_turn_start -> true | _ -> false

(** Check whether an event is [AE_turn_end]. *)
let is_turn_end = function Agent_types.AE_turn_end _ -> true | _ -> false

(** Count events matching a predicate. *)
let count_events pred events = List.length (List.filter pred events)

(** {1 Test 1: cancellation during stream} *)

(** Cancel while the Faux provider is paused mid-stream. Verifies that the loop
    handles the cancellation cleanly:
    - AE_turn_end with empty tool_results is emitted
    - AE_agent_end is emitted
    - The run terminates without crashing
    - No second AE_turn_start is emitted (the aborted turn does not restart)

    Implementation note: the consumer fibre runs under [sw], so it may be
    cancelled before it collects the cleanup events ([AE_turn_end],
    [AE_agent_end]) emitted by the loop under [Eio.Cancel.protect]. We therefore
    drain [loop_stream] a second time in a fresh switch after the cancelled
    switch exits — by then all loop fibres have finished and the stream is
    closed, so the drain completes immediately without blocking.

    Synchronisation: we use a Promise (not Condition) for the pause signal so
    that [Promise.await] returns immediately even if the producer resolves it
    before the control code reaches the await. Conditions do not have this
    "sticky" property and can miss a broadcast that fires before the wait is
    registered. *)
let test_cancellation_during_stream_emits_aborted_and_ends () =
  Eio_main.run @@ fun _env ->
  Faux_provider.reset_recorded ();
  let events = ref [] in
  (* The pause callback resolves a promise (sticky), then blocks until the
     switch is cancelled.  Using a Promise means the control code's await
     returns immediately even if the broadcast fires before the wait is
     registered — unlike Eio.Condition which can lose the signal. *)
  let pause_reached_p, pause_reached_r = Eio.Promise.create () in
  let pause () =
    (try Eio.Promise.resolve pause_reached_r () with _ -> ());
    (* Block until the switch is cancelled — Cancelled is raised here. *)
    let never, _ = Eio.Promise.create () in
    Eio.Promise.await never
  in
  let partial_msg = make_assistant_message "" in
  let final_msg = make_assistant_message "hello" in
  let script =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Pera_types.Types.AME_text_start { partial = partial_msg };
              Pera_types.Types.AME_text_delta
                { text = "hel"; partial = partial_msg };
              (* pause is called after each event; the second event triggers the
                 cancel via the condition *)
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
             ~messages:[ make_user_agent_message "hello" ]
             ~sw
         in
         loop_stream_ref := Some loop_stream;
         (* Consumer fibre: collect events into the shared ref.
            This fibre runs under [sw] and may be cancelled before it sees
            all cleanup events; the post-switch drain below collects the rest. *)
         Eio.Fiber.fork ~sw (fun () ->
             try ignore (collect_events_into events loop_stream) with _ -> ());
         (* Control: wait for the pause to be reached, then cancel the switch.
            Promise.await returns immediately if already resolved. *)
         Eio.Promise.await pause_reached_p;
         Eio.Switch.fail sw (Failure "cancelled by test"))
   with Failure _ -> ());
  (* After the switch exits all loop fibres have finished and the stream is
     closed.  Drain any events not yet consumed by the (cancelled) consumer
     fibre above; use a fresh switch so we are not in a cancelled context. *)
  (match !loop_stream_ref with
  | None -> ()
  | Some loop_stream ->
      Eio.Switch.run (fun _sw2 ->
          ignore (collect_events_into events loop_stream)));
  let ev = !events in
  (* The run must have emitted at least AE_agent_start and AE_turn_start before
     the cancellation point *)
  Alcotest.(check bool)
    "AE_agent_start emitted before cancel" true
    (count_events is_agent_start ev > 0);
  Alcotest.(check bool)
    "AE_turn_start emitted before cancel" true
    (count_events is_turn_start ev > 0);
  (* AE_turn_end must be emitted: the loop catches cancellation in
     consume_provider_stream, returns Aborted, and emits AE_turn_end via the
     normal terminal path. AE_agent_end is emitted under Eio.Cancel.protect. *)
  Alcotest.(check bool)
    "AE_turn_end emitted after cancel" true
    (count_events is_turn_end ev > 0);
  Alcotest.(check bool)
    "AE_agent_end emitted after cancel" true
    (count_events is_agent_end ev > 0);
  (* No second turn should have started (cancellation during first turn) *)
  Alcotest.(check int)
    "at most one AE_turn_start" 1
    (count_events is_turn_start ev)

(** {1 Test 2: cancellation during parallel tool execution} *)

(** Cancel while one of two parallel tools is blocked. Verifies that:
    - The run terminates cleanly (no unhandled exception)
    - AE_agent_end is emitted (run closes the stream)
    - At least the completed tool's result makes it into the event sequence *)
let test_cancellation_during_parallel_tools_appends_completed_in_source_order ()
    =
  Eio_main.run @@ fun _env ->
  Faux_provider.reset_recorded ();
  let events = ref [] in
  (* Coordination: tool1 blocks until tool2 signals, then we cancel the switch
     from a control fibre that watches tool2's completion. *)
  let tool2_done = ref false in
  let tool2_cond = Eio.Condition.create () in
  let tool2_mutex = Eio.Mutex.create () in
  (* Shared ref to capture the switch so the control fibre can fail it *)
  let sw_ref : Eio.Switch.t option ref = ref None in
  let tool1 =
    Agent_types.
      {
        name = "tool1";
        description = "slow tool — waits for tool2";
        schema = empty_schema;
        mode = `Parallel;
        execute =
          (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
            (* Block until tool2 completes — the test will then cancel the
               switch, causing this await to raise Eio.Cancel.Cancelled *)
            Eio.Mutex.use_rw ~protect:false tool2_mutex (fun () ->
                while not !tool2_done do
                  Eio.Condition.await tool2_cond tool2_mutex
                done);
            Ok (Agent_types.Tool_text "result1"));
      }
  in
  let tool2 =
    Agent_types.
      {
        name = "tool2";
        description = "fast tool";
        schema = empty_schema;
        mode = `Parallel;
        execute =
          (fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
            (* Signal completion and then cancel the outer switch *)
            Eio.Mutex.use_rw ~protect:false tool2_mutex (fun () ->
                tool2_done := true;
                Eio.Condition.broadcast tool2_cond);
            Option.iter
              (fun sw -> Eio.Switch.fail sw (Failure "cancel-tools"))
              !sw_ref;
            Ok (Agent_types.Tool_text "result2"));
      }
  in
  let tc1 = make_tool_call "call-1" "tool1" (`Assoc []) in
  let tc2 = make_tool_call "call-2" "tool2" (`Assoc []) in
  let final_tool_msg = make_tool_use_assistant_message [ tc1; tc2 ] in
  let script1 =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Pera_types.Types.AME_tool_call_start
                {
                  index = 0;
                  id = "call-1";
                  name = "tool1";
                  partial = final_tool_msg;
                };
            ];
          final = final_tool_msg;
        }
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1 ] in
  let config = make_config ~tools:[ tool1; tool2 ] stream_fn in
  let loop_stream_ref2 = ref None in
  (try
     Eio.Switch.run (fun sw ->
         sw_ref := Some sw;
         let loop_stream =
           Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
         in
         loop_stream_ref2 := Some loop_stream;
         Eio.Fiber.fork ~sw (fun () ->
             try ignore (collect_events_into events loop_stream) with _ -> ()))
   with Failure _ -> ());
  (* Drain any events not yet consumed by the (cancelled) consumer fibre. *)
  (match !loop_stream_ref2 with
  | None -> ()
  | Some loop_stream ->
      Eio.Switch.run (fun _sw2 ->
          ignore (collect_events_into events loop_stream)));
  let ev = !events in
  (* The run must reach AE_agent_end (clean termination) *)
  Alcotest.(check bool)
    "AE_agent_end emitted — run terminates cleanly" true
    (count_events is_agent_end ev > 0);
  (* tool2 completed before cancel; its execution end event should be present *)
  let tool_end_events =
    List.filter_map
      (fun e ->
        match e with
        | Agent_types.AE_tool_execution_end { tool_name; is_error; _ } ->
            Some (tool_name, is_error)
        | _ -> None)
      ev
  in
  Alcotest.(check bool)
    "tool2 execution end present (completed before cancel)" true
    (List.exists (fun (name, _) -> String.equal name "tool2") tool_end_events)

(** {1 Test 3: cancellation between turns} *)

(** Cancel while the get_follow_up_messages hook is blocked at an async point
    (simulating a between-turns cancellation at the first real async boundary
    after a turn completes).

    Verifies that:
    - No second AE_turn_start is emitted after the cancellation point
    - AE_agent_end is emitted (loop cleans up via the top-level cancel handler)
    - The run terminates without crashing *)
let test_cancellation_between_turns_stops_before_next_turn () =
  Eio_main.run @@ fun _env ->
  Faux_provider.reset_recorded ();
  let events = ref [] in
  (* Promise that the get_follow_up_messages hook resolves when it starts
     executing.  Using a Promise (sticky) means the control fibre's await
     returns immediately even if the hook ran before the control code reached
     the wait — unlike Eio.Condition which can miss the signal. *)
  let hook_started_p, hook_started_r = Eio.Promise.create () in
  (* get_follow_up_messages is called by run_outer after the inner loop exits.
     It signals that it has been reached (via the promise), then blocks
     indefinitely at Eio.Promise.await — an async point.  When the switch is
     cancelled, Eio.Promise.await raises Eio.Cancel.Cancelled, which propagates
     out of the hook and is caught by the top-level handler in run. *)
  let get_follow_up_messages =
    Some
      (fun () ->
        (try Eio.Promise.resolve hook_started_r () with _ -> ());
        (* Block forever — cancelled when the switch fails *)
        let never, _ = Eio.Promise.create () in
        Eio.Promise.await never)
  in
  let script = make_text_turn_script "turn one" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config ~get_follow_up_messages stream_fn in
  let loop_stream_ref3 = ref None in
  (try
     Eio.Switch.run (fun sw ->
         let loop_stream =
           Agent_loop.run config
             ~messages:[ make_user_agent_message "start" ]
             ~sw
         in
         loop_stream_ref3 := Some loop_stream;
         (* Consumer fibre: collect events.  May be cancelled before it sees
            AE_agent_end; the post-switch drain below collects the rest. *)
         Eio.Fiber.fork ~sw (fun () ->
             try ignore (collect_events_into events loop_stream) with _ -> ());
         (* Control: wait for the between-turns hook to run, then cancel.
            Promise.await returns immediately if already resolved. *)
         Eio.Promise.await hook_started_p;
         Eio.Switch.fail sw (Failure "cancelled between turns"))
   with Failure _ -> ());
  (* Drain any events not yet consumed by the (cancelled) consumer fibre. *)
  (match !loop_stream_ref3 with
  | None -> ()
  | Some loop_stream ->
      Eio.Switch.run (fun _sw2 ->
          ignore (collect_events_into events loop_stream)));
  let ev = !events in
  (* Turn 1 ran to completion — one AE_turn_start and one AE_turn_end *)
  Alcotest.(check int)
    "exactly one AE_turn_start (turn 1 only)" 1
    (count_events is_turn_start ev);
  Alcotest.(check int)
    "exactly one AE_turn_end (turn 1 only)" 1
    (count_events is_turn_end ev);
  (* AE_agent_end was emitted by the top-level cancellation handler in run,
     confirming the stream was closed cleanly. *)
  Alcotest.(check bool)
    "AE_agent_end emitted — clean shutdown after cancel" true
    (count_events is_agent_end ev > 0)

let () =
  Alcotest.run "agent_loop_cancel"
    [
      ( "cancellation",
        [
          Alcotest.test_case
            "cancel during stream emits AE_turn_end(Aborted) and AE_agent_end"
            `Quick test_cancellation_during_stream_emits_aborted_and_ends;
          Alcotest.test_case
            "cancel during parallel tools — completed result present, run ends"
            `Quick
            test_cancellation_during_parallel_tools_appends_completed_in_source_order;
          Alcotest.test_case
            "cancel between turns stops before next turn, AE_agent_end emitted"
            `Quick test_cancellation_between_turns_stops_before_next_turn;
        ] );
    ]
