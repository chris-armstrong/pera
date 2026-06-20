val make_temp_dir :
  < secure_random : _ Eio.Flow.source ; fs : _ Eio.Path.t ; .. > -> string
(** [make_temp_dir env] creates a uniquely-named temp directory under the system
    temp dir and returns its path. The directory is not cleaned up on exit; the
    OS reclaims it on reboot. *)
