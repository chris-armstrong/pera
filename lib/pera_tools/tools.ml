[@@@warning "-33"]

open Containers

type local_tool = unit Pera_core.Agent_types.tool

let read = Read_tool.read
let write = Write_tool.write
let bash = Bash_tool.bash
let grep = Grep_tool.grep
let default env = [ read env; write env; bash env; grep env ]
