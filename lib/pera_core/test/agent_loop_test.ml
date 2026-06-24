open Containers [@@warning "-33"]
open Pera_core
open Pera_core_test_util
open Agent_loop_helpers

(** Build a minimal loop config with sensible defaults. *)
let make_config ?(transform_context = None) ?(get_api_key = None)
    ?(should_stop_after_turn = None) ?(prepare_next_turn = None)
    ?(get_steering_messages = None) ?(get_follow_up_messages = None) stream_fn =
  Agent_loop.
    {
      model = test_model;
      system = "test system";
      options = test_options;
      stream_fn;
      convert_to_llm = default_convert_to_llm;
      tool_ctx = ();
      tools = [];
      tool_execution = `Parallel;
      transform_context;
      get_api_key;
      before_tool_call = None;
      after_tool_call = None;
      should_stop_after_turn;
      prepare_next_turn;
      get_steering_messages;
      get_follow_up_messages;
    }

(** Check whether an event is [AE_turn_start]. *)
let is_turn_start = function Agent_types.AE_turn_start -> true | _ -> false

(** Check whether an event is [AE_agent_end]. *)
let is_agent_end = function Agent_types.AE_agent_end _ -> true | _ -> false

(** Check whether an event is [AE_agent_start]. *)
let is_agent_start = function Agent_types.AE_agent_start -> true | _ -> false

(** Check whether an event is [AE_turn_end]. *)
let is_turn_end = function Agent_types.AE_turn_end _ -> true | _ -> false

(** Check whether an event is [AE_message_start]. *)
let is_message_start = function
  | Agent_types.AE_message_start _ -> true
  | _ -> false

(** Check whether an event is [AE_message_update]. *)
let is_message_update = function
  | Agent_types.AE_message_update _ -> true
  | _ -> false

(** Check whether an event is [AE_message_end]. *)
let is_message_end = function
  | Agent_types.AE_message_end _ -> true
  | _ -> false

(** {1 Test 1: single text turn lifecycle events} *)

let test_single_text_turn_emits_lifecycle_and_final_messages () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "hello" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config stream_fn in
  let initial_msg = make_user_agent_message "hi" in
  let loop_stream = Agent_loop.run config ~messages:[ initial_msg ] ~sw in
  let events, result = collect_agent_events loop_stream in
  (* Assert event counts *)
  Alcotest.(check int) "one agent_start" 1 (count_events is_agent_start events);
  Alcotest.(check int) "one turn_start" 1 (count_events is_turn_start events);
  Alcotest.(check int)
    "one message_start" 1
    (count_events is_message_start events);
  Alcotest.(check bool)
    "at least one message_update" true
    (count_events is_message_update events > 0);
  Alcotest.(check int) "one message_end" 1 (count_events is_message_end events);
  Alcotest.(check int) "one turn_end" 1 (count_events is_turn_end events);
  Alcotest.(check int) "one agent_end" 1 (count_events is_agent_end events);
  (* Assert order: agent_start < turn_start < message_start < message_end <
     turn_end < agent_end *)
  check_event_order
    [
      ("agent_start", is_agent_start);
      ("turn_start", is_turn_start);
      ("message_start", is_message_start);
      ("message_end", is_message_end);
      ("turn_end", is_turn_end);
      ("agent_end", is_agent_end);
    ]
    events;
  (* Assert final messages: user + assistant *)
  match result with
  | Error (err_msg, _stop_err) ->
      Alcotest.failf "expected Ok result, got Error %s" err_msg
  | Ok final_messages -> (
      Alcotest.(check int) "two final messages" 2 (List.length final_messages);
      let assistant_msg =
        List.nth_opt final_messages 1
        |> Option.get_exn_or "expected second message"
      in
      match assistant_msg with
      | Agent_types.Real (Pera_connector.Connector.AssistantMessage am) -> (
          match am.content with
          | [ Pera_types.Types.AText t ] ->
              Alcotest.(check string) "assistant text" "hello" t
          | _ -> Alcotest.fail "expected AText content")
      | _ -> Alcotest.fail "expected AssistantMessage")

(** {1 Test 2: transform_context applied before convert_to_llm} *)

let test_transform_context_applied_before_convert_to_llm () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "ok" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  (* transform_context drops all but the last message *)
  let transform_context =
    Some
      (fun msgs -> match List.rev msgs with [] -> [] | last :: _ -> [ last ])
  in
  let initial_msgs =
    [
      make_user_agent_message "first message (to be pruned)";
      make_user_agent_message "second message (kept)";
    ]
  in
  let config = make_config ~transform_context stream_fn in
  let loop_stream = Agent_loop.run config ~messages:initial_msgs ~sw in
  let _events, _result = collect_agent_events loop_stream in
  (* Assert: the recorded context saw only the last message *)
  let recorded = Faux_provider.recorded_contexts () in
  Alcotest.(check int) "one recorded context" 1 (List.length recorded);
  let ctx =
    List.nth_opt recorded 0 |> Option.get_exn_or "expected recorded context"
  in
  Alcotest.(check int)
    "recorded context has one message (transform dropped the first)" 1
    (List.length ctx.Pera_connector.Connector.messages);
  match List.nth_opt ctx.Pera_connector.Connector.messages 0 with
  | Some (Pera_connector.Connector.UserMessage { content = [ UText t ]; _ }) ->
      Alcotest.(check string)
        "remaining message is the second one" "second message (kept)" t
  | _ -> Alcotest.fail "expected UserMessage with UText content"

(** {1 Test 3: get_api_key called once per LLM call} *)

let test_get_api_key_called_before_each_llm_call () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let call_count = ref 0 in
  let get_api_key =
    Some
      (fun ~provider:_ ->
        incr call_count;
        None)
  in
  let script = make_text_turn_script "response" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let config = make_config ~get_api_key stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "hello" ] ~sw
  in
  let _events, _result = collect_agent_events loop_stream in
  Alcotest.(check int) "get_api_key called once for one turn" 1 !call_count

(** {1 Test 4: should_stop_after_turn = true terminates after one turn} *)

let test_should_stop_after_turn_true_terminates_run () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  (* Two scripts — but should_stop_after_turn returns true, so only 1 used *)
  let script1 = make_text_turn_script "turn one" in
  let script2 = make_text_turn_script "turn two" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let should_stop_after_turn = Some (fun _ctx -> true) in
  let config = make_config ~should_stop_after_turn stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "go" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  Alcotest.(check int)
    "exactly one turn_end before agent_end" 1
    (count_events is_turn_end events);
  Alcotest.(check int) "agent_end present" 1 (count_events is_agent_end events)

(** {1 Test 5: prepare_next_turn can swap the model} *)

let test_prepare_next_turn_swaps_model () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let new_model =
    Pera_types.Types.
      { id = "swapped-model"; api = "faux"; context_window = 200_000 }
  in
  (* Record models seen by our custom stream_fn wrapper *)
  let recorded_models : Pera_types.Types.model list ref = ref [] in
  (* prepare_next_turn returns a model swap after the first turn, then None *)
  let turn_count = ref 0 in
  let prepare_next_turn =
    Some
      (fun _ctx ->
        incr turn_count;
        if Int.equal !turn_count 1 then
          Some
            Agent_types.
              { messages = None; model = Some new_model; thinking = Inherit }
        else None)
  in
  (* Use a steering message to force a second turn *)
  let steering_called = ref 0 in
  let get_steering_messages =
    Some
      (fun () ->
        incr steering_called;
        if Int.equal !steering_called 1 then
          [ make_user_agent_message "steering after turn 1" ]
        else [])
  in
  let base_script1 = make_text_turn_script "turn 1 response" in
  let base_script2 = make_text_turn_script "turn 2 response" in
  let base_stream_fn =
    Faux_provider.stream_fn_of_scripts [ base_script1; base_script2 ]
  in
  (* Wrap the stream_fn to record the model it receives each call *)
  let wrapping_stream_fn ~model ~context ~options ~sw =
    recorded_models := !recorded_models @ [ model ];
    base_stream_fn ~model ~context ~options ~sw
  in
  let config =
    make_config ~prepare_next_turn ~get_steering_messages wrapping_stream_fn
  in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "start" ] ~sw
  in
  let _events, _result = collect_agent_events loop_stream in
  (* Two LLM calls should have been made *)
  let models = !recorded_models in
  Alcotest.(check int) "two LLM calls" 2 (List.length models);
  (* First call used the original model *)
  let first_model =
    List.nth_opt models 0 |> Option.get_exn_or "expected first model"
  in
  Alcotest.(check string)
    "first call uses original model" "test-model"
    first_model.Pera_types.Types.id;
  (* Second call used the swapped model *)
  let second_model =
    List.nth_opt models 1 |> Option.get_exn_or "expected second model"
  in
  Alcotest.(check string)
    "second call uses swapped model" "swapped-model"
    second_model.Pera_types.Types.id

(** {1 Test 6: steering messages injected on next inner-loop iteration} *)

let test_steering_message_injected_on_next_iteration () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let call_count = ref 0 in
  let steering_msg = make_user_agent_message "steering content" in
  let get_steering_messages =
    Some
      (fun () ->
        incr call_count;
        if Int.equal !call_count 1 then [ steering_msg ] else [])
  in
  let script1 = make_text_turn_script "first response" in
  let script2 = make_text_turn_script "second response" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~get_steering_messages stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "initial" ] ~sw
  in
  let _events, _result = collect_agent_events loop_stream in
  (* The second call to stream_fn should have received the steering message *)
  let recorded = Faux_provider.recorded_contexts () in
  Alcotest.(check int) "two recorded contexts" 2 (List.length recorded);
  let second_ctx =
    List.nth_opt recorded 1
    |> Option.get_exn_or "expected second recorded context"
  in
  (* The steering message should appear in the second context's messages *)
  let has_steering =
    List.exists
      (fun msg ->
        match msg with
        | Pera_connector.Connector.UserMessage { content = [ UText t ]; _ } ->
            String.equal t "steering content"
        | _ -> false)
      second_ctx.Pera_connector.Connector.messages
  in
  Alcotest.(check bool) "steering message in second context" true has_steering

(** {1 Test 7: follow-up messages restart the inner loop} *)

let test_follow_up_message_restarts_inner_loop () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let follow_up_called = ref 0 in
  let follow_up_msg = make_user_agent_message "follow-up" in
  let get_follow_up_messages =
    Some
      (fun () ->
        incr follow_up_called;
        if Int.equal !follow_up_called 1 then [ follow_up_msg ] else [])
  in
  let script1 = make_text_turn_script "first turn" in
  let script2 = make_text_turn_script "second turn" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let config = make_config ~get_follow_up_messages stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "start" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  (* Two turns should have been triggered *)
  Alcotest.(check int)
    "two turn_start events" 2
    (count_events is_turn_start events);
  Alcotest.(check int) "agent_end present" 1 (count_events is_agent_end events)

(** {1 Test 8: error stop_reason terminates the run} *)

let test_error_stop_reason_terminates_run () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let error_final =
    make_assistant_message ~stop_reason:(Pera_types.Types.Error Pera_types.Types.Transport)
      [ Pera_types.Types.AText "oops" ]
  in
  let error_script =
    Faux_provider.Turn
      Faux_provider.
        {
          events =
            [
              Pera_types.Types.AME_text_start
                { partial = make_text_assistant_message "" };
            ];
          final = error_final;
        }
  in
  (* A second script that should NOT be reached *)
  let second_script = make_text_turn_script "should not reach this" in
  let stream_fn =
    Faux_provider.stream_fn_of_scripts [ error_script; second_script ]
  in
  let config = make_config stream_fn in
  let loop_stream =
    Agent_loop.run config ~messages:[ make_user_agent_message "hello" ] ~sw
  in
  let events, _result = collect_agent_events loop_stream in
  Alcotest.(check int)
    "no second turn_start after error" 1
    (count_events is_turn_start events);
  Alcotest.(check int) "agent_end present" 1 (count_events is_agent_end events);
  (* Check that the turn_end was emitted with the error message *)
  let turn_end_events =
    List.filter_map
      (fun e ->
        match e with
        | Agent_types.AE_turn_end { message; _ } -> Some message
        | _ -> None)
      events
  in
  Alcotest.(check int) "one turn_end" 1 (List.length turn_end_events);
  let turn_end_msg =
    List.nth_opt turn_end_events 0
    |> Option.get_exn_or "expected turn_end message"
  in
  match turn_end_msg with
  | Agent_types.Real (Pera_connector.Connector.AssistantMessage am) -> (
      match am.stop_reason with
      | Pera_types.Types.Error _ -> () (* expected *)
      | other ->
          Alcotest.failf "expected Error stop_reason, got %s"
            (match other with
            | Pera_types.Types.EndTurn -> "EndTurn"
            | Pera_types.Types.ToolUse -> "ToolUse"
            | Pera_types.Types.MaxTokens -> "MaxTokens"
            | Pera_types.Types.StopSequence -> "StopSequence"
            | Pera_types.Types.Error _ -> "Error"
            | Pera_types.Types.Aborted -> "Aborted"))
  | _ -> Alcotest.fail "expected AssistantMessage in turn_end"

let () =
  Alcotest.run "agent_loop"
    [
      ( "lifecycle",
        [
          Alcotest.test_case
            "single text turn emits lifecycle events and final messages" `Quick
            test_single_text_turn_emits_lifecycle_and_final_messages;
          Alcotest.test_case "error stop_reason terminates the run" `Quick
            test_error_stop_reason_terminates_run;
        ] );
      ( "hooks",
        [
          Alcotest.test_case "transform_context applied before convert_to_llm"
            `Quick test_transform_context_applied_before_convert_to_llm;
          Alcotest.test_case "get_api_key called before each LLM call" `Quick
            test_get_api_key_called_before_each_llm_call;
          Alcotest.test_case
            "should_stop_after_turn true terminates run after one turn" `Quick
            test_should_stop_after_turn_true_terminates_run;
          Alcotest.test_case "prepare_next_turn swaps the model" `Quick
            test_prepare_next_turn_swaps_model;
          Alcotest.test_case
            "steering message injected into next inner-loop iteration" `Quick
            test_steering_message_injected_on_next_iteration;
          Alcotest.test_case "follow-up message restarts inner loop" `Quick
            test_follow_up_message_restarts_inner_loop;
        ] );
    ]
