(** Tools assembly module for the Pera agent framework.

    Provides a single [default] function that assembles all four tools (read,
    write, bash, grep) from one execution environment. This is the canonical
    entry point for constructing all standard tools. *)

type local_tool = (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool
(** Convenience alias: a tool whose execute receives [~ctx] as a first-class
    module satisfying [Execution_env.S]. The loop config for these tools uses
    [tool_ctx = exec_env]. *)

val read : local_tool
(** [read] is a read tool. See {!Read_tool.read}. *)

val write : local_tool
(** [write] is a write tool. See {!Write_tool.write}. *)

val bash : local_tool
(** [bash] is a bash tool. See {!Bash_tool.bash}. *)

val grep : local_tool
(** [grep] is a grep tool. See {!Grep_tool.grep}. *)

val default : local_tool list
(** [default] returns [[read; write; bash; grep]]. This is the standard
    assembly function for building all four tools.

    Loop config wiring:
    {[
      let tools = Tools.default in
      let config = {
        tool_ctx = exec_env;
        tools;
        ... }
    ]} *)
