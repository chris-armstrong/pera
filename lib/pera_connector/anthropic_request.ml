open Containers
open Pera_types

(** {1 Cache-control helpers} *)

(** Sort an assoc list alphabetically by key. *)
let sort_assoc_pairs pairs =
  List.sort (fun (a, _) (b, _) -> String.compare a b) pairs

(** Build an Anthropic [cache_control] marker for the given TTL. *)
let cache_marker ttl =
  match ttl with
  | Types.Five_minutes -> `Assoc [ ("type", `String "ephemeral") ]
  | Types.One_hour ->
      `Assoc
        (sort_assoc_pairs
           [ ("type", `String "ephemeral"); ("ttl", `String "1h") ])

(** Add a [cache_control] marker to an existing JSON object, keeping its keys
    alphabetically sorted. *)
let with_cache_control marker (`Assoc pairs) =
  `Assoc (sort_assoc_pairs (("cache_control", marker) :: pairs))

(** Tag the last JSON object in a list with a cache-control marker. *)
let tag_last_assoc marker blocks =
  match List.rev blocks with
  | [] -> blocks
  | (`Assoc _ as last) :: rest ->
      let tagged = with_cache_control marker last in
      List.rev (tagged :: rest)
  | _ -> blocks

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

(** Render a [Connector.UserMessage] payload to the Anthropic content array. *)
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

(** Render a [Connector.AssistantMessage] payload to the Anthropic content array.
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

(** Render a [Connector.ToolResultMessage] as a single accumulated block to be
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
  | Connector.ToolResultMessage trc ->
      (* Accumulate into the current run of tool results. *)
      let block = tool_result_block trc in
      {
        state with
        pending_tool_results = state.pending_tool_results @ [ block ];
      }
  | Connector.UserMessage { role; content } ->
      (* A non-tool-result message ends any in-progress tool-result run. *)
      let state = flush_pending_tool_results state in
      let content_json = user_content_to_json_list content in
      let json =
        `Assoc [ ("role", `String role); ("content", `List content_json) ]
      in
      { state with rendered = json :: state.rendered }
  | Connector.AssistantMessage { content; _ } ->
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

(** Render a [Connector.tool_schema] to the Anthropic tools array format. Fields
    are emitted in alphabetical key order so the wire bytes are stable across
    identical tool definitions. *)
let tool_to_json (tool : Connector.tool_schema) =
  `Assoc
    [
      ("description", `String tool.description);
      ("input_schema", Json_schema.to_json tool.schema);
      ("name", `String tool.name);
    ]

(** Render the system prompt. When the cache policy includes the system
    breakpoint, emit it as a content-block array with a [cache_control] marker
    on the last text block. *)
let system_to_json cache_policy ttl system =
  if String.is_empty system then None
  else
    match cache_policy with
    | Types.No_cache -> Some (`String system)
    | Types.Conversation | Types.SystemAndToolsOnly ->
        let marker = cache_marker ttl in
        let block =
          with_cache_control marker
            (`Assoc [ ("type", `String "text"); ("text", `String system) ])
        in
        Some (`List [ block ])

(** Tag the last tool in the rendered tools array with a cache-control marker.
*)
let tag_last_tool marker tools = tag_last_assoc marker tools

(** Tag the last content block of the last user message with a cache-control
    marker. The last rendered message is expected to be a user message at turn
    start; any other role is an invariant violation. *)
let tag_last_user_message marker messages =
  let update_message (`Assoc fields) =
    let content =
      match List.assoc_opt ~eq:String.equal "content" fields with
      | Some (`List xs) -> xs
      | other ->
          failwith
            (Fmt.str "tag_last_user_message: expected content list, got %s"
               (Yojson.Safe.to_string (Option.value ~default:`Null other)))
    in
    let new_content = tag_last_assoc marker content in
    let new_fields =
      List.map
        (fun (k, v) ->
          if String.equal k "content" then (k, `List new_content) else (k, v))
        fields
    in
    `Assoc (sort_assoc_pairs new_fields)
  in
  match List.rev messages with
  | (`Assoc fields as last) :: rest -> (
      match List.assoc_opt ~eq:String.equal "role" fields with
      | Some (`String "user") -> List.rev (update_message last :: rest)
      | _ ->
          failwith
            "tag_last_user_message: expected last message to have role 'user'")
  | _ -> messages

let build_request_body ~model ~context ~options =
  let open Connector in
  let messages_json = messages_to_json context.messages in
  let tools_json = List.map tool_to_json context.tools in
  let marker = cache_marker options.cache_ttl in
  let tagged_tools =
    match options.cache_policy with
    | Types.No_cache -> tools_json
    | Types.Conversation | Types.SystemAndToolsOnly ->
        tag_last_tool marker tools_json
  in
  let tagged_messages =
    match options.cache_policy with
    | Types.Conversation -> tag_last_user_message marker messages_json
    | Types.No_cache | Types.SystemAndToolsOnly -> messages_json
  in
  let base_fields =
    [
      ("model", `String model.Types.id);
      ("max_tokens", `Int options.max_tokens);
      ("stream", `Bool true);
      ("messages", `List tagged_messages);
    ]
  in
  let with_system =
    match
      system_to_json options.cache_policy options.cache_ttl context.system
    with
    | None -> base_fields
    | Some sys -> base_fields @ [ ("system", sys) ]
  in
  let with_tools =
    if List.is_empty tagged_tools then with_system
    else with_system @ [ ("tools", `List tagged_tools) ]
  in
  let with_thinking =
    match options.thinking_budget_tokens with
    | None -> with_tools
    | Some budget ->
        with_tools
        @ [ ("thinking",
              `Assoc [ ("type", `String "enabled");
                        ("budget_tokens", `Int budget) ]) ]
  in
  let with_temperature =
    match options.temperature with
    | None -> with_thinking
    | Some t -> with_thinking @ [ ("temperature", `Float t) ]
  in
  `Assoc with_temperature
