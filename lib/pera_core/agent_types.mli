(** Agent-core data model types for Pera.

    This module defines the vocabulary the agent loop is written against: agent
    messages (a superset of provider messages), agent events, the tool type,
    tool output, and hook result types.

    All types are pure — no loop logic or IO. *)

(** {1 Agent messages} *)

(** Synthetic message kinds. *)
type synthetic = Compaction_summary of { summary : string }

val equal_synthetic : synthetic -> synthetic -> bool
val pp_synthetic : Format.formatter -> synthetic -> unit
val show_synthetic : synthetic -> string

val compaction_framing : string
(** ["Context from earlier conversation:\n\n"] — the user-role framing
    prepended to a compaction summary when it is rendered for the LLM. *)

val synthetic_to_message : synthetic -> Pera_provider.Provider.message
(** Render a synthetic message into the provider message the LLM sees. For
    [Compaction_summary {summary}] this is a user message whose single text
    block is [compaction_framing ^ summary]. *)

(** Agent-level message: a real provider message, or a synthetic one. *)
type agent_message =
  | Real of Pera_provider.Provider.message
      (** A real provider message (user, assistant, or tool result). *)
  | Synthetic of synthetic  (** A synthetic message kind. *)

val to_provider_message : agent_message -> Pera_provider.Provider.message
(** [Real m -> m]; [Synthetic s -> synthetic_to_message s]. The canonical
    agent-to-provider message projection.

    NOTE: every synthetic in M6 is LLM-visible, so this is total. If a future
    {i invisible} synthetic is added, change the return type to [option] and
    have [convert_to_llm] [filter_map] over it. *)

(** {1 Tool types} *)

(** The output produced by a tool execution. *)
type tool_output =
  | Tool_text of string  (** Plain-text tool output. *)
  | Tool_json of Yojson.Safe.t  (** Structured JSON tool output. *)

val equal_tool_output : tool_output -> tool_output -> bool
val pp_tool_output : Format.formatter -> tool_output -> unit
val show_tool_output : tool_output -> string

(** Opaque tool type with a smart constructor and accessors.

    Hiding the record behind [Tool.t] lets us enforce invariants (e.g. stable
    JSON canonicalisation) and prevents callers from constructing tools with
    reordered or dynamic fields that silently break Anthropic prompt caching.

    The ['ctx] parameter is the context type supplied by the caller; it is
    passed unchanged to {!Tool.execute}. *)
module Tool : sig
  type 'ctx t

  val create :
    name:string ->
    description:string ->
    schema:Pera_provider.Json_schema.t ->
    parallel_safe:bool ->
    execute:
      (ctx:'ctx ->
       args:Yojson.Safe.t ->
       sw:Eio.Switch.t ->
       cancel:Eio.Cancel.t ->
       (tool_output, Pera_types.Types.tool_error) result) ->
    'ctx t
  (** Construct a tool.

      [parallel_safe] declares whether the tool can run concurrently with
      sibling tool calls. If any tool in a batch is [parallel_safe = false], the
      whole batch is forced to run sequentially. *)

  val name : _ t -> string
  val description : _ t -> string
  val schema : _ t -> Pera_provider.Json_schema.t
  val parallel_safe : _ t -> bool

  val execute :
    'ctx t ->
    ctx:'ctx ->
    args:Yojson.Safe.t ->
    sw:Eio.Switch.t ->
    cancel:Eio.Cancel.t ->
    (tool_output, Pera_types.Types.tool_error) result
end

(** Backwards-compatible alias for the opaque {!Tool.t}. *)
type 'ctx tool = 'ctx Tool.t

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
  | AE_compaction_start
      (** Autonomous compaction has begun (threshold crossed). *)
  | AE_compaction_end of { summary : string }
      (** Autonomous compaction succeeded; [summary] is the produced summary
          text. The harness session subscriber writes the Compaction entry, the
          synthetic user message, and a Leaf in response to this event. *)
  | AE_compaction_error of { message : string }
      (** Autonomous compaction failed; [message] describes the failure. The
          context is unchanged and the run continues uncompacted. *)

val equal_agent_event : agent_event -> agent_event -> bool
(** Derived structural equality for {!agent_event}. Uses [agent_message_equal]
    for [agent_message] fields and [Yojson.Safe.equal] for JSON fields. *)

val pp_agent_event : Format.formatter -> agent_event -> unit
(** Pretty-printer for {!agent_event}. Produces human-readable structured
    output, e.g. [AE_agent_end \{messages=[4]}]. *)

val show_agent_event : agent_event -> string
(** [show_agent_event e] is [Format.asprintf "%a" pp_agent_event e]. *)

(** {1 Hook result types} *)

(** Result returned by the [before_tool_call] hook. *)
type before_tool_call_result =
  | Allow  (** Allow the tool call to proceed. *)
  | Deny of string
      (** Deny the tool call with the given message; the message is surfaced to
          the model as an error tool result. *)

val equal_before_tool_call_result :
  before_tool_call_result -> before_tool_call_result -> bool

val pp_before_tool_call_result :
  Format.formatter -> before_tool_call_result -> unit

val show_before_tool_call_result : before_tool_call_result -> string

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

val equal_turn_update : turn_update -> turn_update -> bool
val pp_turn_update : Format.formatter -> turn_update -> unit
val show_turn_update : turn_update -> string

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

(** {1 Equality helpers} *)

val agent_message_equal : agent_message -> agent_message -> bool
(** Structural equality for {!agent_message}. Uses [Provider.equal_message]
    for [Real] messages and [equal_synthetic] for [Synthetic] messages. *)
