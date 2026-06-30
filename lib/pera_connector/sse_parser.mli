(** Provider-agnostic SSE chunk parser.

    Layer A of the two-layer SSE parsing architecture (spec §4). Receives raw
    byte chunks from an HTTP response body and emits fully-framed SSE events.

    This module is a pure byte-level parser with no IO or dependency on
    pera_types. *)

type framed_event = {
  event_type : string;
      (** Value of the [event:] field; empty string when no [event:] field was
          present in the event block. *)
  data : string;
      (** Value of the [data:] field. If multiple [data:] lines are present
          their values are joined with newlines. *)
  id : string option;  (** Value of the [id:] field, if present. *)
}

type state
(** Opaque parser state that holds any partial line buffer accumulated from
    previous [feed] calls. *)

val initial_state : state
(** The empty parser state. Pass this to the first call to [feed]. *)

val feed : state -> string -> state * framed_event list
(** [feed state chunk] appends [chunk] to any partial data buffered in [state],
    then extracts all complete SSE events delimited by blank lines ([\\n\\n]).

    Returns the updated state (holding any incomplete trailing data) and the
    list of fully-parsed events in the order they appeared. The returned list is
    empty when no complete events were present in the accumulated buffer. *)
