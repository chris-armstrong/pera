open Containers [@@warning "-33"]
open Pera_core
open Pera_core_test_util
open Agent_loop_helpers

(** {1 Event predicate helpers} *)

let is_agent_start = function Agent_types.AE_agent_start -> true | _ -> false
let is_agent_end = function Agent_types.AE_agent_end _ -> true | _ -> false
let is_turn_start = function Agent_types.AE_turn_start -> true | _ -> false
let is_turn_end = function Agent_types.AE_turn_end _ -> true | _ -> false

let is_message_start = function
  | Agent_types.AE_message_start _ -> true
  | _ -> false

let is_message_end = function
  | Agent_types.AE_message_end _ -> true
  | _ -> false

(** Build a minimal provider context for tests. *)
let make_provider_context ~system messages =
  Pera_provider.Provider.{ system; messages; tools = []; thinking = false }

(** Collect assistant_message_event values from a provider stream into a list,
    and return the final result. *)
let collect_assistant_events stream =
  let buf = ref [] in
  let result =
    Pera_provider.Event_stream.iter stream ~f:(fun e -> buf := e :: !buf)
  in
  (List.rev !buf, result)

(** {1 Test 1: stream_fn resolves a registered provider} *)

let test_stream_fn_resolves_registered_provider () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script_events =
    [
      Pera_types.Types.AME_text_start
        { partial = make_text_assistant_message "" };
      Pera_types.Types.AME_text_delta
        {
          text = "hello from faux";
          partial = make_text_assistant_message "hello from faux";
        };
    ]
  in
  let final_msg = make_text_assistant_message "hello from faux" in
  let script =
    Faux_provider.Turn
      Faux_provider.{ events = script_events; final = final_msg }
  in
  let provider_mod = Faux_provider.as_provider [ script ] in
  let registry =
    Pera_provider.Provider_registry.register
      Pera_provider.Provider_registry.empty ~name:"faux" provider_mod
  in
  let adapter = Provider_adapter.create ~registry ~env ~sw in
  let stream_fn = Provider_adapter.stream_fn adapter in
  let context =
    make_provider_context ~system:"test"
      [
        Pera_provider.Provider.UserMessage
          { Pera_types.Types.role = "user"; content = [ UText "hi" ] };
      ]
  in
  let model = { Pera_types.Types.id = "test-model"; api = "faux" } in
  let options =
    Pera_provider.Provider.{ max_tokens = 1024; temperature = None }
  in
  let stream = stream_fn ~model ~context ~options ~sw in
  let events, result = collect_assistant_events stream in
  (* Assert: two events emitted (text_start, text_delta) *)
  Alcotest.(check int) "two events emitted" 2 (List.length events);
  (* Assert: result is Ok with expected final message *)
  match result with
  | Error e -> Alcotest.failf "expected Ok result, got Error '%s'" e
  | Ok msg -> (
      match msg.Pera_types.Types.content with
      | [ Pera_types.Types.AText t ] ->
          Alcotest.(check string) "final message text" "hello from faux" t
      | _ -> Alcotest.fail "expected AText content in final message")

(** {1 Test 2: unknown api returns error stream} *)

let test_stream_fn_unknown_api_returns_error_stream () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  (* Create adapter with an empty registry *)
  let registry = Pera_provider.Provider_registry.empty in
  let adapter = Provider_adapter.create ~registry ~env ~sw in
  let stream_fn = Provider_adapter.stream_fn adapter in
  let context =
    make_provider_context ~system:"test"
      [
        Pera_provider.Provider.UserMessage
          { Pera_types.Types.role = "user"; content = [ UText "hi" ] };
      ]
  in
  let model =
    { Pera_types.Types.id = "nonexistent-model"; api = "nonexistent-api" }
  in
  let options =
    Pera_provider.Provider.{ max_tokens = 1024; temperature = None }
  in
  let stream = stream_fn ~model ~context ~options ~sw in
  let _events, result = collect_assistant_events stream in
  (* Assert: result is Error with message containing the unknown api name *)
  match result with
  | Ok _ -> Alcotest.fail "expected Error result for unknown API"
  | Error msg ->
      Alcotest.(check bool)
        "error message contains the unknown api name" true
        (String.mem ~sub:"nonexistent-api" msg)

(** {1 Test 3: stream_fn preserves provider semantics through Agent_loop.run} *)

let test_stream_fn_preserves_provider_semantics () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let script = make_text_turn_script "hello from adapter" in
  let provider_mod = Faux_provider.as_provider [ script ] in
  let registry =
    Pera_provider.Provider_registry.register
      Pera_provider.Provider_registry.empty ~name:"faux" provider_mod
  in
  let adapter = Provider_adapter.create ~registry ~env ~sw in
  let stream_fn = Provider_adapter.stream_fn adapter in
  (* Build a loop config using the adapter's stream_fn.
     The model.api must match the registered name 'faux'. *)
  let model = { Pera_types.Types.id = "test-model"; api = "faux" } in
  let options =
    Pera_provider.Provider.{ max_tokens = 1024; temperature = None }
  in
  let config =
    Agent_loop.
      {
        model;
        system = "test system";
        options;
        stream_fn;
        convert_to_llm = default_convert_to_llm;
        tool_ctx = ();
        tools = [];
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
  in
  let initial_msg = make_user_agent_message "hi" in
  let loop_stream = Agent_loop.run config ~messages:[ initial_msg ] ~sw in
  let events, result = collect_agent_events loop_stream in
  (* Assert event lifecycle *)
  Alcotest.(check int)
    "agent_start emitted" 1
    (count_events is_agent_start events);
  Alcotest.(check int)
    "turn_start emitted" 1
    (count_events is_turn_start events);
  Alcotest.(check int)
    "message_start emitted" 1
    (count_events is_message_start events);
  Alcotest.(check int)
    "message_end emitted" 1
    (count_events is_message_end events);
  Alcotest.(check int) "turn_end emitted" 1 (count_events is_turn_end events);
  Alcotest.(check int) "agent_end emitted" 1 (count_events is_agent_end events);
  (* Assert order *)
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
  | Error msg -> Alcotest.failf "expected Ok result, got Error '%s'" msg
  | Ok final_messages -> (
      Alcotest.(check int) "two final messages" 2 (List.length final_messages);
      let assistant_msg =
        List.nth_opt final_messages 1
        |> Option.get_exn_or "expected second message"
      in
      match assistant_msg with
      | Agent_types.Real (Pera_provider.Provider.AssistantMessage am) -> (
          match am.content with
          | [ Pera_types.Types.AText t ] ->
              Alcotest.(check string) "assistant text" "hello from adapter" t
          | _ -> Alcotest.fail "expected AText content")
      | _ -> Alcotest.fail "expected AssistantMessage")

let () =
  Alcotest.run "provider_adapter"
    [
      ( "adapter",
        [
          Alcotest.test_case
            "stream_fn resolves registered provider and yields scripted events"
            `Quick test_stream_fn_resolves_registered_provider;
          Alcotest.test_case "stream_fn unknown api returns error stream" `Quick
            test_stream_fn_unknown_api_returns_error_stream;
          Alcotest.test_case
            "stream_fn preserves provider semantics through Agent_loop.run"
            `Quick test_stream_fn_preserves_provider_semantics;
        ] );
    ]
