open Containers [@@warning "-33"]
open Pera_core_test_util

(** Build a minimal [assistant_message] with the given [stop_reason] and text
    content. Used to construct scripted final messages in tests. *)
let make_assistant_message ?(stop_reason = Pera_types.Types.EndTurn) text =
  Pera_types.Types.
    {
      content = [ AText text ];
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

(** Build a minimal [user_message]. *)
let make_user_message text =
  Pera_types.Types.{ role = "user"; content = [ UText text ] }

(** Build a minimal [Connector.context] with only a user message and no tools or
    system prompt. *)
let make_context messages =
  Pera_connector.Connector.{ system = ""; messages; tools = [] }

(** Collect all events from a stream into a list, returning the list and the
    final result. Raises on unexpected outcomes inside [Alcotest.failf]. *)
let collect_events stream =
  let buf = ref [] in
  let result =
    Pera_connector.Event_stream.iter stream ~f:(fun e -> buf := e :: !buf)
  in
  (List.rev !buf, result)

(** Alcotest testable for [assistant_message_event] using the equality function
    from [Agent_types]. *)
let ame_testable =
  Alcotest.testable
    (fun ppf e ->
      Format.fprintf ppf "%s"
        (match e with
        | Pera_types.Types.AME_text_start _ -> "AME_text_start"
        | Pera_types.Types.AME_text_delta _ -> "AME_text_delta"
        | Pera_types.Types.AME_thinking_start _ -> "AME_thinking_start"
        | Pera_types.Types.AME_thinking_delta _ -> "AME_thinking_delta"
        | Pera_types.Types.AME_tool_call_start _ -> "AME_tool_call_start"
        | Pera_types.Types.AME_tool_call_delta _ -> "AME_tool_call_delta"
        | Pera_types.Types.AME_tool_call_end _ -> "AME_tool_call_end"
        | Pera_types.Types.AME_done _ -> "AME_done"
        | Pera_types.Types.AME_error _ -> "AME_error"))
    Pera_types.Types.equal_assistant_message_event

(** Alcotest testable for [(assistant_message_event list, string) result]. *)
let result_testable =
  Alcotest.testable
    (fun ppf r ->
      match r with
      | Ok msg ->
          Format.fprintf ppf "Ok(%s)"
            (match msg.Pera_types.Types.content with
            | [ AText t ] -> t
            | _ -> "<complex>")
      | Error (msg, stop_err) ->
          Format.fprintf ppf "Error(%s, %s)" msg
            (Pera_types.Types.show_stop_error stop_err))
    (fun r1 r2 ->
      match (r1, r2) with
      | Ok m1, Ok m2 -> Pera_types.Types.equal_assistant_message m1 m2
      | Error (e1, s1), Error (e2, s2) ->
          String.equal e1 e2 && Pera_types.Types.equal_stop_error s1 s2
      | _, _ -> false)

(** A model value suitable for Faux_provider calls (the model is ignored). *)
let faux_model =
  Pera_types.Types.
    { id = "faux-model"; protocol = "faux"; context_window = 200_000 }

(** Simple stream options — Faux_provider ignores these. *)
let faux_options =
  Pera_connector.Connector.
    {
      max_tokens = 1024;
      temperature = None;
      cache_policy = Pera_types.Types.No_cache;
      cache_ttl = Pera_types.Types.Five_minutes;
      thinking_budget_tokens = None;
    }

(** ----------------------------------------------------------------------- Test
    1: A single-turn script emits events and then resolves with the scripted
    final message.
    ----------------------------------------------------------------------- *)
let test_script_emits_events_then_resolves_final () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  (* Arrange: a partial message used as the "partial" field in events *)
  let partial_msg = make_assistant_message "" in
  let final_msg = make_assistant_message "hello world" in
  let events =
    [
      Pera_types.Types.AME_text_start { partial = partial_msg };
      Pera_types.Types.AME_text_delta
        { text = "hello world"; partial = final_msg };
    ]
  in
  let script = Faux_provider.Turn Faux_provider.{ events; final = final_msg } in
  let fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let ctx =
    make_context
      [ Pera_connector.Connector.UserMessage (make_user_message "hi") ]
  in
  (* Act *)
  let stream = fn ~model:faux_model ~context:ctx ~options:faux_options ~sw in
  let collected_events, result = collect_events stream in
  (* Assert: events match the script *)
  Alcotest.(check (list ame_testable))
    "emitted events match script" events collected_events;
  (* Assert: result resolves to Ok final *)
  Alcotest.(check result_testable)
    "stream result is Ok final_msg" (Ok final_msg) result

(** ----------------------------------------------------------------------- Test
    2: A two-script stream_fn advances one script per call.
    ----------------------------------------------------------------------- *)
let test_multi_turn_scripts_advance_per_call () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let final1 = make_assistant_message "turn one" in
  let final2 = make_assistant_message "turn two" in
  let script1 =
    Faux_provider.Turn Faux_provider.{ events = []; final = final1 }
  in
  let script2 =
    Faux_provider.Turn Faux_provider.{ events = []; final = final2 }
  in
  let fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let ctx =
    make_context
      [ Pera_connector.Connector.UserMessage (make_user_message "prompt") ]
  in
  (* First call — should yield script1's final *)
  let stream1 = fn ~model:faux_model ~context:ctx ~options:faux_options ~sw in
  let _events1, result1 = collect_events stream1 in
  Alcotest.(check result_testable)
    "first call yields script[0]'s final" (Ok final1) result1;
  (* Second call — should yield script2's final *)
  let stream2 = fn ~model:faux_model ~context:ctx ~options:faux_options ~sw in
  let _events2, result2 = collect_events stream2 in
  Alcotest.(check result_testable)
    "second call yields script[1]'s final" (Ok final2) result2

(** ----------------------------------------------------------------------- Test
    3: The context passed to the stream_fn is recorded and retrievable.
    ----------------------------------------------------------------------- *)
let test_recorded_context_is_observable () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let final_msg = make_assistant_message "done" in
  let script =
    Faux_provider.Turn Faux_provider.{ events = []; final = final_msg }
  in
  let fn = Faux_provider.stream_fn_of_scripts [ script ] in
  let user_msg = make_user_message "what is 2+2?" in
  let ctx = make_context [ Pera_connector.Connector.UserMessage user_msg ] in
  (* Act *)
  let stream = fn ~model:faux_model ~context:ctx ~options:faux_options ~sw in
  let _events, _result = collect_events stream in
  (* Assert: the recorded context contains the messages we passed in *)
  let recorded = Faux_provider.recorded_contexts () in
  Alcotest.(check int) "one context recorded" 1 (List.length recorded);
  let recorded_ctx =
    List.nth_opt recorded 0
    |> Option.get_exn_or "expected at least one recorded context"
  in
  Alcotest.(check int)
    "recorded context has one message" 1
    (List.length recorded_ctx.Pera_connector.Connector.messages);
  let recorded_msg =
    List.nth_opt recorded_ctx.Pera_connector.Connector.messages 0
    |> Option.get_exn_or "expected a message in recorded context"
  in
  (* Compare the recorded message by checking its user content *)
  match recorded_msg with
  | Pera_connector.Connector.UserMessage { role; content = [ UText t ] } ->
      Alcotest.(check string) "role is user" "user" role;
      Alcotest.(check string) "message text matches" "what is 2+2?" t
  | _ -> Alcotest.fail "expected a UserMessage with UText content"

(** ----------------------------------------------------------------------- Test
    4: An error script closes the stream with [Error _].
    ----------------------------------------------------------------------- *)
let test_error_script_closes_stream_with_error () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let partial_msg = make_assistant_message "" in
  let error_script =
    Faux_provider.Error
      Faux_provider.
        {
          error_events =
            [ Pera_types.Types.AME_text_start { partial = partial_msg } ];
          error_message = "simulated transport failure";
        }
  in
  let fn = Faux_provider.stream_fn_of_scripts [ error_script ] in
  let ctx =
    make_context
      [ Pera_connector.Connector.UserMessage (make_user_message "hi") ]
  in
  (* Act *)
  let stream = fn ~model:faux_model ~context:ctx ~options:faux_options ~sw in
  let collected_events, result = collect_events stream in
  (* Assert: one event was emitted before the error *)
  Alcotest.(check int) "one event before error" 1 (List.length collected_events);
  (* Assert: result is Error *)
  match result with
  | Error (err_msg, _stop_err) ->
      Alcotest.(check string)
        "error message matches" "simulated transport failure" err_msg
  | Ok _ -> Alcotest.fail "expected Error result from error script"

let () =
  Alcotest.run "faux_provider"
    [
      ( "stream_fn_of_scripts",
        [
          Alcotest.test_case
            "single-turn script emits events then resolves final message" `Quick
            test_script_emits_events_then_resolves_final;
          Alcotest.test_case "multi-turn scripts advance one per call" `Quick
            test_multi_turn_scripts_advance_per_call;
          Alcotest.test_case "context passed to stream_fn is recorded" `Quick
            test_recorded_context_is_observable;
          Alcotest.test_case "error script closes stream with Error" `Quick
            test_error_script_closes_stream_with_error;
        ] );
    ]
