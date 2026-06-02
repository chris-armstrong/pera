(** Local-OS implementation of [Execution_env.S].

    Constructs an execution environment backed by the real OS through [Eio]
    primitives. *)

val create : env:Eio_unix.Stdenv.base -> cwd:string -> (module Execution_env.S)
(** [create ~env ~cwd] builds an [Execution_env.S] value that operates against
    the local filesystem and shell, rooted at [cwd].

    - Filesystem operations use [env#fs] (Eio directory handle).
    - Shell execution uses [env#process_mgr].
    - [cwd] is the base directory for resolving relative paths.
    - All IO operations return Result; OS exceptions are mapped to
      [Pera_types.Types.file_error] or [Pera_types.Types.execution_error]. *)
