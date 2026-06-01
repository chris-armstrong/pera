type t = string
(** A full 36-character UUIDv7 string. *)

val generate : unit -> t
(** [generate ()] returns a fresh standard 36-character UUIDv7 string.
    Clock non-monotonicity within a millisecond is acceptable for session
    ordering. *)
