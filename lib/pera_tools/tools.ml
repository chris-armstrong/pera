[@@@warning "-33"]

open Containers

type local_tool = (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool

let read = Read_tool.read
let write = Write_tool.write
let bash = Bash_tool.bash
let grep = Grep_tool.grep
let default = [ read; write; bash; grep ]
