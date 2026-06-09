(** Bash tool for the Pera agent framework.

    Executes shell commands through the execution environment. stdout and stderr
    are combined into a single output buffer. Output is tail-truncated to 2000
    lines or 256 KB. Non-zero exit codes and shell-level errors return
    [Error tool_error]. *)

val bash :
  (module Pera_env.Execution_env.S) -> unit Pera_core.Agent_types.tool
(** [bash env] constructs a bash tool that executes commands through [env].

    Schema arguments:
    - ["command"] (string, required): Bash command to execute.
    - ["timeout"] (number, optional): Timeout in seconds.

    Mode: [`Sequential] — shell state (environment, cwd) is shared between
    invocations. *)
