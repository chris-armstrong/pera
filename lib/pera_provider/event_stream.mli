(** Generic event stream primitive for streaming completions.

    A bounded, backpressure-capable stream that carries typed events and
    resolves to a final result (or error) when the producer is done.

    The implementation is a thin layer over [Eio.Stream.t] for buffering plus an
    [Eio.Promise.t] for the final result. The stream is bounded (default
    capacity 32) so a stalled consumer backpressures the producer.

    Invariants:
    - [close] or [close_error] must be called exactly once per stream.
    - After [close] or [close_error], calling [push] has no effect.
    - [take] and [iter] must only be called from a fiber running under an
      [Eio.Switch.t]. *)

type ('event, 'result) t
(** A stream of [('event)] values that resolves to [('result, string) result].
*)

val create : capacity:int -> ('event, 'result) t
(** [create ~capacity] creates a new stream with the given bounded capacity.

    Use capacity 32 for normal use (default per spec). *)

val push : ('event, 'result) t -> 'event -> unit
(** [push t event] appends [event] to the stream.

    Blocks if the stream is at capacity (backpressure). *)

val close : ('event, 'result) t -> 'result -> unit
(** [close t result] signals that no more events will be pushed, and resolves
    the stream's result promise with [Ok result]. *)

val close_error : ('event, 'result) t -> string -> unit
(** [close_error t msg] signals that the stream failed, and resolves the result
    promise with [Error msg]. *)

val take :
  ('event, 'result) t ->
  [ `Event of 'event | `Done of 'result | `Error of string ]
(** [take t] takes the next item from the stream.

    Returns:
    - [`Event e] when an event is available.
    - [`Done r] when the stream was closed with [close r].
    - [`Error msg] when the stream was closed with [close_error msg].

    Blocks if no item is available. *)

val iter : ('event, 'result) t -> f:('event -> unit) -> ('result, string) result
(** [iter t ~f] applies [f] to every event in the stream, then returns the final
    result.

    Blocks until all events have been consumed and the stream is closed. *)

val result : ('event, 'result) t -> ('result, string) result
(** [result t] awaits and returns the final result of the stream.

    Blocks until [close] or [close_error] has been called. *)
