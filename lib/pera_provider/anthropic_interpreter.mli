(** Anthropic-specific SSE interpreter.

    Layer B of the two-layer SSE parsing architecture (spec §4). Consumes
    {!Sse_parser.framed_event} values produced by the SSE chunk parser and emits
    {!Pera_types.Types.assistant_message_event} values with immutable partial
    snapshots.

    Invariants:
    - Unknown event types (e.g. ["done"], ["proxy.stats"], ["ping"]) are
      silently ignored — never produce an error.
    - JSON repair failures from tool-use input produce
      {!Pera_types.Types.AME_error} rather than raising.
    - Each emitted event carries an immutable snapshot of the in-progress
      [assistant_message] that is structurally distinct from every other
      snapshot.

    The event-handling state machine in {!feed} is a close translation of
    pi's Anthropic SSE handling ([packages/ai/src/providers/anthropic.ts],
    [github.com/earendil-works/pi], MIT). *)

open Pera_types

type state
(** Opaque interpreter state. Holds the in-progress [assistant_message] builder
    accumulated so far: completed content blocks, any active text/thinking or
    tool-use buffer, and accumulated usage counters. *)

val initial_state : state
(** The empty interpreter state. Pass this to the first call to {!feed}. *)

val feed :
  state -> Sse_parser.framed_event -> state * Types.assistant_message_event list
(** [feed state event] processes one framed SSE event and returns the updated
    state and a list of zero or more [assistant_message_event] values to emit.

    The returned list is empty for event types that do not cause an emission
    (e.g. events before the first [message_start]). Each emitted event carries
    an immutable [partial] snapshot of the assistant message as it stands at the
    moment of emission.

    Unknown event types are silently ignored (empty list returned, state
    unchanged). *)
