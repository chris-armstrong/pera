(** Shared helpers for JSONL session-file inspection used by session and
    harness drivers. *)

type verdict = Pass | Fail of string

val parse_session_file : string -> Yojson.Safe.t list
(** Read the file at [path], split on newlines, and parse each non-empty line
    as JSON. Raises on malformed JSON. *)

val get_string : string -> Yojson.Safe.t -> string
(** [get_string key json] extracts [key] from [json] as a string. Raises
    [Yojson.Safe.Util.Type_error] if the key is absent or not a string. *)

val get_string_opt : string -> Yojson.Safe.t -> string option
(** [get_string_opt key json] extracts [key] as a string, returning [None] if
    absent or non-string. *)

val check_content_chain : Yojson.Safe.t list -> string option
(** Filter out leaf entries and verify each remaining entry's [parent_id]
    equals the previous entry's [id]. Returns [None] on success, [Some msg]
    on the first violation. *)

val assert_leaves_childless : Yojson.Safe.t list -> Yojson.Safe.t option
(** Returns [Some entry] if any entry references a leaf's [id] as its
    [parent_id]; [None] if all leaves are childless. *)

val verify_chain_and_leaves : Yojson.Safe.t list -> verdict
(** [check_content_chain] then [assert_leaves_childless]; returns [Pass] or a
    descriptive [Fail]. *)

val make_temp_dir : Eio_unix.Stdenv.base -> prefix:string -> string
(** Create a temporary directory under the system temp dir with a unique
    name derived from [prefix], the PID, and the current timestamp. *)

val cleanup : string -> unit
(** Remove [path] recursively (best-effort). *)

val print_verdict : tag:string -> scenario:string -> verdict -> unit
(** Print [[tag] scenario ... PASS] or [[tag] scenario ... FAIL: msg]. *)

val count_passed : (string * verdict) list -> int
(** Count scenarios whose verdict is [Pass]. *)

val collect_cumulative_usage : Yojson.Safe.t list -> Pera_types.Types.usage
(** [collect_cumulative_usage entries] sums the token fields of every
    assistant message's [usage] block in [entries]. [cost_usd] of the result
    is [None] — cost aggregation is provider-specific and not meaningful when
    summed across turns. *)

val parse_session_file_lenient : string -> Yojson.Safe.t list
(** [parse_session_file_lenient path] reads the file at [path], splits on
    newlines, and returns only the lines that parse as valid JSON, silently
    skipping lines that raise. Used to verify crash-resilience: a partial
    trailing line (simulating a crash mid-write) does not corrupt the
    previously-fsync'd entries. *)
