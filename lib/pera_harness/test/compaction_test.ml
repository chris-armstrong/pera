open Containers [@@warning "-33"]
open Pera_core_test_util

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

let test_model =
  Pera_types.Types.
    { id = "test-model"; protocol = "faux"; context_window = 200_000 }

let test_options =
  Pera_connector.Connector.
    {
      max_tokens = 1024;
      temperature = None;
      cache_policy = Pera_types.Types.No_cache;
      cache_ttl = Pera_types.Types.Five_minutes;
      thinking_budget_tokens = None;
    }

let make_assistant_message content =
  Pera_types.Types.
    {
      content;
      stop_reason = EndTurn;
      provenance =
        {
          protocol = "anthropic";
          provider = "test";
          model = "test";
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

let summary_final_message =
  make_assistant_message [ Pera_types.Types.AText "SUMMARY" ]

let make_summary_script () =
  Faux_provider.Turn
    Faux_provider.{ events = []; final = summary_final_message }

let make_user_agent_msg text =
  let um = Pera_types.Types.{ role = "user"; content = [ UText text ] } in
  Pera_core.Agent_types.Real (Pera_connector.Connector.UserMessage um)

let make_assistant_agent_msg text =
  let am =
    Pera_connector.Connector.AssistantMessage
      (make_assistant_message [ Pera_types.Types.AText text ])
  in
  Pera_core.Agent_types.Real am

(** Build a list of agent messages suitable for compaction tests. Produces:
    [user_0, assistant_1, user_2, assistant_3, ...] *)
let make_messages n =
  List.init n (fun i ->
      if Int.equal (i mod 2) 0 then
        make_user_agent_msg (Printf.sprintf "user %d" i)
      else make_assistant_agent_msg (Printf.sprintf "assistant %d" i))

(* ── Alcotest testables ───────────────────────────────────────────────────── *)

let agent_message_testable =
  Alcotest.testable
    (fun fmt m ->
      Format.pp_print_string fmt
        (Pera_core.Agent_types.show_agent_event
           (Pera_core.Agent_types.AE_agent_end { messages = [ m ] })))
    Pera_core.Agent_types.agent_message_equal

(* ── Tests ────────────────────────────────────────────────────────────────── *)

(* test_compact_success_shape:
   With messages of length tail_size + 3 and tail_size = 2, compact returns
   Ok (Some r) where r.summary = "SUMMARY", r.new_messages has length 4
   (1 first + 1 synthetic + 2 tail), head equals original first, element 1 is
   Synthetic (Compaction_summary {summary="SUMMARY"}), and the last 2 match
   the original tail. *)
let test_compact_success_shape () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let tail_size = 2 in
  let n = tail_size + 3 in
  let messages = make_messages n in
  let stream_fn =
    Faux_provider.stream_fn_of_scripts [ make_summary_script () ]
  in
  let result =
    Pera_harness.Compaction.compact ~stream_fn ~model:test_model
      ~options:test_options ~messages ~tail_size ~sw
  in
  let r =
    match result with
    | Error msg -> Alcotest.failf "expected Ok (Some _) but got Error %S" msg
    | Ok None -> Alcotest.fail "expected Ok (Some _) but got Ok None"
    | Ok (Some r) -> r
  in
  Alcotest.(check string) "summary text" "SUMMARY" r.summary;
  Alcotest.(check int) "new_messages length" 4 (List.length r.new_messages);
  let original_first =
    List.nth_opt messages 0 |> Option.get_exn_or "messages[0]"
  in
  let new_first =
    List.nth_opt r.new_messages 0 |> Option.get_exn_or "new_messages[0]"
  in
  Alcotest.(check agent_message_testable)
    "head equals original first" original_first new_first;
  let new_second =
    List.nth_opt r.new_messages 1 |> Option.get_exn_or "new_messages[1]"
  in
  let expected_synthetic =
    Pera_core.Agent_types.Synthetic
      (Pera_core.Agent_types.Compaction_summary { summary = "SUMMARY" })
  in
  Alcotest.(check agent_message_testable)
    "element 1 is Compaction_summary" expected_synthetic new_second;
  let original_tail = List.drop (n - tail_size) messages in
  let new_tail = List.drop 2 r.new_messages in
  Alcotest.(check (list agent_message_testable))
    "tail matches original last 2" original_tail new_tail

(** test_compact_renders_synthetic_as_user: to_provider_message of the
    compaction synthetic (element 1 of new_messages) is a UserMessage whose text
    starts with Agent_types.compaction_framing. *)
let test_compact_renders_synthetic_as_user () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let tail_size = 2 in
  let messages = make_messages (tail_size + 3) in
  let stream_fn =
    Faux_provider.stream_fn_of_scripts [ make_summary_script () ]
  in
  let r =
    match
      Pera_harness.Compaction.compact ~stream_fn ~model:test_model
        ~options:test_options ~messages ~tail_size ~sw
    with
    | Ok (Some r) -> r
    | Ok None -> Alcotest.fail "expected Ok (Some _) but got Ok None"
    | Error msg -> Alcotest.failf "expected Ok (Some _) but got Error %S" msg
  in
  let synthetic_msg =
    List.nth_opt r.new_messages 1 |> Option.get_exn_or "new_messages[1]"
  in
  let provider_msg = Pera_core.Agent_types.to_provider_message synthetic_msg in
  match provider_msg with
  | Pera_connector.Connector.UserMessage Pera_types.Types.{ content; _ } ->
      let text =
        List.filter_map
          (fun c ->
            match c with Pera_types.Types.UText t -> Some t | _ -> None)
          content
        |> String.concat ""
      in
      let framing = Pera_core.Agent_types.compaction_framing in
      let starts_with_framing = String.prefix ~pre:framing text in
      Alcotest.(check bool)
        "text starts with compaction_framing" true starts_with_framing
  | other ->
      Alcotest.failf "expected UserMessage but got: %s"
        (Pera_connector.Connector.show_message other)

(** test_compact_too_short_returns_none: Messages of length tail_size + 1 → Ok
    None (stream_fn not called). *)
let test_compact_too_short_returns_none () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let tail_size = 2 in
  let messages = make_messages (tail_size + 1) in
  (* Empty scripts: if stream_fn were called it would raise *)
  let stream_fn = Faux_provider.stream_fn_of_scripts [] in
  let result =
    Pera_harness.Compaction.compact ~stream_fn ~model:test_model
      ~options:test_options ~messages ~tail_size ~sw
  in
  (match result with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "expected Ok None but got Ok (Some _)"
  | Error msg -> Alcotest.failf "expected Ok None but got Error %S" msg);
  (* Verify stream_fn was not called *)
  Alcotest.(check int)
    "stream_fn not called (no recorded contexts)" 0
    (List.length (Faux_provider.recorded_contexts ()))

(** test_compact_stream_error_returns_error: When the script is an Error turn,
    compact returns Error _. *)
let test_compact_stream_error_returns_error () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  Faux_provider.reset_recorded ();
  let tail_size = 2 in
  let messages = make_messages (tail_size + 3) in
  let error_script =
    Faux_provider.Error
      Faux_provider.{ error_events = []; error_message = "boom" }
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ error_script ] in
  let result =
    Pera_harness.Compaction.compact ~stream_fn ~model:test_model
      ~options:test_options ~messages ~tail_size ~sw
  in
  match result with
  | Error _ -> ()
  | Ok None -> Alcotest.fail "expected Error but got Ok None"
  | Ok (Some _) -> Alcotest.fail "expected Error but got Ok (Some _)"

(** test_render_messages_to_text_includes_tool_results: Rendering a list
    containing a ToolResultMessage includes the result content text. *)
let test_render_messages_to_text_includes_tool_results () =
  let tool_result =
    Pera_connector.Connector.ToolResultMessage
      Pera_types.Types.
        {
          tool_call_id = "tc-123";
          content = `String "tool output here";
          is_error = false;
        }
  in
  let rendered =
    Pera_harness.Compaction.render_messages_to_text [ tool_result ]
  in
  let contains_id = String.mem ~sub:"tc-123" rendered in
  let contains_content = String.mem ~sub:"tool output here" rendered in
  Alcotest.(check bool) "rendered contains tool_call_id" true contains_id;
  Alcotest.(check bool)
    "rendered contains tool result content" true contains_content

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "compaction"
    [
      ( "compact",
        [
          Alcotest.test_case "success shape" `Quick test_compact_success_shape;
          Alcotest.test_case "renders synthetic as user message" `Quick
            test_compact_renders_synthetic_as_user;
          Alcotest.test_case "too short returns None" `Quick
            test_compact_too_short_returns_none;
          Alcotest.test_case "stream error returns Error" `Quick
            test_compact_stream_error_returns_error;
        ] );
      ( "render_messages_to_text",
        [
          Alcotest.test_case "includes tool results" `Quick
            test_render_messages_to_text_includes_tool_results;
        ] );
    ]
