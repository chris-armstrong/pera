(** Pure input-line parsing for the interactive loop.

    The interactive read loop itself lives in [Pera_cli.Make] because it needs
    the [Env] functor's stdin/tty accessors and the harness [send] handle. This
    module provides only the pure parsing functions. *)

type command_result =
  | Send of string  (** Send this text to the agent. *)
  | Compact  (** Trigger /compact. *)
  | Info  (** Show /info stats. *)
  | Quit  (** Exit the session. *)
  | Error of string  (** User-visible error message. *)

val is_tty : stdin_isatty:bool -> bool
(** [is_tty ~stdin_isaty] returns [stdin_isaty]. The tty check is injected by
    the caller so this module stays pure and testable. *)

val parse_line :
  commands:Pera_config.command_def list -> string -> command_result
(** Parse one input line. See spec for behaviour. Pure. *)

val expand_template : template:string -> args:string -> string
(** Substitute [{args}] → [args]; [{1}],[{2}],... → whitespace-delimited tokens.
    Pure. *)
