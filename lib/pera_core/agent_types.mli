(** Agent-core data model types for Pera.

    This module defines the vocabulary the agent loop is written against: agent
    messages (a superset of provider messages), agent events, the tool type,
    tool output, and hook result types.

    All types are pure — no loop logic or IO. *)

(** {1 Agent messages} *)

(** Uninhabited sum for forward-compatibility. New synthetic kinds (e.g.
    compaction summaries) will be added as constructors here at M6. *)
type synthetic = |

(** Agent-level message: a real provider message, or a synthetic one. The
    [Synthetic] case is uninhabited in v1; pattern-matching on it can use the
    refutation syntax [| Synthetic s -> .] *)
type agent_message =
  | Real of Pera_provider.Provider.message
      (** A real provider message (user, assistant, or tool result). *)
  | Synthetic of synthetic  (** A synthetic message kind; uninhabited in v1. *)

(** {1 Tool types} *)

(** The output produced by a tool execution. *)
type tool_output =
  | Tool_text of string  (** Plain-text tool output. *)
  | Tool_json of Yojson.Safe.t  (** Structured JSON tool output. *)

type 'ctx tool = {
  name : string;  (** Tool name as presented to the model. *)
  description : string;  (** Short description of what the tool does. *)
  schema : Pera_provider.Json_schema.t;
      (** JSON schema for the tool's arguments; used for pre-call validation. *)
  mode : [ `Sequential | `Parallel ];
      (** Default execution mode for this tool. If any called tool is
          [`Sequential], the whole batch runs sequentially. *)
  execute :
    ctx:'ctx ->
    args:Yojson.Safe.t ->
    sw:Eio.Switch.t ->
    cancel:Eio.Cancel.t ->
    (tool_output, Pera_types.Types.tool_error) result;
      (** Execute the tool. Returns [Ok output] on success or [Error tool_error]
          on failure. Must not raise on expected failures; exceptions from
          [execute] are caught by the loop and converted to error tool results.
      *)
}
(** A tool that the agent loop can invoke.

    The ['ctx] parameter is the context type supplied by the caller; it is
    passed unchanged to {!field-execute}. *)

(** {1 Agent events} *)

(** Events emitted by the agent loop during a run.

    These are the agent-level equivalents of
    {!Pera_types.Types.assistant_message_event}, supplemented with loop
    lifecycle and tool-execution events. *)
type agent_event =
  | AE_agent_start
      (** The agent run has begun. Emitted once at the start of
          [Agent_loop.run]. *)
  | AE_agent_end of { messages : agent_message list }
      (** The agent run has finished. [messages] is the final conversation
          history. *)
  | AE_turn_start  (** A new turn (LLM call) is beginning. *)
  | AE_turn_end of {
      message : agent_message;
      tool_results : Pera_types.Types.tool_result_content list;
    }
      (** A turn has ended. [message] is the assistant message; [tool_results]
          are the results of any tool calls made in this turn (empty for
          text-only turns). *)
  | AE_message_start of { message : agent_message }
      (** The provider has started emitting an assistant message. *)
  | AE_message_update of {
      message : agent_message;
      event : Pera_types.Types.assistant_message_event;
    }  (** The assistant message has been updated with a streaming event. *)
  | AE_message_end of { message : agent_message }
      (** The provider has finished emitting the assistant message. *)
  | AE_tool_execution_start of {
      tool_call_id : string;
      tool_name : string;
      args : Yojson.Safe.t;
    }  (** A tool execution has begun. *)
  | AE_tool_execution_update of {
      tool_call_id : string;
      tool_name : string;
      partial : Yojson.Safe.t;
    }  (** A partial update from a long-running tool execution. *)
  | AE_tool_execution_end of {
      tool_call_id : string;
      tool_name : string;
      result : Yojson.Safe.t;
      is_error : bool;
    }
      (** A tool execution has completed. [is_error] is [true] when the tool
          returned an error or raised an exception. *)

(** {1 Hook result types} *)

(** Result returned by the [before_tool_call] hook. *)
type before_tool_call_result =
  | Allow  (** Allow the tool call to proceed. *)
  | Deny of string
      (** Deny the tool call with the given message; the message is surfaced to
          the model as an error tool result. *)

type turn_update = {
  messages : agent_message list option;
      (** Replace the current message history; [None] to keep it. *)
  model : Pera_types.Types.model option;
      (** Switch to a different model for the next turn; [None] to keep the
          current model. *)
  thinking : bool option;
      (** Enable or disable extended thinking; [None] to keep the current
          setting. *)
}
(** A requested update to the turn state, returned by the [prepare_next_turn]
    hook. Each field is [None] to leave the current value unchanged. *)

(** {1 Helper functions} *)

val tool_output_to_result_content :
  tool_call_id:string ->
  is_error:bool ->
  tool_output ->
  Pera_types.Types.tool_result_content
(** [tool_output_to_result_content ~tool_call_id ~is_error output] converts a
    [tool_output] to a {!Pera_types.Types.tool_result_content} for inclusion in
    the message history.

    - [Tool_text s] becomes [content = `String s].
    - [Tool_json j] becomes [content = j]. *)

(** {1 Loop seam type} *)

type stream_fn =
  model:Pera_types.Types.model ->
  context:Pera_provider.Provider.context ->
  options:Pera_provider.Provider.simple_stream_options ->
  sw:Eio.Switch.t ->
  ( Pera_types.Types.assistant_message_event,
    Pera_types.Types.assistant_message )
  Pera_provider.Event_stream.t
(** The function type the agent loop uses to call a provider for one turn.

    This is the loop's provider-agnostic seam: any value satisfying this type
    can be used as the provider backend. The [Faux_provider] test double and the
    adapter from [Provider.S] both produce values of this type.

    The [~env] parameter is absent by design — the loop itself is pure-from-IO.
    Callers that wrap a real [Provider.S] bind [~env] into the closure before
    passing it here. *)

(** {1 Alcotest support} *)

val assistant_message_equal :
  Pera_types.Types.assistant_message ->
  Pera_types.Types.assistant_message ->
  bool
(** Structural equality for {!Pera_types.Types.assistant_message}. Uses
    type-specific equality for all fields; does not use polymorphic [(=)]. *)

val assistant_message_event_equal :
  Pera_types.Types.assistant_message_event ->
  Pera_types.Types.assistant_message_event ->
  bool
(** Structural equality for {!Pera_types.Types.assistant_message_event}. Uses
    type-specific equality for all fields; does not use polymorphic [(=)]. *)

val agent_event_equal : agent_event -> agent_event -> bool
(** Structural equality for {!agent_event}. Does not use polymorphic [(=)]; uses
    pattern matching on each constructor. *)

val pp_agent_event : Format.formatter -> agent_event -> unit
(** Pretty-printer for {!agent_event}. Sufficient for test output. *)

val agent_event_testable : agent_event Alcotest.testable
(** Alcotest testable for {!agent_event}. Use with
    [Alcotest.testable pp_agent_event agent_event_equal]. *)
