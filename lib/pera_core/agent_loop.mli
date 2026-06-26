(** Agent loop — outer/inner turn loops, streaming, and between-turn hooks.

    This module implements the control flow described in the specification §5:
    an outer loop (drives follow-up restarts) wrapped around an inner loop
    (iterates turns while there are pending steering messages or tool calls).

    All external calls go through config callbacks; the loop itself is
    pure-from-IO (no piaf, no files, no clock). *)

(** {1 Hook context types} *)

type 'ctx should_stop_ctx = {
  message : Agent_types.agent_message;
      (** The final assistant message from the completed turn. *)
  tool_results : Pera_types.Types.tool_result_content list;
      (** Tool results produced in this turn; empty for text-only turns. *)
  messages : Agent_types.agent_message list;
      (** The full conversation history after this turn. *)
  tool_ctx : 'ctx;  (** The tool context from the loop config. *)
  emit : Agent_types.agent_event -> unit;
      (** Push an event into the loop's own event stream, in order, after this
          turn's [AE_turn_end] and before the next turn. Used by the harness
          compaction hook to emit [AE_compaction_*] events. *)
}
(** Context passed to the [should_stop_after_turn] hook. *)

type 'ctx prepare_ctx = {
  message : Agent_types.agent_message;
      (** The final assistant message from the completed turn. *)
  tool_results : Pera_types.Types.tool_result_content list;
      (** Tool results produced in this turn; empty for text-only turns. *)
  messages : Agent_types.agent_message list;
      (** The full conversation history after this turn. *)
  tool_ctx : 'ctx;  (** The tool context from the loop config. *)
}
(** Context passed to the [prepare_next_turn] hook. *)

type 'ctx before_tool_call_ctx = {
  message : Agent_types.agent_message;
      (** The assistant message that produced the tool call. *)
  tool_call : Pera_types.Types.tool_call;
      (** The tool call being considered. *)
  validated_args : Yojson.Safe.t;  (** Validated arguments for the tool call. *)
  tool_ctx : 'ctx;  (** The tool context from the loop config. *)
}
(** Context passed to the [before_tool_call] hook. *)

type 'ctx after_tool_call_ctx = {
  tool_call : Pera_types.Types.tool_call;  (** The tool call that completed. *)
  result : Pera_types.Types.tool_result_content;
      (** The tool result content. *)
  tool_ctx : 'ctx;  (** The tool context from the loop config. *)
}
(** Context passed to the [after_tool_call] hook. *)

(** {1 Loop configuration} *)

type 'ctx agent_loop_config = {
  model : Pera_types.Types.model;
      (** The model to use for LLM calls. May be overridden by
          [prepare_next_turn]. *)
  system : string;  (** System prompt. *)
  options : Pera_connector.Connector.simple_stream_options;
      (** Streaming options (max_tokens, temperature). *)
  stream_fn : Agent_types.stream_fn;
      (** Provider-agnostic seam for making LLM calls. *)
  convert_to_llm :
    Agent_types.agent_message list -> Pera_connector.Connector.message list;
      (** Converts the agent message history to the provider message format.
          Applied after [transform_context]. *)
  tool_ctx : 'ctx;  (** Context value passed to all tool [execute] calls. *)
  tools : 'ctx Agent_types.tool list;
      (** Tools available to the model. Empty means no tool use. *)
  tool_execution : [ `Sequential | `Parallel ];
      (** Default execution mode for tool calls. If any called tool has mode
          [`Sequential], the whole batch runs sequentially regardless of this
          setting. *)
  transform_context :
    (Agent_types.agent_message list -> Agent_types.agent_message list) option;
      (** Optional transform applied to the message history before
          [convert_to_llm]. Use for context pruning, summarisation, etc. *)
  get_api_key : (provider:string -> string option) option;
      (** Optional callback to resolve an API key by provider name. Called once
          per LLM call before invoking [stream_fn]. The key value is not used by
          the loop itself; this callback exists to satisfy provider contracts.
      *)
  before_tool_call :
    ('ctx before_tool_call_ctx -> Agent_types.before_tool_call_result) option;
      (** Optional hook called before each tool execution. Return [Allow] to
          proceed or [Deny msg] to skip execution and surface [msg] as an error
          result. *)
  after_tool_call : ('ctx after_tool_call_ctx -> unit) option;
      (** Optional hook called after each tool execution completes (including
          error results). Side-effect only. *)
  should_stop_after_turn : ('ctx should_stop_ctx -> bool) option;
      (** Optional hook called after each turn. If it returns [true], the inner
          loop exits and the outer loop checks for follow-up messages. *)
  prepare_next_turn :
    ('ctx prepare_ctx -> Agent_types.turn_update option) option;
      (** Optional hook called after [should_stop_after_turn] (when the run
          continues). Returns a [turn_update] to swap messages, model, or
          thinking setting for the next turn; [None] to keep everything
          unchanged. *)
  get_steering_messages : (unit -> Agent_types.agent_message list) option;
      (** Optional callback invoked once per inner-loop iteration. If it returns
          a non-empty list, those messages are injected as pending for the next
          iteration, keeping the inner loop alive for another turn. *)
  get_follow_up_messages : (unit -> Agent_types.agent_message list) option;
      (** Optional callback invoked after the inner loop exits. If it returns a
          non-empty list, the outer loop restarts the inner loop with those
          messages as the initial pending input. *)
}
(** Full configuration for an agent loop run. *)

(** {1 Entry point} *)

val run :
  'ctx agent_loop_config ->
  messages:Agent_types.agent_message list ->
  sw:Eio.Switch.t ->
  ( Agent_types.agent_event,
    Agent_types.agent_message list )
  Pera_connector.Event_stream.t
(** [run config ~messages ~sw] starts an agent loop run.

    Forks a fibre under [sw] that drives the outer/inner loop and pushes
    {!Agent_types.agent_event} values into the returned
    {!Pera_connector.Event_stream.t}.

    The stream is closed with [Ok final_messages] on [AE_agent_end], where
    [final_messages] is the complete conversation history including all turns.

    The caller should consume the stream via {!Pera_connector.Event_stream.iter}
    and read the final messages via {!Pera_connector.Event_stream.result}.

    @param messages
      Initial conversation history (typically a single user message).
    @param sw
      The switch under which the loop fibre runs. Cancelling [sw] cancels the
      loop. *)
