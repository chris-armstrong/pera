(** Build shell-backed tools from [shell_tool_def] config entries.

    Startup-time validation checks that every [{name}] placeholder in the
    command template corresponds to a declared argument. The constructed tool's
    [execute] function extracts argument values from the JSON args, substitutes
    them into the template, and runs the resulting command via
    [(val ctx).Sh.exec]. *)

type build_error = Unknown_placeholder of string

val build :
  Pera_config.shell_tool_def ->
  ( (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool,
    build_error )
  result
(** Build a single tool from a [shell_tool_def].

    Startup-time validation: every [{name}] token in [command] must correspond
    to a declared arg; any unknown placeholder is
    [Error (Unknown_placeholder name)].

    The constructed tool's [execute] function:
    - Extracts each declared arg value from [args] JSON.
    - Substitutes [{name}] with [Filename.quote value].
    - Calls [(val ctx).Sh.exec ~cwd:E.cwd command_string].
    - Returns [Tool_text output] on success, [tool_error] on failure. *)

val build_all :
  Pera_config.shell_tool_def list ->
  ( (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool list,
    build_error )
  result
(** [build_all defs] calls [build] on each element; short-circuits on the first
    error. *)

val substitute : string -> (string * string) list -> string
(** [substitute template arg_values] replaces [{name}] placeholders in
    [template] with [Filename.quote value] from [arg_values]. Exposed for
    testing. *)
