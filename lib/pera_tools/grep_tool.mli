(** Grep tool for the Pera agent framework.

    Searches files using ripgrep (rg). Results are in path:line:content format,
    capped at 100 matches. Mode: Parallel. No system grep fallback; no OCaml Re
    fallback. *)

val grep :
  (module Pera_env.Execution_env.S) -> unit Pera_core.Agent_types.tool
(** [grep env] constructs a grep tool that searches files through [env].

    Schema arguments:
    - ["pattern"] (string, required): Search pattern (regular expression).
    - ["path"] (string, optional): File or directory to search. Defaults to
      current directory.
    - ["glob"] (string, optional): Filter files by glob pattern (e.g. ["*.ml"]).

    Mode: [`Parallel] — searches are independent.

    ripgrep must be installed. If not found at first `execute` call, an [Error]
    with install instructions is returned. The availability check is memoised
    per tool instance. *)
