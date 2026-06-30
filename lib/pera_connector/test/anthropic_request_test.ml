open Containers
open Pera_types
open Pera_connector
open Provider_test_helpers

(** {1 Cache-control marker tests} *)

let tool_schema name description schema =
  Pera_connector.Connector.{ name; description; schema }

let empty_schema = Json_schema.object_ ~properties:[] ~required:[] ()
let read_tool = tool_schema "read" "Read a file" empty_schema
let write_tool = tool_schema "write" "Write a file" empty_schema

let user_message text =
  Connector.UserMessage { Types.role = "user"; content = [ Types.UText text ] }

(** Build a fixture context with system prompt, two tools, and one user message.
*)
let make_cache_context () =
  {
    Connector.system = "You are helpful";
    messages = [ user_message "hello" ];
    tools = [ read_tool; write_tool ];
  }

(** Build options for a specific cache policy and TTL. *)
let make_cache_options policy ttl =
  make_options ~cache_policy:policy ~cache_ttl:ttl ()

(** Render a full request body for the cache fixture. *)
let render_cache_body policy ttl =
  let context = make_cache_context () in
  let options = make_cache_options policy ttl in
  Anthropic_request.build_request_body ~model:test_model ~context ~options

(** Check whether a JSON value (or any nested value) contains at least one
    [cache_control] key. *)
let rec has_cache_control json =
  match json with
  | `Assoc fields ->
      List.exists
        (fun (k, v) -> String.equal k "cache_control" || has_cache_control v)
        fields
  | `List xs -> List.exists has_cache_control xs
  | _ -> false

(** Count how many [cache_control] markers appear in a JSON value. *)
let rec count_cache_control json =
  match json with
  | `Assoc fields ->
      List.fold_left
        (fun acc (k, v) ->
          let here = if String.equal k "cache_control" then 1 else 0 in
          acc + here + count_cache_control v)
        0 fields
  | `List xs -> List.fold_left (fun acc x -> acc + count_cache_control x) 0 xs
  | _ -> 0

(** Find the first [cache_control] value in a JSON tree. *)
let rec find_first_cache_control json =
  match json with
  | `Assoc fields ->
      let direct = List.assoc_opt ~eq:String.equal "cache_control" fields in
      if Option.is_some direct then direct
      else List.find_map (fun (_, v) -> find_first_cache_control v) fields
  | `List xs -> List.find_map find_first_cache_control xs
  | _ -> None

(** Find the [system] field of a request body. *)
let system_of_body body =
  let fields = as_assoc "body" body in
  List.assoc_opt ~eq:String.equal "system" fields

(** Find the [tools] field of a request body. *)
let tools_of_body body =
  let fields = as_assoc "body" body in
  List.assoc_opt ~eq:String.equal "tools" fields |> Option.map (as_list "tools")

(** Find the [messages] field of a request body. *)
let messages_of_body body =
  let fields = as_assoc "body" body in
  List.assoc_opt ~eq:String.equal "messages" fields
  |> Option.map (as_list "messages")

(** Extract the last element of a list. *)
let last_opt xs = match List.rev xs with [] -> None | x :: _ -> Some x

(* ── Test: No_cache emits no cache_control markers ── *)

let test_no_cache_emits_no_markers () =
  (* Arrange *)
  let body = render_cache_body Types.No_cache Types.Five_minutes in
  (* Assert *)
  Alcotest.(check int) "no cache_control markers" 0 (count_cache_control body)

(* ── Test: Conversation tags system, last tool, and last user message ── *)

let test_conversation_tags_all_three_breakpoints () =
  (* Arrange *)
  let body = render_cache_body Types.Conversation Types.Five_minutes in
  (* Assert: exactly three markers *)
  Alcotest.(check int)
    "three cache_control markers" 3 (count_cache_control body);
  (* System is an array with one text block carrying the marker *)
  let system =
    system_of_body body
    |> Option.get_exn_or "expected system field"
    |> as_list "system"
  in
  Alcotest.(check int) "system has one block" 1 (List.length system);
  let system_block =
    match system with
    | [ block ] -> as_assoc "system[0]" block
    | _ -> Alcotest.fail "expected exactly one system block"
  in
  let _ = assoc_exn "cache_control" system_block in
  let _ = assoc_exn "text" system_block in
  (* Last tool carries the marker *)
  let tools = tools_of_body body |> Option.get_exn_or "expected tools field" in
  let last_tool =
    last_opt tools |> Option.get_exn_or "expected at least one tool"
  in
  let _ = assoc_exn "cache_control" (as_assoc "last tool" last_tool) in
  (* Last message carries the marker *)
  let messages =
    messages_of_body body |> Option.get_exn_or "expected messages field"
  in
  let last_msg =
    last_opt messages |> Option.get_exn_or "expected at least one message"
  in
  let msg_fields = as_assoc "last message" last_msg in
  Alcotest.(check string)
    "last message role is user" "user"
    (assoc_exn "role" msg_fields |> as_string "role");
  let content =
    assoc_exn "content" msg_fields |> as_list "last message content"
  in
  let last_block =
    last_opt content |> Option.get_exn_or "expected at least one content block"
  in
  let _ =
    assoc_exn "cache_control" (as_assoc "last content block" last_block)
  in
  ()

(* ── Test: SystemAndToolsOnly tags system and last tool, not last message ── *)

let test_system_and_tools_only_tags_system_and_tools () =
  (* Arrange *)
  let body = render_cache_body Types.SystemAndToolsOnly Types.Five_minutes in
  (* Assert: exactly two markers *)
  Alcotest.(check int) "two cache_control markers" 2 (count_cache_control body);
  (* Last message does NOT carry a marker *)
  let messages =
    messages_of_body body |> Option.get_exn_or "expected messages field"
  in
  let last_msg =
    last_opt messages |> Option.get_exn_or "expected at least one message"
  in
  let content =
    assoc_exn "content" (as_assoc "last message" last_msg)
    |> as_list "last message content"
  in
  let last_block =
    last_opt content |> Option.get_exn_or "expected at least one content block"
  in
  Alcotest.(check bool)
    "last message block has no cache_control" false
    (has_cache_control last_block)

(* ── Test: Five_minutes TTL omits ttl field ── *)

let test_five_minutes_ttl_emits_ephemeral_only () =
  (* Arrange *)
  let body = render_cache_body Types.Conversation Types.Five_minutes in
  (* Act *)
  let marker =
    find_first_cache_control body
    |> Option.get_exn_or "expected a cache_control marker"
  in
  (* Assert *)
  let marker_str = Yojson.Safe.to_string marker in
  Alcotest.(check string)
    "five minute marker is ephemeral only" {|{"type":"ephemeral"}|} marker_str

(* ── Test: One_hour TTL includes ttl field ── *)

let test_one_hour_ttl_includes_ttl_field () =
  (* Arrange *)
  let body = render_cache_body Types.Conversation Types.One_hour in
  (* Act *)
  let marker =
    find_first_cache_control body
    |> Option.get_exn_or "expected a cache_control marker"
  in
  (* Assert *)
  let marker_str = Yojson.Safe.to_string marker in
  Alcotest.(check string)
    "one hour marker includes ttl" {|{"ttl":"1h","type":"ephemeral"}|}
    marker_str

(* ── Test: empty system still omits system field under cache policy ── *)

let test_empty_system_omits_system_field_even_when_caching () =
  (* Arrange *)
  let context =
    {
      Connector.system = "";
      messages = [ user_message "hello" ];
      tools = [ read_tool ];
    }
  in
  let options = make_cache_options Types.Conversation Types.Five_minutes in
  (* Act *)
  let body =
    Anthropic_request.build_request_body ~model:test_model ~context ~options
  in
  (* Assert *)
  let fields = as_assoc "body" body in
  match List.assoc_opt ~eq:String.equal "system" fields with
  | None -> ()
  | Some _ ->
      Alcotest.fail "expected no system field when system prompt is empty"

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
    Connector.AssistantMessage
      {
        Types.content = [ Types.AText "I will call two tools." ];
        stop_reason = Types.ToolUse;
        provenance =
          {
            Types.protocol = "anthropic";
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
    Connector.UserMessage
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
      ( "cache_control",
        [
          Alcotest.test_case "no_cache_emits_no_markers" `Quick
            test_no_cache_emits_no_markers;
          Alcotest.test_case "conversation_tags_all_three_breakpoints" `Quick
            test_conversation_tags_all_three_breakpoints;
          Alcotest.test_case "system_and_tools_only_tags_system_and_tools"
            `Quick test_system_and_tools_only_tags_system_and_tools;
          Alcotest.test_case "five_minutes_ttl_emits_ephemeral_only" `Quick
            test_five_minutes_ttl_emits_ephemeral_only;
          Alcotest.test_case "one_hour_ttl_includes_ttl_field" `Quick
            test_one_hour_ttl_includes_ttl_field;
          Alcotest.test_case "empty_system_omits_system_field_even_when_caching"
            `Quick test_empty_system_omits_system_field_even_when_caching;
        ] );
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
