(** Read PERA_* environment variables via an injected [getenv_opt] function.

    All functions take a [getenv_opt] parameter rather than calling
    [Sys.getenv_opt] directly, so tests can supply a canned lookup without
    [Unix.putenv]. *)

type api_key_override =
  | AK_key of string
  | AK_file of string
  | AK_command of string list
  | AK_none

val read_api_key_override :
  getenv_opt:(string -> string option) -> (api_key_override, string) result
(** Read [PERA_API_KEY] / [PERA_API_KEY_FILE] / [PERA_API_KEY_COMMAND] via
    [getenv_opt]. [Error] if more than one is set. [Ok AK_none] if none are set.
*)

val read_partial_config :
  getenv_opt:(string -> string option) -> (Pera_config.config, string) result
(** Build a partial [Pera_config.config] from [PERA_*] env vars. Only fields
    with a corresponding env var set are populated; the rest are [None] / [[]].
    Returns [Error msg] if a typed var (effort, cache policy, etc.) has an
    unrecognised value; [msg] quotes the bad value and the variable name. *)
