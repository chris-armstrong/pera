open Containers
open Pera_types

type compat = {
  base_url : string;
  reasoning_field : string;
  max_tokens_field : string;
  require_tool_result_name : bool;
  enable_thinking_field : string option;
      (** If [Some field], send [field: true] in the request body when
          [context.thinking = true]. Use [None] for providers that enable
          thinking via model selection (e.g. OpenAI o-series). *)
}
(** Per-endpoint compatibility configuration for the OpenAI chat-completions
    API.

    Different providers that expose the same wire format have minor differences
    in field names (e.g. [max_completion_tokens] vs [max_tokens]) and optional
    fields (e.g. whether tool-result messages require a [name]). *)

let opencode_zen_compat =
  {
    base_url = "https://zen.opencode.ai";
    reasoning_field = "reasoning_content";
    max_tokens_field = "max_completion_tokens";
    require_tool_result_name = false;
    enable_thinking_field = Some "enable_thinking";
  }

let opencode_go_compat =
  {
    base_url = "https://opencode.ai/zen/go";
    reasoning_field = "reasoning_content";
    max_tokens_field = "max_completion_tokens";
    require_tool_result_name = false;
    enable_thinking_field = Some "enable_thinking";
  }

let default_compat =
  {
    base_url = "https://api.openai.com";
    reasoning_field = "reasoning_content";
    max_tokens_field = "max_completion_tokens";
    require_tool_result_name = false;
    enable_thinking_field = Some "enable_thinking";
  }

(** Select a compatibility preset by name. Valid values:
    - ["openai"] → default (api.openai.com)
    - ["zen"]    → zen.opencode.ai
    - ["go"]     → opencode.ai/zen/go/v1/chat/completions
    Unknown values fall back to [default_compat]. *)
let compat_of_string = function
  | "zen" -> opencode_zen_compat
  | "go" -> opencode_go_compat
  | _ -> default_compat

(** Convert a [Yojson.Safe.t] to the string representation expected by the
    OpenAI API for message content fields. [`String s] is unwrapped to [s];
    other JSON values are serialised with [Yojson.Safe.to_string]. *)
let yojson_to_content_string = function
  | `String s -> s
  | other -> Yojson.Safe.to_string other

(** Render a single [Types.user_content] block to OpenAI user-message content.
*)
let user_content_to_json content =
  match content with
  | Types.UText text -> `String text
  | Types.UImage { url; media_type } ->
      `Assoc
        [
          ("type", `String "image_url");
          ( "image_url",
            `Assoc [ ("url", `String url); ("media_type", `String media_type) ]
          );
        ]

(** Render a [Provider.UserMessage] to the OpenAI messages format.

    Simple text-only messages use a plain string [content] field. Mixed or image
    content uses the array format. *)
let user_message_to_json (msg : Types.user_message) =
  let content_json = List.map user_content_to_json msg.content in
  let content =
    match content_json with
    | [ `String text ] -> `String text
    | _ -> `List content_json
  in
  `Assoc [ ("role", `String msg.role); ("content", content) ]

(** Render a [Types.assistant_content] block to OpenAI assistant-message
    content. *)
let assistant_content_to_json = function
  | Types.AText text -> `String text
  | Types.AThinking { text; _ } ->
      (* TODO: OpenAI completions API does not natively support thinking blocks
         in conversation history. Dropped for now. *)
      `String text
  | Types.AToolCall { id; name; arguments } ->
      `Assoc
        [
          ("id", `String id);
          ("type", `String "function");
          ( "function",
            `Assoc
              [
                ("name", `String name);
                ("arguments", `String (Yojson.Safe.to_string arguments));
              ] );
        ]

(** Render a [Provider.AssistantMessage] to the OpenAI messages format.

    Text-only messages use a plain string [content] field. Messages containing
    tool calls use the [tool_calls] array and set [content] to [null]. *)
let is_tool_call = function
  | Types.AToolCall _ -> true
  | Types.AText _ | Types.AThinking _ -> false

let tool_call_block_to_json = function
  | Types.AToolCall _ as block -> Some (assistant_content_to_json block)
  | Types.AText _ | Types.AThinking _ -> None

let text_of_content = function
  | Types.AText s -> Some s
  | Types.AThinking _ | Types.AToolCall _ -> None

let assistant_message_to_json (msg : Types.assistant_message) =
  let has_tool_calls = List.exists is_tool_call msg.content in
  if has_tool_calls then
    let tool_calls = List.filter_map tool_call_block_to_json msg.content in
    let texts = List.filter_map text_of_content msg.content in
    let content =
      match texts with
      | [] -> `Null
      | [ single ] -> `String single
      | many -> `String (String.concat "\n" many)
    in
    `Assoc
      [
        ("role", `String "assistant");
        ("content", content);
        ("tool_calls", `List tool_calls);
      ]
  else
    let texts = List.filter_map text_of_content msg.content in
    let content =
      match texts with
      | [ single ] -> `String single
      | _ -> `String (String.concat "\n" texts)
    in
    `Assoc [ ("role", `String "assistant"); ("content", content) ]

(** Render a [Provider.ToolResultMessage] to the OpenAI messages format. *)
let tool_result_message_to_json ?find_tool_name
    (trc : Types.tool_result_content) =
  let base_fields =
    [
      ("role", `String "tool");
      ("tool_call_id", `String trc.tool_call_id);
      ("content", `String (yojson_to_content_string trc.content));
    ]
  in
  let with_name =
    match find_tool_name with
    | Some f -> (
        match f ~tool_call_id:trc.tool_call_id with
        | Some name -> base_fields @ [ ("name", `String name) ]
        | None -> base_fields)
    | None -> base_fields
  in
  `Assoc with_name

(** Render one [Provider.message] to the OpenAI messages format. *)
let message_to_json ?find_tool_name = function
  | Provider.UserMessage msg -> user_message_to_json msg
  | Provider.AssistantMessage msg -> assistant_message_to_json msg
  | Provider.ToolResultMessage trc ->
      tool_result_message_to_json ?find_tool_name trc

let messages_to_json ?find_tool_name ~compat:_ messages =
  (* [~compat] is reserved for future endpoint-specific message formatting
     (e.g. per-endpoint field-name differences in message objects). *)
  List.map (message_to_json ?find_tool_name) messages

(** Render a [Provider.tool_schema] to the OpenAI tools array format.
    The nested [function] object fields are emitted in alphabetical key order
    so the wire bytes are stable across identical tool definitions. *)
let tool_to_json (tool : Provider.tool_schema) =
  `Assoc
    [
      ( "function",
        `Assoc
          [
            ("description", `String tool.description);
            ("name", `String tool.name);
            ("parameters", Json_schema.to_json tool.schema);
          ] );
      ("type", `String "function");
    ]

let extract_tool_name acc = function
  | Types.AToolCall { id; name; _ } -> (id, name) :: acc
  | Types.AText _ | Types.AThinking _ -> acc

let extract_tool_names_from_message acc = function
  | Provider.AssistantMessage { content; _ } ->
      List.fold_left extract_tool_name acc content
  | Provider.UserMessage _ | Provider.ToolResultMessage _ -> acc

(** Build a tool-name lookup closure by scanning [messages] for
    [AssistantMessage] entries that contain [AToolCall] blocks. *)
let build_tool_name_lookup messages =
  let id_name_pairs =
    List.fold_left extract_tool_names_from_message [] messages
  in
  fun ~tool_call_id ->
    List.assoc_opt ~eq:String.equal tool_call_id id_name_pairs

let build_request_body ~model ~context ~options ~compat =
  let open Provider in
  let find_tool_name =
    if compat.require_tool_result_name then
      Some (build_tool_name_lookup context.messages)
    else None
  in
  let messages_json =
    messages_to_json ?find_tool_name ~compat context.messages
  in
  let with_system =
    if String.is_empty context.system then messages_json
    else
      `Assoc [ ("role", `String "system"); ("content", `String context.system) ]
      :: messages_json
  in
  let base_fields =
    [
      ("model", `String model.Types.id);
      ("stream", `Bool true);
      ("stream_options", `Assoc [ ("include_usage", `Bool true) ]);
      ("messages", `List with_system);
      (compat.max_tokens_field, `Int options.max_tokens);
    ]
  in
  let with_thinking =
    match (context.thinking, compat.enable_thinking_field) with
    | true, Some field -> base_fields @ [ (field, `Bool true) ]
    | _ -> base_fields
  in
  let with_tools =
    if List.is_empty context.tools then with_thinking
    else
      with_thinking @ [ ("tools", `List (List.map tool_to_json context.tools)) ]
  in
  let with_temperature =
    match options.temperature with
    | None -> with_tools
    | Some t -> with_tools @ [ ("temperature", `Float t) ]
  in
  `Assoc with_temperature
