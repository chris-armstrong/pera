(** OpenAI-completions-specific SSE interpreter.

    Layer B of the two-layer SSE parsing architecture (spec §4). Consumes
    {!Sse_parser.framed_event} values produced by the SSE chunk parser and emits
    {!Pera_types.Types.assistant_message_event} values with immutable partial
    snapshots.

    The OpenAI wire format has no explicit content-block lifecycle; the
    interpreter infers block boundaries from the presence/absence of delta
    fields.

    Invariants:
    - Unknown delta fields are silently ignored.
    - JSON parse failures from SSE data produce {!Pera_types.Types.AME_error}
      rather than raising.
    - Each emitted event carries an immutable snapshot of the in-progress
      [assistant_message] that is structurally distinct from every other
      snapshot. *)

open Pera_types

type state
(** Opaque interpreter state. *)

val initial_state : reasoning_field:string -> state
(** The empty interpreter state configured with the given [reasoning_field] name
    (e.g. ["reasoning_content"] or ["reasoning"]).

    The reasoning field comes from the compat record at provider creation time;
    it does not change per-chunk. *)

val feed :
  state -> Sse_parser.framed_event -> state * Types.assistant_message_event list
(** [feed state event] processes one framed SSE event and returns the updated
    state and a list of zero or more [assistant_message_event] values to emit.

    The returned list is empty for chunks that do not cause an emission (e.g.
    the initial role chunk). Each emitted event carries an immutable [partial]
    snapshot of the assistant message as it stands at the moment of emission.

    The [[DONE]] sentinel string produces [AME_done]. Malformed JSON data
    produces [AME_error]. *)
