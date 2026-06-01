open Containers [@@warning "-33"]

type file_kind = [ `File | `Directory | `Symlink ]

type file_info = {
  name : string;
  path : string;
  kind : file_kind;
  size : int;
  mtime_s : float;
}

type exec_result = { stdout : string; stderr : string; exit_code : int }

module type FILESYSTEM = sig
  val read_text_file :
    path:string ->
    sw:Eio.Switch.t ->
    (string, Pera_types.Types.file_error) result

  val write_file :
    path:string ->
    content:string ->
    sw:Eio.Switch.t ->
    (unit, Pera_types.Types.file_error) result

  val append_file :
    path:string ->
    content:string ->
    sw:Eio.Switch.t ->
    (unit, Pera_types.Types.file_error) result

  val list_dir :
    path:string ->
    sw:Eio.Switch.t ->
    (file_info list, Pera_types.Types.file_error) result

  val file_info :
    path:string ->
    sw:Eio.Switch.t ->
    (file_info, Pera_types.Types.file_error) result

  val exists :
    path:string -> sw:Eio.Switch.t -> (bool, Pera_types.Types.file_error) result

  val create_dir :
    path:string -> sw:Eio.Switch.t -> (unit, Pera_types.Types.file_error) result

  val absolute_path : string -> (string, Pera_types.Types.file_error) result
  val join_path : string list -> string

  val canonical_path :
    path:string ->
    sw:Eio.Switch.t ->
    (string, Pera_types.Types.file_error) result
end

module type SHELL = sig
  val exec :
    command:string ->
    ?cwd:string ->
    ?env:(string * string) list ->
    ?timeout:float ->
    ?on_stdout:(string -> unit) ->
    ?on_stderr:(string -> unit) ->
    sw:Eio.Switch.t ->
    cancel:Eio.Cancel.t ->
    (exec_result, Pera_types.Types.execution_error) result

  val find_executable : name:string -> string option
end

module type S = sig
  module Fs : FILESYSTEM
  module Sh : SHELL
end
