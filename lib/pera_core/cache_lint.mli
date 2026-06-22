(** Cache-stability dynamic-content linter.

    Anthropic prompt caching is byte-level prefix matching: any dynamic content
    in the system prompt or tool descriptions silently invalidates the cache.
    This module provides a heuristic linter that warns at construction time when
    a string looks like it contains timestamps, UUIDs, or other dynamic values.
*)

val warn_if_dynamic : ?quiet:bool -> field:string -> string -> unit
(** [warn_if_dynamic ?quiet ~field text] inspects [text] for common dynamic
    content patterns (ISO 8601 timestamps, RFC 3339 dates, UUID v4, long digit
    runs). On a match, it emits a [Logs.warn] message naming [field] and the
    matched pattern.

    [~quiet:true] suppresses the warning. *)
