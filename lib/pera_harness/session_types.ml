open Containers

type entry_id = Entry_id.t

type session_info_entry = {
  id : entry_id;
  timestamp : float;
  session_id : string;
  cwd : string;
  model : Pera_types.Types.model;
  parent_session_id : string option;
}

type message_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
  message : Pera_connector.Connector.message;
}

type leaf_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
}

type model_change_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
  model : Pera_types.Types.model;
}

type thinking_level_change_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
  thinking_enabled : bool;
}

type compaction_entry = {
  id : entry_id;
  parent_id : entry_id option;
  timestamp : float;
  summary : string;
  first_kept_entry_id : entry_id;
}

type session_entry =
  | SessionInfo of session_info_entry
  | Message of message_entry
  | Leaf of leaf_entry
  | ModelChange of model_change_entry
  | ThinkingLevelChange of thinking_level_change_entry
  | Compaction of compaction_entry

let stop_reason_to_string = function
  | Pera_types.Types.EndTurn -> "end_turn"
  | Pera_types.Types.ToolUse -> "tool_use"
  | Pera_types.Types.MaxTokens -> "max_tokens"
  | Pera_types.Types.StopSequence -> "stop_sequence"
  | Pera_types.Types.Error _ -> "error"
  | Pera_types.Types.Aborted -> "aborted"

let user_content_to_json = function
  | Pera_types.Types.UText t ->
      `Assoc [ ("type", `String "text"); ("text", `String t) ]
  | Pera_types.Types.UImage { url; media_type } ->
      `Assoc
        [
          ("type", `String "image");
          ("url", `String url);
          ("media_type", `String media_type);
        ]

let assistant_content_to_json = function
  | Pera_types.Types.AText t ->
      `Assoc [ ("type", `String "text"); ("text", `String t) ]
  | Pera_types.Types.AThinking { text; signature } ->
      let fields =
        [ ("type", `String "thinking"); ("text", `String text) ]
        @ Option.map_or ~default:[]
            (fun s -> [ ("signature", `String s) ])
            signature
      in
      `Assoc fields
  | Pera_types.Types.AToolCall { id; name; arguments } ->
      `Assoc
        [
          ("type", `String "tool_call");
          ("id", `String id);
          ("name", `String name);
          ("arguments", arguments);
        ]

let usage_to_json (u : Pera_types.Types.usage) =
  let base =
    [
      ("input_tokens", `Int u.input_tokens);
      ("output_tokens", `Int u.output_tokens);
      ("cache_read_tokens", `Int u.cache_read_tokens);
      ("cache_write_tokens", `Int u.cache_write_tokens);
    ]
  in
  let cost_field =
    Option.map_or ~default:[]
      (fun d -> [ ("cost_usd", `String (Decimal.to_string d)) ])
      u.cost_usd
  in
  `Assoc (base @ cost_field)

let provenance_to_json (p : Pera_types.Types.provenance) =
  let base =
    [
      ("api", `String p.api);
      ("provider", `String p.provider);
      ("model", `String p.model);
    ]
  in
  let err_field =
    Option.map_or ~default:[]
      (fun e -> [ ("error_message", `String e) ])
      p.error_message
  in
  `Assoc (base @ err_field)

let message_to_json = function
  | Pera_connector.Connector.UserMessage { role; content } ->
      let content_json = List.map user_content_to_json content in
      `Assoc [ ("role", `String role); ("content", `List content_json) ]
  | Pera_connector.Connector.AssistantMessage am ->
      let content_json = List.map assistant_content_to_json am.content in
      `Assoc
        [
          ("role", `String "assistant");
          ("content", `List content_json);
          ("stop_reason", `String (stop_reason_to_string am.stop_reason));
          ("provenance", provenance_to_json am.provenance);
          ("usage", usage_to_json am.usage);
        ]
  | Pera_connector.Connector.ToolResultMessage { tool_call_id; content; is_error }
    ->
      `Assoc
        [
          ("role", `String "tool_result");
          ("tool_call_id", `String tool_call_id);
          ("content", content);
          ("is_error", `Bool is_error);
        ]

let maybe_parent_id_field = function
  | None -> []
  | Some pid -> [ ("parent_id", `String (Entry_id.to_string pid)) ]

let base_fields ~id ~type_str ~timestamp ~parent_id =
  [
    ("id", `String (Entry_id.to_string id));
    ("type", `String type_str);
    ("timestamp", `Float timestamp);
  ]
  @ maybe_parent_id_field parent_id

let entry_to_json = function
  | SessionInfo e ->
      let model_json =
        `Assoc
          [
            ("id", `String e.model.id);
            ("api", `String e.model.api);
            ("context_window", `Int e.model.context_window);
          ]
      in
      let base =
        base_fields ~id:e.id ~type_str:"session_info" ~timestamp:e.timestamp
          ~parent_id:None
      in
      let extra =
        [
          ("session_id", `String e.session_id);
          ("cwd", `String e.cwd);
          ("model", model_json);
        ]
        @ Option.map_or ~default:[]
            (fun psid -> [ ("parent_session_id", `String psid) ])
            e.parent_session_id
      in
      `Assoc (base @ extra)
  | Message e ->
      let base =
        base_fields ~id:e.id ~type_str:"message" ~timestamp:e.timestamp
          ~parent_id:e.parent_id
      in
      let msg_json = message_to_json e.message in
      `Assoc (base @ [ ("message", msg_json) ])
  | Leaf e ->
      let base =
        base_fields ~id:e.id ~type_str:"leaf" ~timestamp:e.timestamp
          ~parent_id:e.parent_id
      in
      `Assoc base
  | ModelChange e ->
      let model_json =
        `Assoc
          [
            ("id", `String e.model.id);
            ("api", `String e.model.api);
            ("context_window", `Int e.model.context_window);
          ]
      in
      let base =
        base_fields ~id:e.id ~type_str:"model_change" ~timestamp:e.timestamp
          ~parent_id:e.parent_id
      in
      `Assoc (base @ [ ("model", model_json) ])
  | ThinkingLevelChange e ->
      let base =
        base_fields ~id:e.id ~type_str:"thinking_level_change"
          ~timestamp:e.timestamp ~parent_id:e.parent_id
      in
      `Assoc (base @ [ ("thinking_enabled", `Bool e.thinking_enabled) ])
  | Compaction e ->
      let base =
        base_fields ~id:e.id ~type_str:"compaction" ~timestamp:e.timestamp
          ~parent_id:e.parent_id
      in
      `Assoc
        (base
        @ [
            ("summary", `String e.summary);
            ( "first_kept_entry_id",
              `String (Entry_id.to_string e.first_kept_entry_id) );
          ])
