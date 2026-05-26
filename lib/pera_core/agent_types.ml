open Containers

type synthetic = |

type agent_message =
  | Real of Pera_provider.Provider.message
  | Synthetic of synthetic

(** Compare two [agent_message] values for structural equality. The [Synthetic]
    case is uninhabited so only the [Real] arm is needed. *)
let agent_message_equal m1 m2 =
  match (m1, m2) with
  | Real msg1, Real msg2 -> Pera_provider.Provider.equal_message msg1 msg2

let pp_agent_message ppf = function
  | Real msg ->
      Format.fprintf ppf "Real(%s)" (Pera_provider.Provider.show_message msg)

type tool_output =
  | Tool_text of string
  | Tool_json of
      (Yojson.Safe.t
      [@equal Yojson.Safe.equal]
      [@printer
        fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)])
[@@deriving eq, show]

type 'ctx tool = {
  name : string;
  description : string;
  schema : Pera_provider.Json_schema.t;
  mode : [ `Sequential | `Parallel ];
  execute :
    ctx:'ctx ->
    args:Yojson.Safe.t ->
    sw:Eio.Switch.t ->
    cancel:Eio.Cancel.t ->
    (tool_output, Pera_types.Types.tool_error) result;
}

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

let pp_agent_event ppf event =
  match event with
  | AE_agent_start -> Format.fprintf ppf "AE_agent_start"
  | AE_agent_end { messages } ->
      Format.fprintf ppf "AE_agent_end {messages=[%d]}" (List.length messages)
  | AE_turn_start -> Format.fprintf ppf "AE_turn_start"
  | AE_turn_end { message = _; tool_results } ->
      Format.fprintf ppf "AE_turn_end {tool_results=[%d]}"
        (List.length tool_results)
  | AE_message_start _ -> Format.fprintf ppf "AE_message_start"
  | AE_message_update _ -> Format.fprintf ppf "AE_message_update"
  | AE_message_end _ -> Format.fprintf ppf "AE_message_end"
  | AE_tool_execution_start { tool_call_id; tool_name; _ } ->
      Format.fprintf ppf "AE_tool_execution_start {id=%s; name=%s}" tool_call_id
        tool_name
  | AE_tool_execution_update { tool_call_id; tool_name; _ } ->
      Format.fprintf ppf "AE_tool_execution_update {id=%s; name=%s}"
        tool_call_id tool_name
  | AE_tool_execution_end { tool_call_id; tool_name; is_error; _ } ->
      Format.fprintf ppf "AE_tool_execution_end {id=%s; name=%s; is_error=%b}"
        tool_call_id tool_name is_error

let agent_event_testable = Alcotest.testable pp_agent_event equal_agent_event
