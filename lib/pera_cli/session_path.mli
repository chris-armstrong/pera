(** Session file path generation. *)

val generate_filename :
  secure_random:(bytes -> unit) -> wall_time:(unit -> Unix.tm) -> string
(** Generate a filename of the form [<YYYYMMDD>_<HHMMSS>_<uuidv4>.jsonl].
    [secure_random buf] writes exactly 16 cryptographically random bytes into
    [buf]. [wall_time ()] returns the local-time breakdown. The UUID is built
    with [Uuidm.v4]. *)

val default_session_dir : string -> string
(** [default_session_dir home] is
    [home / ".local" / "state" / "pera" / "sessions"]. Uses [Fpath] for joining.
*)

val resolve :
  session_override:string option ->
  session_dir:string ->
  secure_random:(bytes -> unit) ->
  wall_time:(unit -> Unix.tm) ->
  string
(** If [session_override] is [Some p], return [p] directly. Otherwise return
    [session_dir / generate_filename ~secure_random ~wall_time] joined via
    [Fpath]. *)
