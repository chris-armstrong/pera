open Containers

type synthetic = Compaction_summary of { summary : string } [@@deriving eq, show]

type agent_message =
  | Real of Pera_provider.Provider.message
  | Synthetic of synthetic

let compaction_framing = "Context from earlier conversation:\n\n"

let synthetic_to_message = function
  | Compaction_summary { summary } ->
      Pera_provider.Provider.UserMessage
        Pera_types.Types.
          { role = "user"; content = [ UText (compaction_framing ^ summary) ] }

let to_provider_message = function
  | Real m -> m
  | Synthetic s -> synthetic_to_message s

(** Compare two [agent_message] values for structural equality. *)
let agent_message_equal m1 m2 =
  match (m1, m2) with
  | Real a, Real b -> Pera_provider.Provider.equal_message a b
  | Synthetic a, Synthetic b -> equal_synthetic a b
  | Real _, Synthetic _ | Synthetic _, Real _ -> false

let pp_agent_message ppf = function
  | Real msg ->
      Format.fprintf ppf "Real(%s)" (Pera_provider.Provider.show_message msg)
  | Synthetic s -> Format.fprintf ppf "Synthetic(%s)" (show_synthetic s)

type tool_output =
  | Tool_text of string
  | Tool_json of
      (Yojson.Safe.t
      [@equal Yojson.Safe.equal]
      [@printer
        fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)])
[@@deriving eq, show]

(** Opaque tool constructor and accessors. *)
module Tool = struct
  type 'ctx t = {
    name : string;
    description : string;
    schema : Pera_provider.Json_schema.t;
    parallel_safe : bool;
    execute :
      ctx:'ctx ->
      args:Yojson.Safe.t ->
      sw:Eio.Switch.t ->
      cancel:Eio.Cancel.t ->
      (tool_output, Pera_types.Types.tool_error) result;
  }

  let create ~name ~description ~schema ~parallel_safe ~execute =
    {
      name;
      description;
      schema;
      parallel_safe;
      execute;
    }

  let name t = t.name
  let description t = t.description
  let schema t = t.schema
  let parallel_safe t = t.parallel_safe
  let execute t ~ctx ~args ~sw ~cancel = t.execute ~ctx ~args ~sw ~cancel
end

(** Backwards-compatible alias. *)
type 'ctx tool = 'ctx Tool.t

type agent_event =
  | AE_agent_start
  | AE_agent_end of {
      messages :
        (agent_message list
        [@equal List.equal agent_message_equal]
        [@printer
          fun fmt ms -> Format.fprintf fmt "[%d messages]" (List.length ms)]);
    }
  | AE_turn_start
  | AE_turn_end of {
      message :
        (agent_message[@equal agent_message_equal] [@printer pp_agent_message]);
      tool_results : Pera_types.Types.tool_result_content list;
    }
  | AE_message_start of {
      message :
        (agent_message[@equal agent_message_equal] [@printer pp_agent_message]);
    }
  | AE_message_update of {
      message :
        (agent_message[@equal agent_message_equal] [@printer pp_agent_message]);
      event : Pera_types.Types.assistant_message_event;
    }
  | AE_message_end of {
      message :
        (agent_message[@equal agent_message_equal] [@printer pp_agent_message]);
    }
  | AE_tool_execution_start of {
      tool_call_id : string;
      tool_name : string;
      args :
        (Yojson.Safe.t
        [@equal Yojson.Safe.equal]
        [@printer
          fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)]);
    }
  | AE_tool_execution_update of {
      tool_call_id : string;
      tool_name : string;
      partial :
        (Yojson.Safe.t
        [@equal Yojson.Safe.equal]
        [@printer
          fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)]);
    }
  | AE_tool_execution_end of {
      tool_call_id : string;
      tool_name : string;
      result :
        (Yojson.Safe.t
        [@equal Yojson.Safe.equal]
        [@printer
          fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)]);
      is_error : bool;
    }
  | AE_compaction_start
  | AE_compaction_end of { summary : string }
  | AE_compaction_error of { message : string }
[@@deriving eq, show]

type before_tool_call_result = Allow | Deny of string [@@deriving eq, show]

type turn_update = {
  messages :
    (agent_message list option
    [@equal Option.equal (List.equal agent_message_equal)]
    [@printer
      fun fmt ms ->
        match ms with
        | None -> Format.pp_print_string fmt "None"
        | Some msgs ->
            Format.fprintf fmt "Some [%d messages]" (List.length msgs)]);
  model : Pera_types.Types.model option;
  thinking : bool option;
}
[@@deriving eq, show]

type stream_fn =
  model:Pera_types.Types.model ->
  context:Pera_provider.Provider.context ->
  options:Pera_provider.Provider.simple_stream_options ->
  sw:Eio.Switch.t ->
  ( Pera_types.Types.assistant_message_event,
    Pera_types.Types.assistant_message )
  Pera_provider.Event_stream.t

let tool_output_to_result_content ~tool_call_id ~is_error output =
  let content =
    match output with Tool_text s -> `String s | Tool_json j -> j
  in
  Pera_types.Types.{ tool_call_id; content; is_error }

let pp_assistant_message_event_kind ppf event =
  match event with
  | Pera_types.Types.AME_text_start _ -> Format.pp_print_string ppf "text_start"
  | Pera_types.Types.AME_text_delta { text; _ } ->
      Format.fprintf ppf "text_delta(text=%s)" text
  | Pera_types.Types.AME_thinking_start _ ->
      Format.pp_print_string ppf "thinking_start"
  | Pera_types.Types.AME_thinking_delta { text; _ } ->
      Format.fprintf ppf "thinking_delta(text=%s)" text
  | Pera_types.Types.AME_tool_call_start { name; id; _ } ->
      Format.fprintf ppf "tool_call_start(name=%s, id=%s)" name id
  | Pera_types.Types.AME_tool_call_delta { index; _ } ->
      Format.fprintf ppf "tool_call_delta(idx=%d)" index
  | Pera_types.Types.AME_tool_call_end { index; _ } ->
      Format.fprintf ppf "tool_call_end(idx=%d)" index
  | Pera_types.Types.AME_done _ -> Format.pp_print_string ppf "done"
  | Pera_types.Types.AME_error { message; _ } ->
      Format.fprintf ppf "error(%s)" message

let pp_agent_event ppf event =
  match event with
  | AE_agent_start -> Format.pp_print_string ppf "[AE_agent_start]"
  | AE_agent_end { messages } ->
      Format.fprintf ppf "[AE_agent_end] messages=%d" (List.length messages)
  | AE_turn_start -> Format.pp_print_string ppf "[AE_turn_start]"
  | AE_turn_end { message = _; tool_results } ->
      Format.fprintf ppf "[AE_turn_end] tool_results=%d"
        (List.length tool_results)
  | AE_message_start _ -> Format.pp_print_string ppf "[AE_message_start]"
  | AE_message_update { message = _; event } ->
      Format.fprintf ppf "[AE_message_update] %a"
        pp_assistant_message_event_kind event
  | AE_message_end _ -> Format.pp_print_string ppf "[AE_message_end]"
  | AE_tool_execution_start { tool_call_id; tool_name; _ } ->
      Format.fprintf ppf "[AE_tool_execution_start] id=%s name=%s" tool_call_id
        tool_name
  | AE_tool_execution_update { tool_call_id; tool_name; _ } ->
      Format.fprintf ppf "[AE_tool_execution_update] id=%s name=%s" tool_call_id
        tool_name
  | AE_tool_execution_end { tool_call_id; tool_name; is_error; _ } ->
      Format.fprintf ppf "[AE_tool_execution_end] id=%s name=%s is_error=%b"
        tool_call_id tool_name is_error
  | AE_compaction_start -> Format.pp_print_string ppf "[AE_compaction_start]"
  | AE_compaction_end { summary } ->
      Format.fprintf ppf "[AE_compaction_end] summary_len=%d"
        (String.length summary)
  | AE_compaction_error { message } ->
      Format.fprintf ppf "[AE_compaction_error] %s" message

(** Re-shadow the ppx-generated [show_agent_event] so it delegates to the
    hand-written [pp_agent_event] above rather than the derived OCaml-syntax
    printer that [@@deriving show] closed over at generation time. *)
let show_agent_event e = Format.asprintf "%a" pp_agent_event e
