(** Shared test helpers for [pera_core] agent loop tests.

    These helpers are used by [agent_loop_test], [agent_loop_tools_test], and
    [agent_loop_cancel_test]. They are not part of the public library API. *)

(** {1 Message builders} *)

val make_assistant_message :
  ?stop_reason:Pera_types.Types.stop_reason ->
  Pera_types.Types.assistant_content list ->
  Pera_types.Types.assistant_message
(** [make_assistant_message ?stop_reason content] builds a minimal
    [assistant_message] with the given content blocks and stop_reason. The
    provenance and usage fields are filled with faux sentinel values. *)

val make_text_assistant_message : string -> Pera_types.Types.assistant_message
(** [make_text_assistant_message text] builds an [assistant_message] with a
    single [AText] block and [EndTurn] stop_reason. Convenience wrapper over
    [make_assistant_message]. *)

val make_tool_use_assistant_message :
  Pera_types.Types.tool_call list -> Pera_types.Types.assistant_message
(** [make_tool_use_assistant_message tool_calls] builds an [assistant_message]
    wrapping the given tool calls with [ToolUse] stop_reason. *)

val make_tool_call :
  string -> string -> Yojson.Safe.t -> Pera_types.Types.tool_call
(** [make_tool_call id name arguments] builds a [tool_call] record. *)

val make_user_agent_message : string -> Pera_core.Agent_types.agent_message
(** [make_user_agent_message text] builds an [agent_message] wrapping a
    [UserMessage] with a single [UText] block. *)

(** {1 Config defaults} *)

val default_convert_to_llm :
  Pera_core.Agent_types.agent_message list ->
  Pera_connector.Connector.message list
(** [default_convert_to_llm msgs] unwraps [Real] messages and drops [Synthetic]
    ones. Used as the default [convert_to_llm] in test configs. *)

val test_model : Pera_types.Types.model
(** A model value for loop calls. *)

val test_options : Pera_connector.Connector.simple_stream_options
(** Simple stream options for loop calls. *)

(** {1 Script builders} *)

val make_text_turn_script : string -> Pera_core_test_util.Faux_provider.script
(** [make_text_turn_script text] builds a [Faux_provider] script for a text-only
    turn that emits a [AME_text_start] and [AME_text_delta] event before
    resolving with a final message containing [text]. *)

val make_tool_use_turn_script :
  Pera_types.Types.tool_call list -> Pera_core_test_util.Faux_provider.script
(** [make_tool_use_turn_script tool_calls] builds a [Faux_provider] script for a
    turn that issues the given tool calls. Raises if [tool_calls] is empty. *)

(** {1 Schema values} *)

val empty_schema : Pera_connector.Json_schema.t
(** A tool schema with no properties and no required fields. *)

val int_field_schema : Pera_connector.Json_schema.t
(** A tool schema requiring a field named ["x"] of type integer. *)

(** {1 Event stream helpers} *)

val collect_agent_events :
  ( Pera_core.Agent_types.agent_event,
    Pera_core.Agent_types.agent_message list )
  Pera_connector.Event_stream.t ->
  Pera_core.Agent_types.agent_event list
  * ( Pera_core.Agent_types.agent_message list,
      string * Pera_types.Types.stop_error )
      result
(** [collect_agent_events stream] drains an [Event_stream] of [agent_event]
    values into a list and returns [(events, result)] where [result] is the
    final stream result returned by [Event_stream.iter]. *)

val count_events : ('a -> bool) -> 'a list -> int
(** [count_events pred events] returns the number of events satisfying [pred].
*)

(** {1 Ordering assertions} *)

val check_before :
  message:('a -> bool) ->
  before:('a -> bool) ->
  events:'a list ->
  string ->
  unit
(** [check_before ~message ~before ~events label] asserts that the first index
    in [events] matching [message] is strictly less than the first index
    matching [before]. Calls [Alcotest.fail] with a descriptive message if the
    assertion does not hold. *)

val check_event_order : (string * ('a -> bool)) list -> 'a list -> unit
(** [check_event_order labeled_preds events] asserts that the events matching
    each predicate in [labeled_preds] appear in the given order. Each element is
    [(label, predicate)]. Calls [Alcotest.fail] on the first out-of-order pair.
*)
