(** Pure text truncation module.

    Provides line- and byte-based truncation for tool output. No IO. No Eio.
    Pure string manipulation. *)

val max_lines : int
(** Maximum number of lines before truncation (2000). *)

val max_bytes : int
(** Maximum number of bytes before truncation (262,144 — 256 KB). *)

type truncation_info = {
  truncated : bool;  (** Whether the content was truncated. *)
  total_lines : int;
      (** Total number of lines in the input content (before truncation). *)
  output_lines : int;
      (** Number of lines in the output content (after truncation). *)
  truncated_by : [ `Lines | `Bytes ] option;
      (** Which limit caused the truncation, if any. [None] when not truncated.
      *)
}
(** Information about the truncation result. *)

val truncate_head : string -> string * truncation_info
(** [truncate_head content] shows the first [max_lines] lines or [max_bytes]
    bytes of [content], whichever limit is hit first.

    Used by read_tool to show the beginning of a file. *)

val truncate_tail : string -> string * truncation_info
(** [truncate_tail content] shows the last [max_lines] lines or [max_bytes]
    bytes of [content], whichever limit is hit first.

    Used by bash_tool to show the most recent output. *)
