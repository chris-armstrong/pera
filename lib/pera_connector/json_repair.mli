(** JSON repair utilities for malformed JSON produced during LLM streaming.

    Anthropic tool-input deltas sometimes contain:
    - raw control characters (literal tab, newline, CR) inside JSON strings
    - invalid backslash escapes (e.g. [\H], [\j]) that are not valid per the
      JSON specification

    This module repairs such strings and provides a streaming-safe parser that
    falls back to repair before giving up. *)

val repair : string -> string
(** [repair s] scans [s] and fixes two classes of malformed JSON string content:

    - Raw control characters (bytes 0x00-0x1F) inside JSON strings are replaced
      with their JSON escape sequences ({e \t}, {e \n}, {e \r}, {e \b}, {e \f},
      or {e \uXXXX} for other control characters).
    - Invalid backslash escapes (any sequence where a backslash is followed by a
      character not in the valid JSON escape set: double-quote, backslash,
      forward-slash, b, f, n, r, t, u) are doubled so they become a literal
      backslash followed by the character.

    Valid unicode escapes ([\uXXXX] where XXXX is exactly four hex digits) are
    passed through unchanged.

    Text outside JSON string literals (structural characters, numbers, keywords)
    is never modified. *)

val parse_streaming : string option -> (Yojson.Safe.t, string) result
(** [parse_streaming s] attempts to parse a potentially malformed JSON fragment
    produced during streaming.

    - If [s] is [None] or empty, returns an error.
    - Tries {!Yojson.Safe.from_string} on the input directly.
    - If that fails, calls {!repair} and tries again.
    - Returns [Error msg] if both attempts fail, where [msg] describes the parse
      failure. *)
