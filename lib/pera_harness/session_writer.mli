(** Append-only JSONL session file writer with fsync. *)

type t
(** A session writer handle. *)

val create :
  path:string ->
  env:Eio_unix.Stdenv.base ->
  model:Pera_types.Types.model ->
  cwd:string ->
  (t, Pera_types.Types.file_error) result
(** [create ~path ~env ~model ~cwd] opens (or creates) the JSONL file at [path],
    generating a fresh session id. Parent directories are created as needed.
    Returns [Error] if the path cannot be prepared. *)

val write_session_info : t -> (unit, Pera_types.Types.file_error) result
(** Append a [session_info] entry and advance [current_parent_id]. *)

val write_message :
  t ->
  Pera_connector.Connector.message ->
  (unit, Pera_types.Types.file_error) result
(** Append a [message] entry and advance [current_parent_id]. *)

val write_leaf : t -> (unit, Pera_types.Types.file_error) result
(** Append a [leaf] entry. Does NOT advance [current_parent_id]. *)

val write_model_change :
  t -> Pera_types.Types.model -> (unit, Pera_types.Types.file_error) result
(** Append a [model_change] entry and advance [current_parent_id]. *)

val write_compaction :
  t ->
  summary:string ->
  first_kept_entry_id:Entry_id.t ->
  (unit, Pera_types.Types.file_error) result
(** Append a [compaction] entry parented at the current tip, then advance the
    tip to it. The synthetic summary message is written separately by the caller
    (a subsequent [write_message]), parenting to this entry. *)

val session_id : t -> string
(** The UUIDv7 session identifier generated at [create] time. *)

val current_parent_id : t -> Entry_id.t option
(** The id of the last advancing entry written, or [None] before any advancing
    entry has been written. *)
