open Containers
open Pera_types

(** The active block being streamed. *)
type active_block =
  | ActiveText of { buf : string }
      (** A text block accumulating delta fragments. *)
  | ActiveThinking of { buf : string }
      (** A thinking block accumulating delta fragments. *)
  | ActiveToolUse of {
      index : int;
      id : string;
      name : string;
      json_buf : string;
          (** Concatenated raw input_json_delta fragments — not yet parsed. *)
    }

(** An in-progress tool-use block that has been finalised at content_block_stop.
    We keep a parallel list of finalised tool calls so that we can produce a
    stable content list for partial snapshots even before message_stop. *)
type completed_block =
  | CompletedText of string
  | CompletedThinking of { text : string }
  | CompletedToolCall of Types.tool_call

type state = {
  completed_blocks : completed_block list;
      (** Blocks that have been fully received, in order. *)
  active_block : active_block option;
      (** The currently streaming block, if any. *)
  stop_reason : Types.stop_reason;
  usage : Types.usage;
  provenance : Types.provenance;
}

let default_provenance =
  {
    Types.api = "anthropic";
    provider = "Anthropic";
    model = "";
    error_message = None;
  }

let zero_usage =
  {
    Types.input_tokens = 0;
    output_tokens = 0;
    cache_read_tokens = 0;
    cache_write_tokens = 0;
    cost_usd = None;
  }

let initial_state =
  {
    completed_blocks = [];
    active_block = None;
    stop_reason = Types.EndTurn;
    usage = zero_usage;
    provenance = default_provenance;
  }

(** Build the [assistant_content list] from the current state, including any
    active block that is being streamed. This is used for partial snapshots. *)
let build_content_list state =
  let from_completed = function
    | CompletedText text -> Types.AText text
    | CompletedThinking { text } -> Types.AThinking { text; signature = None }
    | CompletedToolCall tc -> Types.AToolCall tc
  in
  let completed_content = List.map from_completed state.completed_blocks in
  let active_content =
    match state.active_block with
    | None -> []
    | Some (ActiveText { buf }) -> [ Types.AText buf ]
    | Some (ActiveThinking { buf }) ->
        [ Types.AThinking { text = buf; signature = None } ]
    | Some (ActiveToolUse { id; name; _ }) ->
        (* The tool call is in-progress; expose placeholder with empty arguments *)
        [ Types.AToolCall { id; name; arguments = `Assoc [] } ]
  in
  completed_content @ active_content

(** Build an immutable [assistant_message] snapshot from current state. *)
let snapshot state =
  {
    Types.content = build_content_list state;
    stop_reason = state.stop_reason;
    provenance = state.provenance;
    usage = state.usage;
  }

(** Parse [stop_reason] from the Anthropic string value. *)
let parse_stop_reason s =
  match s with
  | "end_turn" -> Types.EndTurn
  | "tool_use" -> Types.ToolUse
  | "max_tokens" -> Types.MaxTokens
  | "stop_sequence" -> Types.StopSequence
  (* Forward-compat: Anthropic can add stop reasons; treat unknown as a
     provider error rather than silently claiming normal completion. *)
  | other -> Types.Error (Types.Provider { message = "unknown stop_reason: " ^ other })

(** Extract an integer field from a JSON object, returning 0 if absent or not an
    integer. *)
let json_int_field fields key =
  match List.assoc_opt ~eq:String.equal key fields with
  | Some (`Int n) -> n
  | Some (`Intlit s) -> (
      match int_of_string_opt s with Some n -> n | None -> 0)
  | _ -> 0

(** Extract a string field from a JSON object, returning None if absent. *)
let json_string_field_opt fields key =
  match List.assoc_opt ~eq:String.equal key fields with
  | Some (`String s) -> Some s
  | _ -> None

(** Parse usage from an Anthropic usage JSON object. Preserves existing usage
    fields when the incoming object omits them (proxies sometimes omit
    input_tokens in message_delta). *)
let parse_usage existing fields =
  (* Check presence explicitly so we can preserve existing when absent. *)
  let field_present key =
    Option.is_some (List.assoc_opt ~eq:String.equal key fields)
  in
  let input_tokens =
    if field_present "input_tokens" then json_int_field fields "input_tokens"
    else existing.Types.input_tokens
  in
  let output_tokens =
    if field_present "output_tokens" then json_int_field fields "output_tokens"
    else existing.Types.output_tokens
  in
  let cache_read_tokens =
    if field_present "cache_read_input_tokens" then
      json_int_field fields "cache_read_input_tokens"
    else existing.Types.cache_read_tokens
  in
  let cache_write_tokens =
    if field_present "cache_creation_input_tokens" then
      json_int_field fields "cache_creation_input_tokens"
    else existing.Types.cache_write_tokens
  in
  {
    Types.input_tokens;
    output_tokens;
    cache_read_tokens;
    cache_write_tokens;
    cost_usd = None;
  }

(** Handle a [message_start] event. Initialises usage and provenance from the
    [message] sub-object. *)
let handle_message_start state json =
  let open Option.Infix in
  let result =
    let* fields = match json with `Assoc f -> Some f | _ -> None in
    let* _ =
      json_string_field_opt fields "type"
      |> Option.filter (String.equal "message_start")
    in
    let* msg_fields =
      match List.assoc_opt ~eq:String.equal "message" fields with
      | Some (`Assoc f) -> Some f
      | _ -> None
    in
    let model =
      json_string_field_opt msg_fields "model" |> Option.value ~default:""
    in
    let usage =
      match List.assoc_opt ~eq:String.equal "usage" msg_fields with
      | Some (`Assoc usage_fields) -> parse_usage state.usage usage_fields
      | _ -> state.usage
    in
    let new_state =
      { state with provenance = { state.provenance with model }; usage }
    in
    Some (new_state, [])
  in
  Option.value result ~default:(state, [])

(** Dispatch a [content_block_start] sub-event for a known block type. Returns
    [None] for unrecognised types. *)
let dispatch_block_start state index block_type block_fields =
  match block_type with
  | "text" ->
      let new_state =
        { state with active_block = Some (ActiveText { buf = "" }) }
      in
      let partial = snapshot new_state in
      Some (new_state, [ Types.AME_text_start { partial } ])
  | "thinking" ->
      let new_state =
        { state with active_block = Some (ActiveThinking { buf = "" }) }
      in
      let partial = snapshot new_state in
      Some (new_state, [ Types.AME_thinking_start { partial } ])
  | "tool_use" ->
      let id =
        json_string_field_opt block_fields "id" |> Option.value ~default:""
      in
      let name =
        json_string_field_opt block_fields "name" |> Option.value ~default:""
      in
      let new_state =
        {
          state with
          active_block = Some (ActiveToolUse { index; id; name; json_buf = "" });
        }
      in
      let partial = snapshot new_state in
      Some
        (new_state, [ Types.AME_tool_call_start { index; id; name; partial } ])
  | _ -> None

(** Handle a [content_block_start] event. Begins a new text, thinking, or
    tool_use active block. *)
let handle_content_block_start state json =
  let open Option.Infix in
  let result =
    let* fields = match json with `Assoc f -> Some f | _ -> None in
    let index =
      match List.assoc_opt ~eq:String.equal "index" fields with
      | Some (`Int n) -> n
      | _ -> 0
    in
    let* block_fields =
      match List.assoc_opt ~eq:String.equal "content_block" fields with
      | Some (`Assoc f) -> Some f
      | _ -> None
    in
    let* block_type = json_string_field_opt block_fields "type" in
    dispatch_block_start state index block_type block_fields
  in
  Option.value result ~default:(state, [])

(** Apply a text delta to the active text block. *)
let apply_text_delta state delta_fields =
  let text =
    json_string_field_opt delta_fields "text" |> Option.value ~default:""
  in
  match state.active_block with
  | Some (ActiveText { buf }) ->
      let new_buf = buf ^ text in
      let new_state =
        { state with active_block = Some (ActiveText { buf = new_buf }) }
      in
      let partial = snapshot new_state in
      Some (new_state, [ Types.AME_text_delta { text; partial } ])
  | _ -> None

(** Apply a thinking delta to the active thinking block. *)
let apply_thinking_delta state delta_fields =
  let text =
    json_string_field_opt delta_fields "thinking" |> Option.value ~default:""
  in
  match state.active_block with
  | Some (ActiveThinking { buf }) ->
      let new_buf = buf ^ text in
      let new_state =
        { state with active_block = Some (ActiveThinking { buf = new_buf }) }
      in
      let partial = snapshot new_state in
      Some (new_state, [ Types.AME_thinking_delta { text; partial } ])
  | _ -> None

(** Apply an input_json delta to the active tool-use block. *)
let apply_input_json_delta state delta_fields =
  let fragment =
    json_string_field_opt delta_fields "partial_json"
    |> Option.value ~default:""
  in
  match state.active_block with
  | Some (ActiveToolUse { index; id; name; json_buf }) ->
      let new_json_buf = json_buf ^ fragment in
      let new_state =
        {
          state with
          active_block =
            Some (ActiveToolUse { index; id; name; json_buf = new_json_buf });
        }
      in
      let partial = snapshot new_state in
      Some
        ( new_state,
          [
            Types.AME_tool_call_delta
              { index; arguments_fragment = fragment; partial };
          ] )
  | _ -> None

(** Handle a [content_block_delta] event. Appends the delta fragment to the
    active block buffer. Does NOT parse tool JSON here — accumulation only. *)
let handle_content_block_delta state json =
  let open Option.Infix in
  let result =
    let* fields = match json with `Assoc f -> Some f | _ -> None in
    let* delta_fields =
      match List.assoc_opt ~eq:String.equal "delta" fields with
      | Some (`Assoc df) -> Some df
      | _ -> None
    in
    let* delta_type = json_string_field_opt delta_fields "type" in
    match delta_type with
    | "text_delta" -> apply_text_delta state delta_fields
    | "thinking_delta" -> apply_thinking_delta state delta_fields
    | "input_json_delta" -> apply_input_json_delta state delta_fields
    (* Forward-compat: Anthropic SSE delta types are an open set.
       Unknown deltas are silently dropped; the default below is the no-op. *)
    | _ -> None
  in
  Option.value result ~default:(state, [])

(** Handle a [content_block_stop] event. Finalises the active block. For
    tool_use, calls [Json_repair.parse_streaming] on the concatenated JSON
    buffer; repair failures produce [AME_error]. *)
let handle_content_block_stop state =
  match state.active_block with
  | None -> (state, [])
  | Some (ActiveText { buf }) ->
      (* No explicit text_end event is emitted — the block is finalised into
         the completed list. *)
      let new_state =
        {
          state with
          active_block = None;
          completed_blocks = state.completed_blocks @ [ CompletedText buf ];
        }
      in
      (new_state, [])
  | Some (ActiveThinking { buf }) ->
      let new_state =
        {
          state with
          active_block = None;
          completed_blocks =
            state.completed_blocks @ [ CompletedThinking { text = buf } ];
        }
      in
      (new_state, [])
  | Some (ActiveToolUse { index; id; name; json_buf }) -> (
      let parse_result = Json_repair.parse_streaming (Some json_buf) in
      match parse_result with
      | Ok arguments ->
          let tool_call = { Types.id; name; arguments } in
          let new_state =
            {
              state with
              active_block = None;
              completed_blocks =
                state.completed_blocks @ [ CompletedToolCall tool_call ];
            }
          in
          let partial = snapshot new_state in
          (new_state, [ Types.AME_tool_call_end { index; partial } ])
      | Error msg ->
          let partial = snapshot state in
          let error_msg =
            Printf.sprintf "failed to parse tool call %s arguments: %s" name msg
          in
          (state, [ Types.AME_error { message = error_msg; partial } ]))

(** Handle a [message_delta] event. Updates stop_reason and usage. *)
let handle_message_delta state json =
  match json with
  | `Assoc fields ->
      let new_stop_reason =
        match List.assoc_opt ~eq:String.equal "delta" fields with
        | Some (`Assoc delta_fields) -> (
            match json_string_field_opt delta_fields "stop_reason" with
            | Some reason -> parse_stop_reason reason
            | None -> state.stop_reason)
        | _ -> state.stop_reason
      in
      let new_usage =
        match List.assoc_opt ~eq:String.equal "usage" fields with
        | Some (`Assoc usage_fields) -> parse_usage state.usage usage_fields
        | _ -> state.usage
      in
      let new_state =
        { state with stop_reason = new_stop_reason; usage = new_usage }
      in
      (new_state, [])
  | _ -> (state, [])

(** Handle a [message_stop] event. Emits [AME_done] with the final message. *)
let handle_message_stop state =
  let message = snapshot state in
  (state, [ Types.AME_done { message } ])

(** Parse an Anthropic SSE event data JSON payload. Returns the "type" field and
    the full parsed JSON, or None on parse failure. *)
let parse_event_data data =
  match Yojson.Safe.from_string data with
  | exception _ -> None
  | json -> (
      match json with
      | `Assoc fields -> (
          match json_string_field_opt fields "type" with
          | Some event_type -> Some (event_type, json)
          | None -> None)
      | _ -> None)

let feed state (framed : Sse_parser.framed_event) =
  (* Unknown event types silently ignored per spec — this is a legitimate
     catch-all on an open protocol type. *)
  let known_event_types =
    [
      "message_start";
      "content_block_start";
      "content_block_delta";
      "content_block_stop";
      "message_delta";
      "message_stop";
    ]
  in
  let is_known_event_type =
    List.mem ~eq:String.equal framed.event_type known_event_types
  in
  if not is_known_event_type then (state, [])
  else
    match parse_event_data framed.data with
    | None -> (state, [])
    | Some (event_type, json) -> (
        match event_type with
        | "message_start" -> handle_message_start state json
        | "content_block_start" -> handle_content_block_start state json
        | "content_block_delta" -> handle_content_block_delta state json
        | "content_block_stop" -> handle_content_block_stop state
        | "message_delta" -> handle_message_delta state json
        | "message_stop" -> handle_message_stop state
        | _ -> (state, []))
