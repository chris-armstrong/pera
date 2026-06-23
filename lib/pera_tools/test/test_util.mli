(** Test utility functions shared across pera_tools test modules. *)

val make_temp_dir :
  < secure_random : _ Eio.Flow.source ; fs : _ Eio.Path.t ; .. > -> string
(** [make_temp_dir env] creates a temporary directory with a unique name under
    the system temp directory. Returns the path. The directory is not cleaned up
    on exit. *)

val write_file :
  (module Pera_env.Execution_env.S) ->
  path:string ->
  content:string ->
  sw:Eio.Switch.t ->
  unit
(** [write_file (module E) ~path ~content ~sw] writes [content] to [path] using
    the execution environment. Fails via [Alcotest.failf] on error. *)
