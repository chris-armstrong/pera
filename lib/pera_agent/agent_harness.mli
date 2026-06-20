(** Top-level assembly module for the Pera agent.

    Binds [Local_env], [Tools.default], [Session_writer], and [Agent_wrapper]
    into a single entry point. *)

type t
(** An agent harness handle. *)

type compaction_config = {
  trigger_tokens : int;
      (** Compact when estimate_messages (convert_to_llm context.messages) >
          this. *)
  tail_size : int;
      (** Number of trailing messages kept verbatim (spec default 4). *)
}
(** Configuration for autonomous compaction. *)

type config = {
  cwd : string;
  model : Pera_types.Types.model;
  session_path : string;
  stream_fn : Pera_core.Agent_types.stream_fn;
  max_tokens : int;
  exec_env : (module Pera_env.Execution_env.S);
  compaction : compaction_config option;
      (** [None] = no autonomous compaction (M5 behaviour). [Some cc] = compact
          automatically when the estimated token count exceeds
          [cc.trigger_tokens]. *)
}
(** Full configuration for creating an agent harness. *)

val create :
  config:config ->
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  (t, Pera_types.Types.file_error) result
(** [create ~config ~env ~sw] assembles the harness: creates a session writer,
    builds default tools from [exec_env], wires up [Agent_wrapper], and
    registers a session subscriber.

    Returns [Error] if the session file cannot be prepared. *)

val send : t -> string -> unit
(** [send t text] writes a user message to the session file and dispatches a run
    to the agent wrapper. The session info entry is written once on the first
    call. [send] never raises. *)

val subscribe : t -> (Pera_core.Agent_types.agent_event -> unit) -> unit -> unit
(** [subscribe t f] registers [f] to receive every agent event. Returns an
    unsubscribe function. *)
