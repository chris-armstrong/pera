(** Read tool for the Pera agent framework.

    Reads a file from the execution environment and returns its content as
    [Tool_text], with truncation and offset/limit support. *)

val read : (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool
(** [read] is a read tool that reads files through the execution environment
    passed as [~ctx] at execute time.

    Schema arguments:
    - ["path"] (string, required): Path to the file to read.
    - ["offset"] (integer, optional): 1-indexed line number to start from.
      Default is 0 (beginning of file).
    - ["limit"] (integer, optional): Maximum number of lines to return. Default
      is 2000.

    Truncation: Output is capped at [Truncate.max_lines] lines or
    [Truncate.max_bytes] bytes. A continuation footer is appended when
    truncation occurs. *)
