open Containers
open Pera_types

type active_tool_call = {
  index : int;
  id : string;
  name : string;
  arguments_buf : string;
}
(** An in-progress tool call accumulated from delta fragments. *)

(** A completed content block ready to be included in the final message. *)
type completed_block =
  | CompletedText of string
  | CompletedThinking of { text : string }
  | CompletedToolCall of Types.tool_call

type state = {
  completed_blocks : completed_block list;
  active_text : string option;
  active_thinking : string option;
  active_tool_calls : active_tool_call list;
  stop_reason : Types.stop_reason;
  usage : Types.usage;
  provenance : Types.provenance;
  reasoning_field : string;
  is_done : bool;
}
(** Internal state for the OpenAI SSE interpreter.

    OpenAI's wire format streams deltas without explicit block start/stop
    events. We track up to one active text block, one active thinking block, and
    a list of active tool calls (indexed by the [index] field). *)

let default_provenance =
  {
    Types.protocol = "openai-completions";
    provider = "OpenAI";
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

let initial_state ~reasoning_field =
  {
    completed_blocks = [];
    active_text = None;
    active_thinking = None;
    active_tool_calls = [];
    stop_reason = Types.EndTurn;
    usage = zero_usage;
    provenance = default_provenance;
    reasoning_field;
    is_done = false;
  }

(** Build the [assistant_content list] from the current state, including any
    active blocks that are being streamed. *)
let build_content_list state =
  let from_completed = function
    | CompletedText text -> Types.AText text
    | CompletedThinking { text } -> Types.AThinking { text; signature = None }
    | CompletedToolCall tc -> Types.AToolCall tc
  in
  let completed = List.map from_completed state.completed_blocks in
  let active_thinking =
    match state.active_thinking with
    | None -> []
    | Some buf -> [ Types.AThinking { text = buf; signature = None } ]
  in
  let active_text =
    match state.active_text with None -> [] | Some buf -> [ Types.AText buf ]
  in
  let active_tool_to_content tc =
    Types.AToolCall { id = tc.id; name = tc.name; arguments = `Assoc [] }
  in
  let active_tools =
    state.active_tool_calls
    |> List.sort (fun a b -> Int.compare a.index b.index)
    |> List.map active_tool_to_content
  in
  completed @ active_thinking @ active_text @ active_tools

(** Build an immutable [assistant_message] snapshot from current state. *)
let snapshot state =
  {
    Types.content = build_content_list state;
    stop_reason = state.stop_reason;
    provenance = state.provenance;
    usage = state.usage;
  }

(** Extract a string field from a JSON object, returning [None] if absent.
    Non-string values (including [`Null]) are treated as absent rather than
    raising, because OpenAI streaming deltas may explicitly set optional fields
    to [null]. This matches the lenient pattern used in the Anthropic
    interpreter. *)
let json_string_field_opt fields key =
  match List.assoc_opt ~eq:String.equal key fields with
  | Some (`String s) -> Some s
  | _ -> None

(** Extract an integer field from a JSON object, returning [0] if absent or not
    an integer. *)
let json_int_field fields key =
  match List.assoc_opt ~eq:String.equal key fields with
  | Some (`Int n) -> n
  | Some (`Intlit s) -> (
      match int_of_string_opt s with Some n -> n | None -> 0)
  | _ -> 0

(** Extract the first choice object from an OpenAI completion chunk. *)
let extract_choice json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal "choices" fields with
      | Some (`List (choice :: _)) -> Some choice
      | _ -> None)
  | _ -> None

(** Extract the [finish_reason] from a choice object.

    [Some `Null] in the JSON maps to [None] here (in-stream sentinel). A missing
    field also maps to [None]. *)
let extract_finish_reason choice =
  match choice with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal "finish_reason" fields with
      | Some `Null -> None
      | Some (`String s) -> Some s
      | _ -> None)
  | _ -> None

(** Extract the [delta] object from a choice object, returning an empty field
    list if absent or not an object. *)
let extract_delta_fields choice =
  match choice with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal "delta" fields with
      | Some (`Assoc df) -> df
      | _ -> [])
  | _ -> []

(** Extract a non-empty text [content] value from delta fields. [None] means no
    content event should be emitted (absent, [null], or empty string). *)
let extract_content delta_fields =
  match List.assoc_opt ~eq:String.equal "content" delta_fields with
  | Some `Null -> None
  | Some (`String s) -> if String.is_empty s then None else Some s
  | _ -> None

(** Extract a non-empty reasoning value from delta fields using the configured
    reasoning field name. *)
let extract_reasoning state delta_fields =
  match List.assoc_opt ~eq:String.equal state.reasoning_field delta_fields with
  | Some `Null -> None
  | Some (`String s) -> if String.is_empty s then None else Some s
  | _ -> None

(** Extract the [tool_calls] array from delta fields. *)
let extract_tool_calls delta_fields =
  match List.assoc_opt ~eq:String.equal "tool_calls" delta_fields with
  | Some (`List items) -> items
  | Some `Null -> []
  | _ -> []

type tool_call_delta = {
  index : int;
  id : string option;
  name : string option;
  arguments : string option;
}
(** Parsed representation of a single item in a [tool_calls] delta array. *)

(** Parse one element of the [tool_calls] array into a [tool_call_delta]. *)
let parse_tool_call_item item =
  match item with
  | `Assoc fields ->
      let index = json_int_field fields "index" in
      let id = json_string_field_opt fields "id" in
      let func_fields =
        match List.assoc_opt ~eq:String.equal "function" fields with
        | Some (`Assoc f) -> f
        | _ -> []
      in
      let name = json_string_field_opt func_fields "name" in
      let arguments = json_string_field_opt func_fields "arguments" in
      Some { index; id; name; arguments }
  | _ -> None

(** Emit [AME_text_start] (with empty text) followed by [AME_text_delta] when
    starting a new text block, or just [AME_text_delta] when appending to an
    existing block. *)
let handle_content_delta state delta_fields =
  match extract_content delta_fields with
  | None -> (state, [])
  | Some text -> (
      match state.active_text with
      | None ->
          let state_with_empty = { state with active_text = Some "" } in
          let partial_start = snapshot state_with_empty in
          let start_event = Types.AME_text_start { partial = partial_start } in
          let state_with_text =
            { state_with_empty with active_text = Some text }
          in
          let partial_delta = snapshot state_with_text in
          let delta_event =
            Types.AME_text_delta { text; partial = partial_delta }
          in
          (state_with_text, [ start_event; delta_event ])
      | Some buf ->
          let new_text = buf ^ text in
          let state = { state with active_text = Some new_text } in
          let partial = snapshot state in
          (state, [ Types.AME_text_delta { text; partial } ]))

(** Emit [AME_thinking_start] followed by [AME_thinking_delta] on first
    reasoning fragment, or just [AME_thinking_delta] on subsequent fragments. *)
let handle_reasoning_delta state delta_fields =
  match extract_reasoning state delta_fields with
  | None -> (state, [])
  | Some text -> (
      match state.active_thinking with
      | None ->
          let state_with_empty = { state with active_thinking = Some "" } in
          let partial_start = snapshot state_with_empty in
          let start_event =
            Types.AME_thinking_start { partial = partial_start }
          in
          let state_with_text =
            { state_with_empty with active_thinking = Some text }
          in
          let partial_delta = snapshot state_with_text in
          let delta_event =
            Types.AME_thinking_delta { text; partial = partial_delta }
          in
          (state_with_text, [ start_event; delta_event ])
      | Some buf ->
          let new_text = buf ^ text in
          let state = { state with active_thinking = Some new_text } in
          let partial = snapshot state in
          (state, [ Types.AME_thinking_delta { text; partial } ]))

(** Handle a single tool-call delta item.

    Creates a new active tool call (and emits [AME_tool_call_start]) when the
    index is first seen. Appends arguments and emits [AME_tool_call_delta] on
    subsequent deltas for the same index. *)
let handle_tool_call_delta state (delta : tool_call_delta) =
  let target_index = delta.index in
  let existing =
    List.find_opt
      (fun (tc : active_tool_call) -> Int.equal tc.index target_index)
      state.active_tool_calls
  in
  match existing with
  | None ->
      let id = Option.value delta.id ~default:"" in
      let name = Option.value delta.name ~default:"" in
      let args = Option.value delta.arguments ~default:"" in
      let tc = { index = target_index; id; name; arguments_buf = "" } in
      let state =
        { state with active_tool_calls = tc :: state.active_tool_calls }
      in
      let partial = snapshot state in
      let start_event =
        Types.AME_tool_call_start { index = target_index; id; name; partial }
      in
      if String.is_empty args then (state, [ start_event ])
      else
        let tc_with_args = { tc with arguments_buf = args } in
        let active_tool_calls =
          List.map
            (fun (t : active_tool_call) ->
              if Int.equal t.index target_index then tc_with_args else t)
            state.active_tool_calls
        in
        let state = { state with active_tool_calls } in
        let partial = snapshot state in
        let delta_event =
          Types.AME_tool_call_delta
            { index = target_index; arguments_fragment = args; partial }
        in
        (state, [ start_event; delta_event ])
  | Some tc ->
      let args = Option.value delta.arguments ~default:"" in
      if String.is_empty args then (state, [])
      else
        let new_tc = { tc with arguments_buf = tc.arguments_buf ^ args } in
        let active_tool_calls =
          List.map
            (fun (t : active_tool_call) ->
              if Int.equal t.index target_index then new_tc else t)
            state.active_tool_calls
        in
        let state = { state with active_tool_calls } in
        let partial = snapshot state in
        ( state,
          [
            Types.AME_tool_call_delta
              { index = target_index; arguments_fragment = args; partial };
          ] )

(** Fold helper that processes one tool-call item and accumulates state +
    events. *)
let fold_tool_call_item (st, evs) item =
  match parse_tool_call_item item with
  | None -> (st, evs)
  | Some delta ->
      let st', evs' = handle_tool_call_delta st delta in
      (st', evs @ evs')

(** Finalise the active text block into the completed list. *)
let finalize_text state =
  match state.active_text with
  | None -> (state, [])
  | Some buf ->
      ( {
          state with
          active_text = None;
          completed_blocks = state.completed_blocks @ [ CompletedText buf ];
        },
        [] )

(** Finalise the active thinking block into the completed list. *)
let finalize_thinking state =
  match state.active_thinking with
  | None -> (state, [])
  | Some buf ->
      ( {
          state with
          active_thinking = None;
          completed_blocks =
            state.completed_blocks @ [ CompletedThinking { text = buf } ];
        },
        [] )

(** Parse a finish-reason string into the internal [stop_reason] variant.

    Forward-compat: unknown finish reasons are mapped to [Error] rather than
    silently defaulting to [EndTurn]. *)
let parse_finish_reason = function
  | "stop" -> Types.EndTurn
  | "tool_calls" -> Types.ToolUse
  | "length" -> Types.MaxTokens
  | "content_filter" ->
      Types.Error (Types.Provider { message = "finish_reason content_filter" })
  | other ->
      Types.Error
        (Types.Provider { message = "unknown finish_reason: " ^ other })

(** Finalise a single active tool call, parsing its accumulated JSON arguments.

    On success the tool call is appended to [completed_blocks] and
    [AME_tool_call_end] is emitted. On failure [AME_error] is emitted and the
    tool call is discarded from the active set. *)
let finalize_single_tool_call state tc =
  match Json_repair.parse_streaming (Some tc.arguments_buf) with
  | Ok arguments ->
      let tool_call = { Types.id = tc.id; name = tc.name; arguments } in
      let state =
        {
          state with
          completed_blocks =
            state.completed_blocks @ [ CompletedToolCall tool_call ];
        }
      in
      let partial = snapshot state in
      (state, [ Types.AME_tool_call_end { index = tc.index; partial } ])
  | Error msg ->
      let partial = snapshot state in
      let error_msg =
        Printf.sprintf "failed to parse tool call %s arguments: %s" tc.name msg
      in
      (state, [ Types.AME_error { message = error_msg; partial } ])

(** Finalise all active tool calls in index order. *)
let finalize_tool_calls state =
  let sorted =
    List.sort
      (fun (a : active_tool_call) (b : active_tool_call) ->
        Int.compare a.index b.index)
      state.active_tool_calls
  in
  let fold_finalize_tool_call (st, evs) tc =
    let st', evs' = finalize_single_tool_call st tc in
    (st', evs @ evs')
  in
  let state, events =
    List.fold_left fold_finalize_tool_call (state, []) sorted
  in
  ({ state with active_tool_calls = [] }, events)

(** Extract usage from the top-level chunk JSON when
    [stream_options.include_usage] is true. Usage appears only on the final
    chunk.

    Cache-read tokens follow the OpenAI shape
    ([usage.prompt_tokens_details.cached_tokens]) which is also used by Kimi
    (Moonshot), GLM (Zhipu), and Ollama Cloud. Providers that use a different
    field (e.g. DeepSeek's [prompt_cache_hit_tokens]) are not covered here. *)
let extract_usage json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt ~eq:String.equal "usage" fields with
      | Some (`Assoc u) ->
          let input_tokens = json_int_field u "prompt_tokens" in
          let output_tokens = json_int_field u "completion_tokens" in
          let cache_read_tokens =
            match List.assoc_opt ~eq:String.equal "prompt_tokens_details" u with
            | Some (`Assoc details) -> json_int_field details "cached_tokens"
            | _ -> 0
          in
          let cost_usd =
            match List.assoc_opt ~eq:String.equal "cost" u with
            | Some (`Float f) ->
                Some (Decimal.of_string (Printf.sprintf "%g" f))
            | Some (`Int n) -> Some (Decimal.of_string (string_of_int n))
            | _ -> None
          in
          Some
            {
              Types.input_tokens;
              output_tokens;
              cache_read_tokens;
              cache_write_tokens = 0;
              cost_usd;
            }
      | _ -> None)
  | _ -> None

(** Handle a non-null [finish_reason] by finalising all active blocks and
    emitting [AME_done]. *)
let handle_finish_reason state reason_str =
  let stop_reason = parse_finish_reason reason_str in
  let state = { state with stop_reason } in
  let state, _ = finalize_thinking state in
  let state, _ = finalize_text state in
  let state, tool_events = finalize_tool_calls state in
  let message = snapshot state in
  ({ state with is_done = true }, tool_events @ [ Types.AME_done { message } ])

(** Handle the [[DONE]] sentinel by finalising all active blocks and emitting
    [AME_done]. *)
let handle_done state =
  let state, _ = finalize_thinking state in
  let state, _ = finalize_text state in
  let state, tool_events = finalize_tool_calls state in
  let message = snapshot state in
  ({ state with is_done = true }, tool_events @ [ Types.AME_done { message } ])

let feed state (framed : Sse_parser.framed_event) =
  if state.is_done then (state, [])
  else if String.equal framed.data "[DONE]" then handle_done state
  else if String.is_empty framed.data then (state, [])
  else
    match Yojson.Safe.from_string framed.data with
    | exception _ ->
        (* Non-JSON data field: likely a server-specific control frame or
           keepalive. Skip it rather than terminating the stream. *)
        (state, [])
    | json -> (
        let state =
          match extract_usage json with
          | Some u -> { state with usage = u }
          | None -> state
        in
        match extract_choice json with
        | None -> (state, [])
        | Some choice ->
            let delta_fields = extract_delta_fields choice in
            let finish_reason = extract_finish_reason choice in
            let state, content_events =
              handle_content_delta state delta_fields
            in
            let state, reasoning_events =
              handle_reasoning_delta state delta_fields
            in
            let tool_items = extract_tool_calls delta_fields in
            let state, tool_events =
              List.fold_left fold_tool_call_item (state, []) tool_items
            in
            let state, finish_events =
              match finish_reason with
              | Some r -> handle_finish_reason state r
              | None -> (state, [])
            in
            ( state,
              content_events @ reasoning_events @ tool_events @ finish_events ))
