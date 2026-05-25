open Containers
open Pera_types
open Pera_provider

(* ── Helpers ── *)

(** Look up the value for [key] in an assoc list, failing the test if absent. *)
let assoc_exn key fields =
  List.assoc_opt ~eq:String.equal key fields
  |> Option.get_exn_or (Fmt.str "expected key %S in assoc" key)

(** Unwrap a [`Assoc] JSON value, failing the test if it is not an assoc. *)
let as_assoc label json =
  match json with
  | `Assoc fields -> fields
  | other ->
      Alcotest.failf "%s: expected JSON object, got %s" label
        (Yojson.Safe.to_string other)

(** Unwrap a [`List] JSON value, failing the test if it is not a list. *)
let as_list label json =
  match json with
  | `List items -> items
  | other ->
      Alcotest.failf "%s: expected JSON array, got %s" label
        (Yojson.Safe.to_string other)

(** Unwrap a [`String] JSON value, failing the test if it is not a string. *)
let as_string label json =
  match json with
  | `String s -> s
  | other ->
      Alcotest.failf "%s: expected JSON string, got %s" label
        (Yojson.Safe.to_string other)

(** Build a minimal [Provider.context] around a message list. *)
let make_context messages =
  { Provider.system = ""; messages; tools = []; thinking = false }

(** Build a minimal [Provider.simple_stream_options]. *)
let make_options () = { Provider.max_tokens = 1024; temperature = None }

(** A minimal model value. *)
let test_model = { Types.id = "test-model"; api = "anthropic" }

(** Render [messages] through [build_request_body] and return the parsed
    messages array from the resulting JSON. *)
let render_messages messages =
  let context = make_context messages in
  let options = make_options () in
  let body =
    Anthropic_request.build_request_body ~model:test_model ~context ~options
  in
  let fields = as_assoc "body" body in
  let messages_json = assoc_exn "messages" fields in
  as_list "messages" messages_json

(** Build a [ToolResultMessage] with string content. *)
let make_tool_result ?(is_error = false) tool_call_id content_str =
  Provider.ToolResultMessage
    { Types.tool_call_id; content = `String content_str; is_error }

(* ── Test 1: single tool result renders as a user message ── *)

let test_single_tool_result_renders_as_user_message () =
  (* Arrange *)
  let messages = [ make_tool_result "call_abc" "ok" ] in
  (* Act *)
  let rendered = render_messages messages in
  (* Assert: exactly one rendered message *)
  Alcotest.(check int) "one message" 1 (List.length rendered);
  let msg_fields =
    as_assoc "message[0]"
      (List.nth_opt rendered 0
      |> Option.get_exn_or "expected rendered message at index 0")
  in
  (* role = "user" *)
  let role = assoc_exn "role" msg_fields |> as_string "role" in
  Alcotest.(check string) "role is user" "user" role;
  (* content is a list with one tool_result block *)
  let content_list = assoc_exn "content" msg_fields |> as_list "content" in
  Alcotest.(check int) "one content block" 1 (List.length content_list);
  let block_fields =
    as_assoc "content[0]"
      (List.nth_opt content_list 0
      |> Option.get_exn_or "expected content block at index 0")
  in
  let block_type = assoc_exn "type" block_fields |> as_string "block type" in
  Alcotest.(check string) "block type is tool_result" "tool_result" block_type;
  let tool_use_id =
    assoc_exn "tool_use_id" block_fields |> as_string "tool_use_id"
  in
  Alcotest.(check string) "tool_use_id matches" "call_abc" tool_use_id;
  let is_error = assoc_exn "is_error" block_fields in
  Alcotest.(check bool)
    "is_error is false" false
    (match is_error with `Bool b -> b | _ -> Alcotest.fail "expected bool")

(* ── Test 2: consecutive tool results coalesce into one user message ── *)

let test_consecutive_tool_results_coalesce_into_one_user_message () =
  (* Arrange: two consecutive ToolResultMessages *)
  let messages =
    [
      make_tool_result "call_1" "result one";
      make_tool_result "call_2" "result two";
    ]
  in
  (* Act *)
  let rendered = render_messages messages in
  (* Assert: exactly ONE merged user message *)
  Alcotest.(check int) "one merged message" 1 (List.length rendered);
  let msg_fields =
    as_assoc "message[0]"
      (List.nth_opt rendered 0
      |> Option.get_exn_or "expected rendered message at index 0")
  in
  let role = assoc_exn "role" msg_fields |> as_string "role" in
  Alcotest.(check string) "role is user" "user" role;
  (* content list has two tool_result blocks in source order *)
  let content_list = assoc_exn "content" msg_fields |> as_list "content" in
  Alcotest.(check int) "two content blocks" 2 (List.length content_list);
  let first_block =
    as_assoc "content[0]"
      (List.nth_opt content_list 0
      |> Option.get_exn_or "expected content block at index 0")
  in
  let second_block =
    as_assoc "content[1]"
      (List.nth_opt content_list 1
      |> Option.get_exn_or "expected content block at index 1")
  in
  let first_id =
    assoc_exn "tool_use_id" first_block |> as_string "first tool_use_id"
  in
  let second_id =
    assoc_exn "tool_use_id" second_block |> as_string "second tool_use_id"
  in
  Alcotest.(check string) "first block id in source order" "call_1" first_id;
  Alcotest.(check string) "second block id in source order" "call_2" second_id

(* ── Test 3: is_error flag propagates ── *)

let test_tool_result_is_error_flag_propagates () =
  (* Arrange: a ToolResultMessage with is_error=true *)
  let messages =
    [ make_tool_result ~is_error:true "call_err" "something went wrong" ]
  in
  (* Act *)
  let rendered = render_messages messages in
  (* Assert: one message with is_error=true in the block *)
  Alcotest.(check int) "one message" 1 (List.length rendered);
  let msg_fields =
    as_assoc "message[0]"
      (List.nth_opt rendered 0
      |> Option.get_exn_or "expected rendered message at index 0")
  in
  let content_list = assoc_exn "content" msg_fields |> as_list "content" in
  let block_fields =
    as_assoc "content[0]"
      (List.nth_opt content_list 0
      |> Option.get_exn_or "expected content block at index 0")
  in
  let is_error = assoc_exn "is_error" block_fields in
  Alcotest.(check bool)
    "is_error is true" true
    (match is_error with `Bool b -> b | _ -> Alcotest.fail "expected bool")

(* ── Test 4: tool results bounded by other messages do not over-merge ── *)

let test_tool_results_between_other_messages_do_not_over_merge () =
  (* Arrange: [AssistantMessage, ToolResultMessage, ToolResultMessage, UserMessage]
     The two tool results form a contiguous run and should coalesce into one
     user message. The result should be [assistant, user(merged), user] in order. *)
  let assistant_msg =
    Provider.AssistantMessage
      {
        Types.content = [ Types.AText "I will call two tools." ];
        stop_reason = Types.ToolUse;
        provenance =
          {
            Types.api = "anthropic";
            provider = "Anthropic";
            model = "test-model";
            error_message = None;
          };
        usage =
          {
            Types.input_tokens = 10;
            output_tokens = 5;
            cache_read_tokens = 0;
            cache_write_tokens = 0;
            cost_usd = None;
          };
      }
  in
  let follow_up_user_msg =
    Provider.UserMessage
      { Types.role = "user"; content = [ Types.UText "continue" ] }
  in
  let messages =
    [
      assistant_msg;
      make_tool_result "call_a" "result a";
      make_tool_result "call_b" "result b";
      follow_up_user_msg;
    ]
  in
  (* Act *)
  let rendered = render_messages messages in
  (* Assert: exactly three rendered messages [assistant, user(merged), user] *)
  Alcotest.(check int) "three messages" 3 (List.length rendered);
  (* First message: assistant role *)
  let first_fields =
    as_assoc "message[0]"
      (List.nth_opt rendered 0
      |> Option.get_exn_or "expected rendered message at index 0")
  in
  let first_role = assoc_exn "role" first_fields |> as_string "first role" in
  Alcotest.(check string) "first message is assistant" "assistant" first_role;
  (* Second message: user role with two tool_result blocks (the merged run) *)
  let second_fields =
    as_assoc "message[1]"
      (List.nth_opt rendered 1
      |> Option.get_exn_or "expected rendered message at index 1")
  in
  let second_role = assoc_exn "role" second_fields |> as_string "second role" in
  Alcotest.(check string) "second message is user" "user" second_role;
  let second_content =
    assoc_exn "content" second_fields |> as_list "second content"
  in
  Alcotest.(check int)
    "second message has two blocks" 2
    (List.length second_content);
  let second_first_block =
    as_assoc "second content[0]"
      (List.nth_opt second_content 0
      |> Option.get_exn_or "expected content block at index 0")
  in
  let second_second_block =
    as_assoc "second content[1]"
      (List.nth_opt second_content 1
      |> Option.get_exn_or "expected content block at index 1")
  in
  let id_a = assoc_exn "tool_use_id" second_first_block |> as_string "id_a" in
  let id_b = assoc_exn "tool_use_id" second_second_block |> as_string "id_b" in
  Alcotest.(check string) "first merged block is call_a" "call_a" id_a;
  Alcotest.(check string) "second merged block is call_b" "call_b" id_b;
  (* Third message: user role with plain text (the follow-up user message) *)
  let third_fields =
    as_assoc "message[2]"
      (List.nth_opt rendered 2
      |> Option.get_exn_or "expected rendered message at index 2")
  in
  let third_role = assoc_exn "role" third_fields |> as_string "third role" in
  Alcotest.(check string) "third message is user" "user" third_role;
  let third_content =
    assoc_exn "content" third_fields |> as_list "third content"
  in
  Alcotest.(check int)
    "third message has one block" 1
    (List.length third_content);
  let third_block =
    as_assoc "third content[0]"
      (List.nth_opt third_content 0
      |> Option.get_exn_or "expected content block at index 0")
  in
  let third_block_type =
    assoc_exn "type" third_block |> as_string "third block type"
  in
  Alcotest.(check string) "third block is text" "text" third_block_type

(* ── Test runner ── *)

let () =
  Alcotest.run "Anthropic_request"
    [
      ( "tool_result_rendering",
        [
          Alcotest.test_case "single_tool_result_renders_as_user_message" `Quick
            test_single_tool_result_renders_as_user_message;
          Alcotest.test_case
            "consecutive_tool_results_coalesce_into_one_user_message" `Quick
            test_consecutive_tool_results_coalesce_into_one_user_message;
          Alcotest.test_case "tool_result_is_error_flag_propagates" `Quick
            test_tool_result_is_error_flag_propagates;
          Alcotest.test_case
            "tool_results_between_other_messages_do_not_over_merge" `Quick
            test_tool_results_between_other_messages_do_not_over_merge;
        ] );
    ]
