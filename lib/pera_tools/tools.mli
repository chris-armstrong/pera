(** Tools assembly module for the Pera agent framework.

    Provides a single [default] function that assembles all four tools (read,
    write, bash, grep) from one execution environment. This is the canonical
    entry point for constructing all standard tools. *)

type local_tool = unit Pera_core.Agent_types.tool
(** Convenience alias: a tool whose constructor closes over its env and whose
    execute receives [~ctx:()]. The loop config for these tools uses
    [tool_ctx = ()]. *)

val read : (module Pera_harness.Execution_env.S) -> local_tool
(** [read env] constructs a read tool. See {!Read_tool.read}. *)

val write : (module Pera_harness.Execution_env.S) -> local_tool
(** [write env] constructs a write tool. See {!Write_tool.write}. *)

val bash : (module Pera_harness.Execution_env.S) -> local_tool
(** [bash env] constructs a bash tool. See {!Bash_tool.bash}. *)

val grep : (module Pera_harness.Execution_env.S) -> local_tool
(** [grep env] constructs a grep tool. See {!Grep_tool.grep}. *)

val default : (module Pera_harness.Execution_env.S) -> local_tool list
(** [default env] returns [[read env; write env; bash env; grep env]]. This is
    the standard assembly function for building all four tools from a single
    execution environment.

    Loop config wiring (for M5 harness):
    {[
      let env = Local_env.create ~env:eio_env ~cwd in
      let tools = Tools.default env in
      let config = {
        tool_ctx = ();
        tools;
        ... }
    ]} *)
