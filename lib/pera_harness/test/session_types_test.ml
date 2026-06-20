open Containers
open Pera_harness.Session_types
open Yojson.Safe.Util

let get_str json key = member key json |> to_string
let get_bool json key = member key json |> to_bool

(* Check that the key is genuinely absent (not merely set to null).
   Yojson.Safe.Util.member returns `Null for both, so we use the assoc list. *)
let has_key json key =
  match json with
  | `Assoc fields -> Option.is_some (List.assoc_opt ~eq:String.equal key fields)
  | _ -> false

let make_usage ?(cost_usd = None) () =
  Pera_types.Types.
    {
      input_tokens = 10;
      output_tokens = 5;
      cache_read_tokens = 0;
      cache_write_tokens = 0;
      cost_usd;
    }

let make_provenance () =
  Pera_types.Types.
    {
      api = "anthropic";
      provider = "anthropic";
      model = "test-model";
      error_message = None;
    }

let make_assistant_message ?(stop_reason = Pera_types.Types.EndTurn)
    ?(cost_usd = None) content =
  Pera_provider.Provider.AssistantMessage
    Pera_types.Types.
      {
        content;
        stop_reason;
        provenance = make_provenance ();
        usage = make_usage ~cost_usd ();
      }

let fake_id = Pera_harness.Entry_id.generate ()
let fake_id_str = Pera_harness.Entry_id.to_string fake_id
let fake_parent_id = Pera_harness.Entry_id.generate ()
let fake_parent_id_str = Pera_harness.Entry_id.to_string fake_parent_id
let fake_ts = 1700000000.0

let fake_model =
  Pera_types.Types.
    { id = "claude-3-5"; api = "anthropic"; context_window = 200_000 }

(* ── session_info tests ─────────────────────────────────────────────────── *)

let test_session_info_serialises_required_fields () =
  let e =
    SessionInfo
      {
        id = fake_id;
        timestamp = fake_ts;
        session_id = "sess-123";
        cwd = "/home/user";
        model = fake_model;
        parent_session_id = None;
      }
  in
  let json = entry_to_json e in
  Alcotest.(check string) "id" fake_id_str (get_str json "id");
  Alcotest.(check string) "type" "session_info" (get_str json "type");
  Alcotest.(check (float 0.0001))
    "timestamp" fake_ts
    (member "timestamp" json |> to_float);
  Alcotest.(check string) "session_id" "sess-123" (get_str json "session_id");
  Alcotest.(check string) "cwd" "/home/user" (get_str json "cwd");
  Alcotest.(check string)
    "model.id" "claude-3-5"
    (get_str (member "model" json) "id");
  Alcotest.(check string)
    "model.api" "anthropic"
    (get_str (member "model" json) "api");
  Alcotest.(check int)
    "model.context_window" 200_000
    (member "model" json |> member "context_window" |> to_int)

let test_session_info_omits_parent_session_id_when_none () =
  let e =
    SessionInfo
      {
        id = fake_id;
        timestamp = fake_ts;
        session_id = "sess";
        cwd = "/";
        model = fake_model;
        parent_session_id = None;
      }
  in
  let json = entry_to_json e in
  Alcotest.(check bool)
    "no parent_session_id key" false
    (has_key json "parent_session_id")

(* ── message entry tests ────────────────────────────────────────────────── *)

let test_message_entry_serialises_parent_id () =
  let e =
    Message
      {
        id = fake_id;
        parent_id = Some fake_parent_id;
        timestamp = fake_ts;
        message =
          Pera_provider.Provider.UserMessage
            Pera_types.Types.{ role = "user"; content = [] };
      }
  in
  let json = entry_to_json e in
  Alcotest.(check string)
    "parent_id" fake_parent_id_str (get_str json "parent_id")

let test_message_entry_omits_parent_id_when_none () =
  let e =
    Message
      {
        id = fake_id;
        parent_id = None;
        timestamp = fake_ts;
        message =
          Pera_provider.Provider.UserMessage
            Pera_types.Types.{ role = "user"; content = [] };
      }
  in
  let json = entry_to_json e in
  Alcotest.(check bool) "no parent_id key" false (has_key json "parent_id")

(* ── leaf tests ─────────────────────────────────────────────────────────── *)

let test_leaf_entry_serialises_correctly () =
  let e = Leaf { id = fake_id; parent_id = None; timestamp = fake_ts } in
  let json = entry_to_json e in
  Alcotest.(check string) "type" "leaf" (get_str json "type")

(* ── message_to_json tests ──────────────────────────────────────────────── *)

let test_user_message_content_serialised_as_array () =
  let msg =
    Pera_provider.Provider.UserMessage
      Pera_types.Types.{ role = "user"; content = [ UText "hi" ] }
  in
  let json = message_to_json msg in
  Alcotest.(check string) "role" "user" (get_str json "role");
  let content = member "content" json |> to_list in
  Alcotest.(check int) "content length" 1 (List.length content);
  Alcotest.(check string)
    "content[0].text" "hi"
    (get_str
       (List.get_at_idx 0 content |> Option.get_exn_or "expected content block")
       "text")

let test_assistant_message_stop_reason_strings () =
  let check_stop_reason sr expected =
    let msg = make_assistant_message ~stop_reason:sr [ AText "x" ] in
    let json = message_to_json msg in
    Alcotest.(check string)
      ("stop_reason " ^ expected)
      expected
      (get_str json "stop_reason")
  in
  check_stop_reason Pera_types.Types.EndTurn "end_turn";
  check_stop_reason Pera_types.Types.ToolUse "tool_use";
  check_stop_reason Pera_types.Types.MaxTokens "max_tokens";
  check_stop_reason Pera_types.Types.StopSequence "stop_sequence";
  check_stop_reason Pera_types.Types.Error "error";
  check_stop_reason Pera_types.Types.Aborted "aborted"

let test_assistant_thinking_block_serialised () =
  let msg =
    make_assistant_message [ AThinking { text = "t"; signature = Some "s" } ]
  in
  let json = message_to_json msg in
  let block =
    member "content" json |> to_list |> fun l ->
    List.get_at_idx 0 l |> Option.get_exn_or "expected content block"
  in
  Alcotest.(check string) "type" "thinking" (get_str block "type");
  Alcotest.(check string) "text" "t" (get_str block "text");
  Alcotest.(check string) "signature" "s" (get_str block "signature")

let test_tool_call_arguments_embedded_as_json () =
  let args = `Assoc [ ("k", `String "v") ] in
  let msg =
    make_assistant_message
      [ AToolCall { id = "tc1"; name = "my_tool"; arguments = args } ]
  in
  let json = message_to_json msg in
  let block =
    member "content" json |> to_list |> fun l ->
    List.get_at_idx 0 l |> Option.get_exn_or "expected content block"
  in
  Alcotest.(check string) "type" "tool_call" (get_str block "type");
  let arguments = member "arguments" block in
  Alcotest.(check string) "arguments.k" "v" (get_str arguments "k")

let test_tool_result_message_serialised () =
  let msg =
    Pera_provider.Provider.ToolResultMessage
      Pera_types.Types.
        { tool_call_id = "tc1"; content = `String "result"; is_error = true }
  in
  let json = message_to_json msg in
  Alcotest.(check bool) "is_error" true (get_bool json "is_error");
  Alcotest.(check string) "role" "tool_result" (get_str json "role")

let test_assistant_message_cost_usd_serialised () =
  let cost = Decimal.of_string "0.0015" in
  let msg = make_assistant_message ~cost_usd:(Some cost) [ AText "x" ] in
  let json = message_to_json msg in
  let usage = member "usage" json in
  Alcotest.(check string) "cost_usd" "0.0015" (get_str usage "cost_usd")

let test_assistant_message_cost_usd_omitted_when_none () =
  let msg = make_assistant_message ~cost_usd:None [ AText "x" ] in
  let json = message_to_json msg in
  let usage = member "usage" json in
  Alcotest.(check bool) "no cost_usd key" false (has_key usage "cost_usd")

let test_entry_to_json_wraps_message_entry () =
  let inner_msg =
    Pera_provider.Provider.UserMessage
      Pera_types.Types.{ role = "user"; content = [ UText "hello" ] }
  in
  let e =
    Message
      {
        id = fake_id;
        parent_id = Some fake_parent_id;
        timestamp = fake_ts;
        message = inner_msg;
      }
  in
  let json = entry_to_json e in
  Alcotest.(check string) "id" fake_id_str (get_str json "id");
  Alcotest.(check string) "type" "message" (get_str json "type");
  Alcotest.(check bool) "has parent_id" true (has_key json "parent_id");
  let msg_json = member "message" json in
  Alcotest.(check string) "message.role" "user" (get_str msg_json "role")

let () =
  Alcotest.run "session_types"
    [
      ( "session_info",
        [
          Alcotest.test_case "serialises required fields" `Quick
            test_session_info_serialises_required_fields;
          Alcotest.test_case "omits parent_session_id when None" `Quick
            test_session_info_omits_parent_session_id_when_none;
        ] );
      ( "message_entry",
        [
          Alcotest.test_case "serialises parent_id" `Quick
            test_message_entry_serialises_parent_id;
          Alcotest.test_case "omits parent_id when None" `Quick
            test_message_entry_omits_parent_id_when_none;
        ] );
      ( "leaf_entry",
        [
          Alcotest.test_case "serialises correctly" `Quick
            test_leaf_entry_serialises_correctly;
        ] );
      ( "message_to_json",
        [
          Alcotest.test_case "user message content as array" `Quick
            test_user_message_content_serialised_as_array;
          Alcotest.test_case "stop_reason strings" `Quick
            test_assistant_message_stop_reason_strings;
          Alcotest.test_case "thinking block" `Quick
            test_assistant_thinking_block_serialised;
          Alcotest.test_case "tool call arguments embedded" `Quick
            test_tool_call_arguments_embedded_as_json;
          Alcotest.test_case "tool result message" `Quick
            test_tool_result_message_serialised;
          Alcotest.test_case "cost_usd serialised as string" `Quick
            test_assistant_message_cost_usd_serialised;
          Alcotest.test_case "cost_usd omitted when None" `Quick
            test_assistant_message_cost_usd_omitted_when_none;
          Alcotest.test_case "entry_to_json wraps message" `Quick
            test_entry_to_json_wraps_message_entry;
        ] );
    ]
