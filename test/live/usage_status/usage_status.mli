(** Human-readable one-line rendering of [Pera_types.Types.usage] for driver
    status output.

    Format: [in=N out=N cache_read=N cache_write=N], with [ cost=$X] appended
    when [cost_usd] is [Some]. The individual fields of [Types.usage] remain
    public record fields, so alternative formatters can read them directly
    rather than re-parsing this string. *)

val format : Pera_types.Types.usage -> string
(** [format u] renders [u] as a single status line. *)