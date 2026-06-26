(** Write tool for the Pera agent framework.

    Writes content to a file through the execution environment. Parent
    directories are created automatically (delegated to [Fs.write_file]).
    Overwrites existing files. Returns the number of bytes written. *)

val write : (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool
(** [write] is a write tool that writes files through the execution environment
    passed as [~ctx] at execute time.

    Schema arguments:
    - ["path"] (string, required): Path to write to.
    - ["content"] (string, required): Content to write to the file.

    Mode: [`Sequential] — concurrent writes to the same path may race. *)
