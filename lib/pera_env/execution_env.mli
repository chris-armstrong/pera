(** Execution environment abstraction for the Pera agent framework.

    Defines the module types for filesystem and shell operations, and the
    combined [S] signature. Tools and harness code operate against this
    abstraction — never directly against the OS. *)

(** {1 Shared types} *)

type file_kind = [ `File | `Directory | `Symlink ]
(** Kind of a filesystem entry. *)

type file_info = {
  name : string;  (** Entry name (last path component). *)
  path : string;  (** Absolute path of the entry. *)
  kind : file_kind;  (** Kind of entry (file, directory, or symlink). *)
  size : int;  (** Size in bytes. *)
  mtime_s : float;  (** Modification time, seconds since Unix epoch. *)
}
(** Metadata about a filesystem entry. *)

type exec_result = {
  stdout : string;  (** Standard output content. *)
  stderr : string;  (** Standard error content. *)
  exit_code : int;  (** Process exit code. *)
}
(** Result of a shell command execution. *)

(** {1 Filesystem module type} *)

(** Abstract filesystem operations.

    All IO operations return [result] and take [sw] for structured concurrency.
    OS-level exceptions are caught and mapped to typed [file_error] codes. *)
module type FILESYSTEM = sig
  val read_text_file :
    path:string ->
    sw:Eio.Switch.t ->
    (string, Pera_types.Types.file_error) result
  (** [read_text_file ~path ~sw] reads the entire file at [path] as a UTF-8
      string. Returns [Error] with [NotFound] if the file does not exist. *)

  val write_file :
    path:string ->
    content:string ->
    sw:Eio.Switch.t ->
    (unit, Pera_types.Types.file_error) result
  (** [write_file ~path ~content ~sw] writes [content] to [path], overwriting
      any existing content. Creates parent directories if they do not exist. *)

  val append_file :
    path:string ->
    content:string ->
    sw:Eio.Switch.t ->
    (unit, Pera_types.Types.file_error) result
  (** [append_file ~path ~content ~sw] appends [content] to the file at [path].
      Creates the file if it does not exist. *)

  val list_dir :
    path:string ->
    sw:Eio.Switch.t ->
    (file_info list, Pera_types.Types.file_error) result
  (** [list_dir ~path ~sw] lists entries in directory [path]. Returns file_info
      for each entry. *)

  val file_info :
    path:string ->
    sw:Eio.Switch.t ->
    (file_info, Pera_types.Types.file_error) result
  (** [file_info ~path ~sw] returns metadata for the entry at [path]. Returns
      [Error] with [NotFound] if the path does not exist. *)

  val exists :
    path:string -> sw:Eio.Switch.t -> (bool, Pera_types.Types.file_error) result
  (** [exists ~path ~sw] checks whether a file or directory exists at [path].
      Absence is not an error — returns [Ok false]. *)

  val create_dir :
    path:string -> sw:Eio.Switch.t -> (unit, Pera_types.Types.file_error) result
  (** [create_dir ~path ~sw] creates a directory at [path]. Creates parent
      directories if they do not exist. Returns [Error] if [path] already exists
      as a file. *)

  val absolute_path : string -> (string, Pera_types.Types.file_error) result
  (** [absolute_path p] resolves the relative path [p] against the environment's
      current working directory. Pure — no IO. Returns [Error] if the path
      cannot be resolved. *)

  val join_path : string list -> string
  (** [join_path segments] joins path segments using the OS path separator. Pure
      — never fails. *)

  val canonical_path :
    path:string ->
    sw:Eio.Switch.t ->
    (string, Pera_types.Types.file_error) result
  (** [canonical_path ~path ~sw] resolves symlinks and normalises the path.
      IO-bound (traverses the filesystem). *)
end

(** {1 Shell module type} *)

(** Abstract shell execution operations.

    [exec] runs a shell command. [find_executable] locates executables on PATH.
*)
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
  (** [exec ~command ~sw ~cancel] executes a shell command. Returns the captured
      stdout, stderr, and exit code. *)

  val find_executable : name:string -> string option
  (** [find_executable ~name] searches PATH for an executable named [name].
      Returns [Some path] if found, [None] otherwise. Pure — no IO. *)
end

(** {1 Combined signature} *)

(** Combined execution environment signature.

    An [S] value provides both filesystem and shell operations bound to a common
    current working directory. *)
module type S = sig
  val cwd : string
  (** The working directory this env is rooted at. Pass to [Sh.exec ~cwd] to run
      subprocesses in the agent's cwd regardless of the process cwd. *)

  module Fs : FILESYSTEM
  (** Filesystem operations. *)

  module Sh : SHELL
  (** Shell execution operations. *)
end
