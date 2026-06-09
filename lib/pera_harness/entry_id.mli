type t
(** A full 36-character UUIDv7 string (abstract). Create via [generate]. *)

val generate : unit -> t
(** [generate ()] returns a fresh standard 36-character UUIDv7 string.
    Clock non-monotonicity within a millisecond is acceptable for session
    ordering. *)

val to_string : t -> string
(** [to_string id] returns the underlying 36-character UUID string. *)
