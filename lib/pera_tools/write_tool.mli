(** Write tool for the Pera agent framework.

    Writes content to a file through the execution environment. Parent
    directories are created automatically (delegated to [Fs.write_file]).
    Overwrites existing files. Returns the number of bytes written. *)

val write :
  (module Pera_env.Execution_env.S) -> unit Pera_core.Agent_types.tool
(** [write env] constructs a write tool that writes files through [env].

    Schema arguments:
    - ["path"] (string, required): Path to write to.
    - ["content"] (string, required): Content to write to the file.

    Mode: [`Sequential] — concurrent writes to the same path may race. *)
