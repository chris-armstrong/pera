open Containers
open Pera_types
open Pera_provider
open Provider_test_helpers

(** Check that [key] is absent from an assoc list. *)
let assoc_absent key fields =
  match List.assoc_opt ~eq:String.equal key fields with
  | None -> ()
  | Some _ -> Alcotest.failf "expected key %S to be absent" key

(* ── messages_to_json tests ── *)

let test_user_message_renders_as_role_user () =
  (* Arrange *)
  let messages =
    [
      Provider.UserMessage
        { Types.role = "user"; content = [ Types.UText "hello" ] };
    ]
  in
  (* Act *)
  let json =
    Openai_completions_request.messages_to_json
      ~compat:Openai_completions_request.default_compat messages
  in
  (* Assert *)
  Alcotest.(check int) "one message" 1 (List.length json);
  let msg_fields =
    match json with
    | msg :: _ -> as_assoc "message[0]" msg
    | [] -> Alcotest.fail "expected at least one message"
  in
  let role = assoc_exn "role" msg_fields |> as_string "role" in
  Alcotest.(check string) "role is user" "user" role;
  let content = assoc_exn "content" msg_fields |> as_string "content" in
  Alcotest.(check string) "content is hello" "hello" content

let test_assistant_text_message_renders_correctly () =
  (* Arrange *)
  let messages =
    [
      Provider.AssistantMessage
        {
          Types.content = [ Types.AText "the text" ];
          stop_reason = Types.EndTurn;
          provenance =
            {
              Types.api = "openai-completions";
              provider = "OpenAI";
              model = "gpt-4";
              error_message = None;
            };
          usage =
            {
              Types.input_tokens = 0;
              output_tokens = 0;
              cache_read_tokens = 0;
              cache_write_tokens = 0;
              cost_usd = None;
            };
        };
    ]
  in
  (* Act *)
  let json =
    Openai_completions_request.messages_to_json
      ~compat:Openai_completions_request.default_compat messages
  in
  (* Assert *)
  Alcotest.(check int) "one message" 1 (List.length json);
  let msg_fields =
    match json with
    | msg :: _ -> as_assoc "message[0]" msg
    | [] -> Alcotest.fail "expected at least one message"
  in
  let role = assoc_exn "role" msg_fields |> as_string "role" in
  Alcotest.(check string) "role is assistant" "assistant" role;
  let content = assoc_exn "content" msg_fields |> as_string "content" in
  Alcotest.(check string) "content is the text" "the text" content

let test_tool_result_renders_without_name_field () =
  (* Arrange *)
  let messages = [ make_tool_result "call_abc" "ok" ] in
  (* Act *)
  let json =
    Openai_completions_request.messages_to_json
      ~compat:Openai_completions_request.default_compat messages
  in
  (* Assert *)
  Alcotest.(check int) "one message" 1 (List.length json);
  let msg_fields =
    match json with
    | msg :: _ -> as_assoc "message[0]" msg
    | [] -> Alcotest.fail "expected at least one message"
  in
  let role = assoc_exn "role" msg_fields |> as_string "role" in
  Alcotest.(check string) "role is tool" "tool" role;
  let tool_call_id =
    assoc_exn "tool_call_id" msg_fields |> as_string "tool_call_id"
  in
  Alcotest.(check string) "tool_call_id matches" "call_abc" tool_call_id;
  let content = assoc_exn "content" msg_fields |> as_string "content" in
  Alcotest.(check string) "content matches" "ok" content;
  assoc_absent "name" msg_fields

let test_tool_result_renders_with_name_when_required () =
  (* Arrange *)
  let find_tool_name ~tool_call_id =
    if String.equal tool_call_id "call_abc" then Some "fn" else None
  in
  let messages = [ make_tool_result "call_abc" "ok" ] in
  let compat =
    {
      Openai_completions_request.default_compat with
      require_tool_result_name = true;
    }
  in
  (* Act *)
  let json =
    Openai_completions_request.messages_to_json ~compat ~find_tool_name messages
  in
  (* Assert *)
  Alcotest.(check int) "one message" 1 (List.length json);
  let msg_fields =
    match json with
    | msg :: _ -> as_assoc "message[0]" msg
    | [] -> Alcotest.fail "expected at least one message"
  in
  let role = assoc_exn "role" msg_fields |> as_string "role" in
  Alcotest.(check string) "role is tool" "tool" role;
  let tool_call_id =
    assoc_exn "tool_call_id" msg_fields |> as_string "tool_call_id"
  in
  Alcotest.(check string) "tool_call_id matches" "call_abc" tool_call_id;
  let name = assoc_exn "name" msg_fields |> as_string "name" in
  Alcotest.(check string) "name is fn" "fn" name

(* ── build_request_body tests ── *)

let test_build_request_body_includes_system_as_first_message () =
  (* Arrange *)
  let context =
    { (make_context []) with Provider.system = "You are helpful" }
  in
  let options = make_options () in
  let model = { Types.id = "gpt-4"; api = "openai-completions" } in
  (* Act *)
  let body =
    Openai_completions_request.build_request_body ~model ~context ~options
      ~compat:Openai_completions_request.default_compat
  in
  (* Assert *)
  let fields = as_assoc "body" body in
  let messages_json = assoc_exn "messages" fields |> as_list "messages" in
  Alcotest.(check int) "one message" 1 (List.length messages_json);
  let first_fields =
    match messages_json with
    | msg :: _ -> as_assoc "message[0]" msg
    | [] -> Alcotest.fail "expected at least one message"
  in
  let role = assoc_exn "role" first_fields |> as_string "role" in
  Alcotest.(check string) "role is system" "system" role;
  let content = assoc_exn "content" first_fields |> as_string "content" in
  Alcotest.(check string) "content is system prompt" "You are helpful" content

let test_build_request_body_includes_tools_as_functions_array () =
  (* Arrange *)
  let tool =
    {
      Provider.name = "echo";
      description = "Echoes text";
      schema = Json_schema.object_ ~properties:[] ~required:[] ();
    }
  in
  let context = { (make_context []) with Provider.tools = [ tool ] } in
  let options = make_options () in
  let model = { Types.id = "gpt-4"; api = "openai-completions" } in
  (* Act *)
  let body =
    Openai_completions_request.build_request_body ~model ~context ~options
      ~compat:Openai_completions_request.default_compat
  in
  (* Assert *)
  let fields = as_assoc "body" body in
  let tools_json = assoc_exn "tools" fields |> as_list "tools" in
  Alcotest.(check int) "one tool" 1 (List.length tools_json);
  let tool_obj =
    match tools_json with
    | t :: _ -> as_assoc "tool[0]" t
    | [] -> Alcotest.fail "expected at least one tool"
  in
  let type_ = assoc_exn "type" tool_obj |> as_string "type" in
  Alcotest.(check string) "type is function" "function" type_

let test_max_tokens_field_uses_max_completion_tokens_by_default () =
  (* Arrange *)
  let context = make_context [] in
  let options = make_options () in
  let model = { Types.id = "gpt-4"; api = "openai-completions" } in
  (* Act *)
  let body =
    Openai_completions_request.build_request_body ~model ~context ~options
      ~compat:Openai_completions_request.default_compat
  in
  (* Assert *)
  let fields = as_assoc "body" body in
  let _ = assoc_exn "max_completion_tokens" fields in
  assoc_absent "max_tokens" fields

let test_max_tokens_field_switches_per_compat () =
  (* Arrange *)
  let compat =
    {
      Openai_completions_request.default_compat with
      max_tokens_field = "max_tokens";
    }
  in
  let context = make_context [] in
  let options = make_options () in
  let model = { Types.id = "gpt-4"; api = "openai-completions" } in
  (* Act *)
  let body =
    Openai_completions_request.build_request_body ~model ~context ~options
      ~compat
  in
  (* Assert *)
  let fields = as_assoc "body" body in
  let _ = assoc_exn "max_tokens" fields in
  assoc_absent "max_completion_tokens" fields

(* ── compat preset tests ── *)

let test_zen_compat_presets_are_correct () =
  let c = Openai_completions_request.opencode_zen_compat in
  Alcotest.(check string) "base_url" "https://zen.opencode.ai" c.base_url;
  Alcotest.(check string)
    "reasoning_field" "reasoning_content" c.reasoning_field;
  Alcotest.(check string)
    "max_tokens_field" "max_completion_tokens" c.max_tokens_field;
  Alcotest.(check bool)
    "require_tool_result_name" false c.require_tool_result_name

let test_go_compat_presets_are_correct () =
  let c = Openai_completions_request.opencode_go_compat in
  Alcotest.(check string) "base_url" "https://go.opencode.ai" c.base_url;
  Alcotest.(check string) "reasoning_field" "reasoning" c.reasoning_field;
  Alcotest.(check string)
    "max_tokens_field" "max_completion_tokens" c.max_tokens_field;
  Alcotest.(check bool)
    "require_tool_result_name" false c.require_tool_result_name

(* ── Test runner ── *)

let () =
  Alcotest.run "OpenAI_completions_request"
    [
      ( "message_rendering",
        [
          Alcotest.test_case "user_message_renders_as_role_user" `Quick
            test_user_message_renders_as_role_user;
          Alcotest.test_case "assistant_text_message_renders_correctly" `Quick
            test_assistant_text_message_renders_correctly;
          Alcotest.test_case "tool_result_renders_without_name_field" `Quick
            test_tool_result_renders_without_name_field;
          Alcotest.test_case "tool_result_renders_with_name_when_required"
            `Quick test_tool_result_renders_with_name_when_required;
        ] );
      ( "request_body",
        [
          Alcotest.test_case
            "build_request_body_includes_system_as_first_message" `Quick
            test_build_request_body_includes_system_as_first_message;
          Alcotest.test_case
            "build_request_body_includes_tools_as_functions_array" `Quick
            test_build_request_body_includes_tools_as_functions_array;
          Alcotest.test_case
            "max_tokens_field_uses_max_completion_tokens_by_default" `Quick
            test_max_tokens_field_uses_max_completion_tokens_by_default;
          Alcotest.test_case "max_tokens_field_switches_per_compat" `Quick
            test_max_tokens_field_switches_per_compat;
        ] );
      ( "compat_presets",
        [
          Alcotest.test_case "zen_compat_presets_are_correct" `Quick
            test_zen_compat_presets_are_correct;
          Alcotest.test_case "go_compat_presets_are_correct" `Quick
            test_go_compat_presets_are_correct;
        ] );
    ]
