(** Runtime JSON schema DSL for tool argument schemas (spec §9).

    Schemas are plain data values — no GADTs, no ppx required. Two operations
    are supported:
    - {!to_json}: renders the schema to JSON Schema draft-07 for sending to
      LLMs.
    - {!validate}: validates a JSON value against the schema, applying the same
      type coercions that Anthropic/Pi use so that string-wrapped primitives
      (e.g. ["42"] for an integer field) pass validation.

    [validate]'s coercion rules are a close translation of pi's
    [coercePrimitiveByType]/[coerceWithJsonSchema] ([packages/ai/src/utils/validation.ts],
    [github.com/earendil-works/pi], MIT). *)

(** A JSON schema node. *)
type t =
  | Object of {
      properties : (string * t) list;
          (** Named properties, in declaration order. *)
      required : string list;
          (** Names of required properties. Optional properties are listed in
              [properties] but absent from [required]. *)
      description : string option;
    }
  | String of { description : string option }
  | Number of { description : string option }
  | Integer of { description : string option }
  | Boolean of { description : string option }
  | Array of { items : t; description : string option }
  | Enum of { values : string list; description : string option }
  | Const of { value : Yojson.Safe.t }
  | Any_of of { schemas : t list }

(** Constructors — convenience wrappers for the [t] variant. *)

val object_ :
  ?description:string ->
  properties:(string * t) list ->
  required:string list ->
  unit ->
  t
(** [object_ ~properties ~required ()] constructs an object schema. Properties
    not in [required] are treated as optional. *)

val string : ?description:string -> unit -> t
val number : ?description:string -> unit -> t
val integer : ?description:string -> unit -> t
val boolean : ?description:string -> unit -> t

val array : ?description:string -> items:t -> unit -> t
(** [array ~items ()] constructs an array schema where every element must
    conform to [items]. *)

val enum : ?description:string -> string list -> t
(** [enum values] constructs an enum schema accepting only the given string
    values. *)

val const : Yojson.Safe.t -> t
(** [const value] constructs a schema that accepts only [value]. *)

val any_of : t list -> t
(** [any_of schemas] constructs a union schema (JSON Schema [anyOf]). *)

val optional : t -> t
(** [optional schema] wraps [schema] in an [any_of] with {!Const}[(`Null)],
    making the field accept either the given schema or [null]. This is a
    convenience for marking object properties as nullable/optional. *)

(** {2 Operations} *)

val to_json : t -> Yojson.Safe.t
(** [to_json schema] renders [schema] as a JSON Schema draft-07 object suitable
    for sending to an LLM API.

    The output is canonical: every JSON object has its keys sorted
    alphabetically (recursively), and object [required] lists are sorted
    alphabetically. Two schemas with the same logical content therefore produce
    identical serialised bytes regardless of declaration order. This stability is
    required for Anthropic prompt caching, which matches request prefixes at
    the byte level.

    Callers should serialise the result with [Yojson.Safe.to_string], not
    [Yojson.Safe.pretty_to_string], to keep bytes compact and stable. *)

val validate : t -> Yojson.Safe.t -> (unit, string) result
(** [validate schema value] checks that [value] conforms to [schema].

    Type coercions are applied before validation, matching Pi's behaviour so
    that tool arguments returned as JSON-encoded strings by Anthropic are
    accepted:
    - A JSON string ["42"] is coerced to the integer 42 for {!Integer} schemas.
    - A JSON string ["true"] / ["false"] is coerced to a boolean.
    - A JSON number [1] / [0] is coerced to a boolean.
    - A JSON null is coerced to 0 / false / "" as appropriate.

    Certain coercions are deliberately rejected to preserve type safety:
    - The string ["1"] / ["0"] does {b not} coerce to boolean (only ["true"] /
      ["false"] do).
    - The string ["null"] does {b not} coerce to JSON null.
    - The string ["42.1"] does {b not} coerce to an integer.

    Returns [Ok ()] when the value (after coercion) is valid, or [Error message]
    with a human-readable description of the failure. Never raises. *)
