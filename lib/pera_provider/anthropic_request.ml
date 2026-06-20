open Containers
open Pera_types

(** Render a single [tool_result_content] as an Anthropic [tool_result] content
    block. *)
let tool_result_block (trc : Types.tool_result_content) =
  `Assoc
    [
      ("type", `String "tool_result");
      ("tool_use_id", `String trc.tool_call_id);
      ("content", trc.content);
      ("is_error", `Bool trc.is_error);
    ]

(** Render a [Provider.UserMessage] payload to the Anthropic content array. *)
let user_content_to_json_list content =
  List.map
    (function
      | Types.UText text ->
          `Assoc [ ("type", `String "text"); ("text", `String text) ]
      | Types.UImage { url; media_type } ->
          `Assoc
            [
              ("type", `String "image");
              ( "source",
                `Assoc
                  [
                    ("type", `String "url");
                    ("url", `String url);
                    ("media_type", `String media_type);
                  ] );
            ])
    content

(** Render a [Provider.AssistantMessage] payload to the Anthropic content array.
*)
let assistant_content_to_json_list content =
  List.map
    (function
      | Types.AText text ->
          `Assoc [ ("type", `String "text"); ("text", `String text) ]
      | Types.AThinking { text; _ } ->
          `Assoc [ ("type", `String "thinking"); ("thinking", `String text) ]
      | Types.AToolCall { id; name; arguments } ->
          `Assoc
            [
              ("type", `String "tool_use");
              ("id", `String id);
              ("name", `String name);
              ("input", arguments);
            ])
    content

(** Render a [Provider.ToolResultMessage] as a single accumulated block to be
    merged into a coalesced user message. *)
let coalesced_tool_result_user_message blocks =
  `Assoc [ ("role", `String "user"); ("content", `List blocks) ]

type fold_state = {
  rendered : Yojson.Safe.t list;
      (** Fully rendered messages, in reverse order. *)
  pending_tool_results : Yojson.Safe.t list;
      (** [tool_result] blocks collected from the current run of consecutive
          [ToolResultMessage] entries, in source order. Non-empty only when we
          are in the middle of a run. *)
}
(** Coalescing fold state: accumulator of rendered Anthropic messages plus an
    optional in-progress run of [tool_result] blocks. *)

(** Flush any pending tool-result blocks as a single coalesced user message and
    return the updated accumulator. *)
let flush_pending_tool_results state =
  match state.pending_tool_results with
  | [] -> state
  | blocks ->
      let user_msg = coalesced_tool_result_user_message blocks in
      { rendered = user_msg :: state.rendered; pending_tool_results = [] }

(** Process one message in the coalescing fold. *)
let fold_one_message state msg =
  match msg with
  | Provider.ToolResultMessage trc ->
      (* Accumulate into the current run of tool results. *)
      let block = tool_result_block trc in
      {
        state with
        pending_tool_results = state.pending_tool_results @ [ block ];
      }
  | Provider.UserMessage { role; content } ->
      (* A non-tool-result message ends any in-progress tool-result run. *)
      let state = flush_pending_tool_results state in
      let content_json = user_content_to_json_list content in
      let json =
        `Assoc [ ("role", `String role); ("content", `List content_json) ]
      in
      { state with rendered = json :: state.rendered }
  | Provider.AssistantMessage { content; _ } ->
      (* A non-tool-result message ends any in-progress tool-result run. *)
      let state = flush_pending_tool_results state in
      let content_json = assistant_content_to_json_list content in
      let json =
        `Assoc
          [ ("role", `String "assistant"); ("content", `List content_json) ]
      in
      { state with rendered = json :: state.rendered }

let messages_to_json messages =
  let initial_state = { rendered = []; pending_tool_results = [] } in
  let final_state = List.fold_left fold_one_message initial_state messages in
  let flushed_state = flush_pending_tool_results final_state in
  List.rev flushed_state.rendered

(** Render a [Provider.tool_schema] to the Anthropic tools array format.
    Fields are emitted in alphabetical key order so the wire bytes are stable
    across identical tool definitions. *)
let tool_to_json (tool : Provider.tool_schema) =
  `Assoc
    [
      ("description", `String tool.description);
      ("input_schema", Json_schema.to_json tool.schema);
      ("name", `String tool.name);
    ]

let build_request_body ~model ~context ~options =
  let open Provider in
  let messages_json = messages_to_json context.messages in
  let base_fields =
    [
      ("model", `String model.Types.id);
      ("max_tokens", `Int options.max_tokens);
      ("stream", `Bool true);
      ("messages", `List messages_json);
    ]
  in
  let with_system =
    if String.is_empty context.system then base_fields
    else base_fields @ [ ("system", `String context.system) ]
  in
  let with_tools =
    if List.is_empty context.tools then with_system
    else
      with_system @ [ ("tools", `List (List.map tool_to_json context.tools)) ]
  in
  let with_temperature =
    match options.temperature with
    | None -> with_tools
    | Some t -> with_tools @ [ ("temperature", `Float t) ]
  in
  `Assoc with_temperature
