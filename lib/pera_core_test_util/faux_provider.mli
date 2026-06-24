(** Faux_provider — deterministic test double for the agent loop.

    Emits scripted {!Pera_types.Types.assistant_message_event} values and
    resolves to a scripted final {!Pera_types.Types.assistant_message} without
    any network or filesystem IO.

    This module satisfies {!Pera_connector.Connector.S} (via {!as_provider}) and
    also exposes a {!Agent_types.stream_fn} adapter (via
    {!stream_fn_of_scripts}) which is the form the agent loop consumes directly.

    The context passed to each {!Agent_types.stream_fn} call is recorded so
    tests can assert on the exact provider input (e.g. verifying that
    [convert_to_llm], [transform_context], and steering message injection
    produced the expected messages). *)

type turn_script = {
  events : Pera_types.Types.assistant_message_event list;
      (** Events pushed into the stream before it is closed. *)
  final : Pera_types.Types.assistant_message;
      (** The final assistant message used to close the stream with [Ok final].
      *)
}
(** A single scripted turn: a list of events the provider emits, followed by the
    final assistant message that closes the stream. *)

type error_script = {
  error_events : Pera_types.Types.assistant_message_event list;
      (** Events pushed before the error is signalled. *)
  error_message : string;  (** The error string passed to [close_error]. *)
}
(** A scripted turn that resolves as an error. *)

(** A script for a single call to the stream function. *)
type script =
  | Turn of turn_script  (** Normal turn that resolves with a final message. *)
  | Error of error_script  (** Turn that resolves with a transport error. *)

val stream_fn_of_scripts :
  ?pause:(unit -> unit) -> script list -> Pera_core.Agent_types.stream_fn
(** Build a {!Agent_types.stream_fn} that plays through [scripts] in order. Each
    call to the returned function consumes the next script; calling it more
    times than there are scripts raises
    [Failure "Faux_provider: no more scripts"].

    The optional [pause] callback is invoked between events, allowing tests to
    inject cancellation mid-stream. *)

val recorded_contexts : unit -> Pera_connector.Connector.context list
(** Returns all {!Pera_connector.Connector.context} values recorded so far, in
    call order (oldest first).

    The list is module-level state; call {!reset_recorded} between tests to
    avoid cross-contamination. *)

val reset_recorded : unit -> unit
(** Clears the recorded context list. Call between test cases. *)

val as_provider : script list -> (module Pera_connector.Connector.S)
(** [as_provider scripts] wraps [scripts] in a first-class module satisfying
    {!Pera_connector.Connector.S}.

    The module has [type t = unit] (stateless). [create] ignores [~env] and
    [~sw] and returns [()]. [stream_simple] ignores the [unit] instance and
    delegates to {!stream_fn_of_scripts}. This function exists to prove that
    [Faux_provider] is a valid [Connector.S] and that the adapter is trivial;
    the loop itself always uses the {!Agent_types.stream_fn} form directly. *)
