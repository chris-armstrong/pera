open Containers

type synthetic = |

type agent_message =
  | Real of Pera_provider.Provider.message
  | Synthetic of synthetic

type tool_output = Tool_text of string | Tool_json of Yojson.Safe.t

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
  | AE_agent_end of { messages : agent_message list }
  | AE_turn_start
  | AE_turn_end of {
      message : agent_message;
      tool_results : Pera_types.Types.tool_result_content list;
    }
  | AE_message_start of { message : agent_message }
  | AE_message_update of {
      message : agent_message;
      event : Pera_types.Types.assistant_message_event;
    }
  | AE_message_end of { message : agent_message }
  | AE_tool_execution_start of {
      tool_call_id : string;
      tool_name : string;
      args : Yojson.Safe.t;
    }
  | AE_tool_execution_update of {
      tool_call_id : string;
      tool_name : string;
      partial : Yojson.Safe.t;
    }
  | AE_tool_execution_end of {
      tool_call_id : string;
      tool_name : string;
      result : Yojson.Safe.t;
      is_error : bool;
    }

type before_tool_call_result = Allow | Deny of string

type turn_update = {
  messages : agent_message list option;
  model : Pera_types.Types.model option;
  thinking : bool option;
}

let tool_output_to_result_content ~tool_call_id ~is_error output =
  let content =
    match output with Tool_text s -> `String s | Tool_json j -> j
  in
  Pera_types.Types.{ tool_call_id; content; is_error }

(** Compare two [agent_message] values by serialising to JSON and comparing the
    result. The [Synthetic] case is uninhabited so only the [Real] arm is
    needed. *)
let agent_message_equal m1 m2 =
  match (m1, m2) with
  | Real msg1, Real msg2 ->
      List.equal Yojson.Safe.equal
        (Pera_provider.Anthropic_request.messages_to_json [ msg1 ])
        (Pera_provider.Anthropic_request.messages_to_json [ msg2 ])

(** Compare two [tool_result_content] values for structural equality, using
    [Yojson.Safe.equal] for the [content] field. *)
let tool_result_content_equal (t1 : Pera_types.Types.tool_result_content)
    (t2 : Pera_types.Types.tool_result_content) =
  String.equal t1.tool_call_id t2.tool_call_id
  && Yojson.Safe.equal t1.content t2.content
  && Bool.equal t1.is_error t2.is_error

(** Compare two [assistant_message] values by comparing each field using
    type-specific equality functions. *)
let rec assistant_message_equal (m1 : Pera_types.Types.assistant_message)
    (m2 : Pera_types.Types.assistant_message) =
  List.equal assistant_content_equal m1.content m2.content
  && stop_reason_equal m1.stop_reason m2.stop_reason
  && provenance_equal m1.provenance m2.provenance
  && usage_equal m1.usage m2.usage

and assistant_content_equal (c1 : Pera_types.Types.assistant_content)
    (c2 : Pera_types.Types.assistant_content) =
  match (c1, c2) with
  | Pera_types.Types.AText s1, Pera_types.Types.AText s2 -> String.equal s1 s2
  | ( Pera_types.Types.AThinking { text = t1; signature = sg1 },
      Pera_types.Types.AThinking { text = t2; signature = sg2 } ) ->
      String.equal t1 t2 && Option.equal String.equal sg1 sg2
  | Pera_types.Types.AToolCall tc1, Pera_types.Types.AToolCall tc2 ->
      String.equal tc1.id tc2.id
      && String.equal tc1.name tc2.name
      && Yojson.Safe.equal tc1.arguments tc2.arguments
  | _, _ -> false

and stop_reason_equal (r1 : Pera_types.Types.stop_reason)
    (r2 : Pera_types.Types.stop_reason) =
  match (r1, r2) with
  | EndTurn, EndTurn -> true
  | ToolUse, ToolUse -> true
  | MaxTokens, MaxTokens -> true
  | StopSequence, StopSequence -> true
  | Error, Error -> true
  | Aborted, Aborted -> true
  | _, _ -> false

and provenance_equal (p1 : Pera_types.Types.provenance)
    (p2 : Pera_types.Types.provenance) =
  String.equal p1.api p2.api
  && String.equal p1.provider p2.provider
  && String.equal p1.model p2.model
  && Option.equal String.equal p1.error_message p2.error_message

and usage_equal (u1 : Pera_types.Types.usage) (u2 : Pera_types.Types.usage) =
  Int.equal u1.input_tokens u2.input_tokens
  && Int.equal u1.output_tokens u2.output_tokens
  && Int.equal u1.cache_read_tokens u2.cache_read_tokens
  && Int.equal u1.cache_write_tokens u2.cache_write_tokens
  && Option.equal Float.equal u1.cost_usd u2.cost_usd

(** Compare two [assistant_message_event] values for structural equality, using
    type-specific equality for all fields. *)
let assistant_message_event_equal
    (e1 : Pera_types.Types.assistant_message_event)
    (e2 : Pera_types.Types.assistant_message_event) =
  match (e1, e2) with
  | ( Pera_types.Types.AME_text_start { partial = p1 },
      Pera_types.Types.AME_text_start { partial = p2 } ) ->
      assistant_message_equal p1 p2
  | ( Pera_types.Types.AME_text_delta { text = t1; partial = p1 },
      Pera_types.Types.AME_text_delta { text = t2; partial = p2 } ) ->
      String.equal t1 t2 && assistant_message_equal p1 p2
  | ( Pera_types.Types.AME_thinking_start { partial = p1 },
      Pera_types.Types.AME_thinking_start { partial = p2 } ) ->
      assistant_message_equal p1 p2
  | ( Pera_types.Types.AME_thinking_delta { text = t1; partial = p1 },
      Pera_types.Types.AME_thinking_delta { text = t2; partial = p2 } ) ->
      String.equal t1 t2 && assistant_message_equal p1 p2
  | ( Pera_types.Types.AME_tool_call_start
        { index = i1; id = id1; name = n1; partial = p1 },
      Pera_types.Types.AME_tool_call_start
        { index = i2; id = id2; name = n2; partial = p2 } ) ->
      Int.equal i1 i2 && String.equal id1 id2 && String.equal n1 n2
      && assistant_message_equal p1 p2
  | ( Pera_types.Types.AME_tool_call_delta
        { index = i1; arguments_fragment = af1; partial = p1 },
      Pera_types.Types.AME_tool_call_delta
        { index = i2; arguments_fragment = af2; partial = p2 } ) ->
      Int.equal i1 i2 && String.equal af1 af2 && assistant_message_equal p1 p2
  | ( Pera_types.Types.AME_tool_call_end { index = i1; partial = p1 },
      Pera_types.Types.AME_tool_call_end { index = i2; partial = p2 } ) ->
      Int.equal i1 i2 && assistant_message_equal p1 p2
  | ( Pera_types.Types.AME_done { message = m1 },
      Pera_types.Types.AME_done { message = m2 } ) ->
      assistant_message_equal m1 m2
  | ( Pera_types.Types.AME_error { message = msg1; partial = p1 },
      Pera_types.Types.AME_error { message = msg2; partial = p2 } ) ->
      String.equal msg1 msg2 && assistant_message_equal p1 p2
  | _, _ -> false

let agent_event_equal e1 e2 =
  match (e1, e2) with
  | AE_agent_start, AE_agent_start -> true
  | AE_agent_start, _ -> false
  | AE_agent_end { messages = ms1 }, AE_agent_end { messages = ms2 } ->
      List.equal agent_message_equal ms1 ms2
  | AE_agent_end _, _ -> false
  | AE_turn_start, AE_turn_start -> true
  | AE_turn_start, _ -> false
  | ( AE_turn_end { message = msg1; tool_results = tr1 },
      AE_turn_end { message = msg2; tool_results = tr2 } ) ->
      agent_message_equal msg1 msg2
      && List.equal tool_result_content_equal tr1 tr2
  | AE_turn_end _, _ -> false
  | AE_message_start { message = m1 }, AE_message_start { message = m2 } ->
      agent_message_equal m1 m2
  | AE_message_start _, _ -> false
  | ( AE_message_update { message = m1; event = e1 },
      AE_message_update { message = m2; event = e2 } ) ->
      agent_message_equal m1 m2 && assistant_message_event_equal e1 e2
  | AE_message_update _, _ -> false
  | AE_message_end { message = m1 }, AE_message_end { message = m2 } ->
      agent_message_equal m1 m2
  | AE_message_end _, _ -> false
  | ( AE_tool_execution_start { tool_call_id = id1; tool_name = n1; args = a1 },
      AE_tool_execution_start { tool_call_id = id2; tool_name = n2; args = a2 }
    ) ->
      String.equal id1 id2 && String.equal n1 n2 && Yojson.Safe.equal a1 a2
  | AE_tool_execution_start _, _ -> false
  | ( AE_tool_execution_update
        { tool_call_id = id1; tool_name = n1; partial = p1 },
      AE_tool_execution_update
        { tool_call_id = id2; tool_name = n2; partial = p2 } ) ->
      String.equal id1 id2 && String.equal n1 n2 && Yojson.Safe.equal p1 p2
  | AE_tool_execution_update _, _ -> false
  | ( AE_tool_execution_end
        { tool_call_id = id1; tool_name = n1; result = r1; is_error = ie1 },
      AE_tool_execution_end
        { tool_call_id = id2; tool_name = n2; result = r2; is_error = ie2 } ) ->
      String.equal id1 id2 && String.equal n1 n2 && Yojson.Safe.equal r1 r2
      && Bool.equal ie1 ie2
  | AE_tool_execution_end _, _ -> false

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

let agent_event_testable = Alcotest.testable pp_agent_event agent_event_equal
