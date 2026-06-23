open Containers

let per_message_overhead = 4
let estimate_text s = (String.length s + 2) / 3

let estimate_user_content = function
  | Pera_types.Types.UText s -> estimate_text s
  | Pera_types.Types.UImage _ -> 8

let estimate_assistant_content = function
  | Pera_types.Types.AText s -> estimate_text s
  | Pera_types.Types.AThinking { text; signature = _ } -> estimate_text text
  | Pera_types.Types.AToolCall { id = _; name; arguments } ->
      estimate_text name + estimate_text (Yojson.Safe.to_string arguments)

let estimate_message = function
  | Pera_provider.Provider.UserMessage { role = _; content } ->
      per_message_overhead
      + List.fold_left (fun acc c -> acc + estimate_user_content c) 0 content
  | Pera_provider.Provider.AssistantMessage
      { content; stop_reason = _; provenance = _; usage = _ } ->
      per_message_overhead
      + List.fold_left
          (fun acc c -> acc + estimate_assistant_content c)
          0 content
  | Pera_provider.Provider.ToolResultMessage
      { tool_call_id = _; content; is_error = _ } ->
      per_message_overhead + estimate_text (Yojson.Safe.to_string content)

let estimate_messages messages =
  List.fold_left (fun acc m -> acc + estimate_message m) 0 messages
