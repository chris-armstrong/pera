(** Render agent events to human-readable or JSON output lines.

    Stateful: tracks accumulated token usage and turn count for [/info]. *)

type t

val create : output:Pera_config.output_config -> json:bool -> t
(** Create a new renderer. [output] controls thinking and quiet modes. [json]
    enables NDJSON output. *)

val render : t -> Pera_core.Agent_types.agent_event -> string list
(** Render an agent event to zero or more output lines.

    - JSON mode ([json = true]): emit one NDJSON line per event.
    - Thinking blocks: only rendered when [output.show_thinking = true].
    - Quiet mode: only emit the final assistant text (suppress tool events). *)

val stats : t -> string
(** Format accumulated stats for [/info]: "Model: X | Turns: N | In: N Out: N
    Cache-R: N Cache-W: N" Pricing is not shown. *)
