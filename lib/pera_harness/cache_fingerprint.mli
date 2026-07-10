(** Session-level cache prefix fingerprint.

    Anthropic prompt caching is byte-level prefix matching: any change to the
    tool schemas or system prompt silently invalidates previously written
    caches. This module computes a stable fingerprint of that prefix from the
    canonical JSON of each registered tool plus the system prompt bytes, and
    emits a warning when the prefix changes between turns. *)

type t
(** A fingerprint of the cacheable prefix. *)

val compute : system:string -> tools:'ctx Pera_core.Agent_types.tool list -> t
(** [compute ~system ~tools] builds a stable fingerprint of the cacheable
    prefix.

    Each tool is serialised to the same canonical JSON shape the Anthropic
    provider emits on the wire, so declaration order in the underlying
    {!Pera_connector.Json_schema.t} does not affect the per-tool bytes. Tool
    order in [tools] is preserved: re-ordering the tool list changes the prefix
    and therefore the fingerprint. *)

val equal : t -> t -> bool
(** [equal a b] is [true] when the two fingerprints represent identical
    cacheable prefixes. *)

val pp : Format.formatter -> t -> unit
(** Print a short hex representation of the fingerprint. *)

val check_and_warn :
  previous:t -> current:t -> cache_policy:Pera_types.Types.cache_policy -> unit
(** [check_and_warn ~previous ~current ~cache_policy] emits a [Logs.warn] when
    [current] differs from [previous] and [cache_policy] is not
    {!Pera_types.Types.No_cache}.

    The warning includes a one-line hint indicating whether the tools, the
    system prompt, or both changed. *)
