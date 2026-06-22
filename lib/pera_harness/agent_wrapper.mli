(** Actor/mailbox wrapper over [Agent_loop.run].

    [create] forks a long-lived actor fibre under the supplied switch.
    [send] enqueues a [Run] message to a capacity-1 mailbox and blocks until the
    actor has finished processing the run.  Concurrent senders queue behind the
    capacity-1 stream; neither is rejected.

    Provides subscription fan-out and observable state (is_streaming,
    pending_tool_call_names, current_messages). *)

type 'ctx t
(** An agent wrapper parameterised by the tool context type ['ctx]. *)

val create :
  config:'ctx Pera_core.Agent_loop.agent_loop_config ->
  sw:Eio.Switch.t ->
  'ctx t
(** [create ~config ~sw] allocates a wrapper and forks an actor fibre under
    [sw].  The fibre lives as long as [sw] is active.

    @param config  Full agent loop configuration.
    @param sw      Switch that owns the actor fibre's lifetime. *)

val subscribe :
  'ctx t -> (Pera_core.Agent_types.agent_event -> unit) -> unit -> unit
(** [subscribe t f] registers [f] to receive every event emitted during a run.
    Events are delivered synchronously from the actor fibre, in the order they
    are emitted.

    Returns an unsubscribe function: calling it removes [f] from the subscriber
    list.  [f] will not be called after the unsubscribe function returns. *)

val send :
  'ctx t -> messages:Pera_core.Agent_types.agent_message list -> unit
(** [send t ~messages] enqueues a run request and blocks until the actor has
    finished processing it.  If another run is in progress, the caller blocks
    until the mailbox slot is free (capacity 1), at which point the actor takes
    the message and begins processing.  [send] never raises. *)

val is_streaming : 'ctx t -> bool
(** [is_streaming t] returns [true] while the actor is processing a run. *)

val pending_tool_call_names : 'ctx t -> string list
(** [pending_tool_call_names t] returns the names of all tool calls that have
    started but not yet completed, in the order they were started. *)

val current_messages : 'ctx t -> Pera_core.Agent_types.agent_message list
(** [current_messages t] returns the full conversation history as of the last
    [AE_agent_end] event.  Returns [[]] before the first run completes. *)

val last_error :
  'ctx t -> (string * Pera_types.Types.stop_error) option
(** [last_error t] returns the most recent provider error, if any. Set on
    [AE_message_end] when [stop_reason = Error _]. The pair is
    [(human_message, structured_error)]. *)
