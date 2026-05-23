open Containers

(** Runtime JSON schema DSL. *)

type t =
  | Object of {
      properties : (string * t) list;
      required : string list;
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

(* ── constructors ────────────────────────────────────────────────────────── *)

let object_ ?description ~properties ~required () =
  Object { properties; required; description }

let string ?description () = String { description }
let number ?description () = Number { description }
let integer ?description () = Integer { description }
let boolean ?description () = Boolean { description }
let array ?description ~items () = Array { items; description }
let enum ?description values = Enum { values; description }
let const value = Const { value }
let any_of schemas = Any_of { schemas }
let optional schema = Any_of { schemas = [ schema; Const { value = `Null } ] }

(* ── to_json ─────────────────────────────────────────────────────────────── *)

let add_description description fields =
  match description with
  | None -> fields
  | Some d -> ("description", `String d) :: fields

let rec to_json = function
  | String { description } ->
      `Assoc (add_description description [ ("type", `String "string") ])
  | Number { description } ->
      `Assoc (add_description description [ ("type", `String "number") ])
  | Integer { description } ->
      `Assoc (add_description description [ ("type", `String "integer") ])
  | Boolean { description } ->
      `Assoc (add_description description [ ("type", `String "boolean") ])
  | Array { items; description } ->
      let fields = [ ("type", `String "array"); ("items", to_json items) ] in
      `Assoc (add_description description fields)
  | Enum { values; description } ->
      let fields =
        [
          ("type", `String "string");
          ("enum", `List (List.map (fun v -> `String v) values));
        ]
      in
      `Assoc (add_description description fields)
  | Const { value } -> `Assoc [ ("const", value) ]
  | Any_of { schemas } -> `Assoc [ ("anyOf", `List (List.map to_json schemas)) ]
  | Object { properties; required; description } ->
      let props_json =
        `Assoc
          (List.map (fun (name, schema) -> (name, to_json schema)) properties)
      in
      let fields =
        [
          ("type", `String "object");
          ("properties", props_json);
          ("required", `List (List.map (fun s -> `String s) required));
        ]
      in
      `Assoc (add_description description fields)

(* ── coercion helpers ────────────────────────────────────────────────────── *)

(** Attempt to coerce a primitive JSON value to match [schema_type]. Returns
    [Some coerced_value] if a coercion was applied, [None] if the value already
    has the correct type, and the original value unchanged if no applicable
    coercion rule exists.

    The coercion rules mirror Pi's [coercePrimitiveByType] in validation.ts. *)
let coerce_primitive (value : Yojson.Safe.t) (schema_type : string) :
    Yojson.Safe.t option =
  match (schema_type, value) with
  (* number coercions *)
  | "number", `Null -> Some (`Float 0.0)
  | "number", `Bool true -> Some (`Float 1.0)
  | "number", `Bool false -> Some (`Float 0.0)
  | "number", `String s -> (
      let s_trimmed = String.trim s in
      if String.is_empty s_trimmed then None
      else
        match float_of_string_opt s_trimmed with
        | Some f when Float.is_finite f -> Some (`Float f)
        | _ -> None)
  (* integer coercions *)
  | "integer", `Null -> Some (`Int 0)
  | "integer", `Bool true -> Some (`Int 1)
  | "integer", `Bool false -> Some (`Int 0)
  | "integer", `String s -> (
      let s_trimmed = String.trim s in
      if String.is_empty s_trimmed then None
      else
        match float_of_string_opt s_trimmed with
        | Some f when Float.is_integer f && Float.is_finite f ->
            Some (`Int (int_of_float f))
        | _ -> None)
  (* boolean coercions — only "true"/"false" strings accepted, not "1"/"0" *)
  | "boolean", `Null -> Some (`Bool false)
  | "boolean", `String "true" -> Some (`Bool true)
  | "boolean", `String "false" -> Some (`Bool false)
  | "boolean", `Int 1 -> Some (`Bool true)
  | "boolean", `Int 0 -> Some (`Bool false)
  | "boolean", `Float 1.0 -> Some (`Bool true)
  | "boolean", `Float 0.0 -> Some (`Bool false)
  (* string coercions *)
  | "string", `Null -> Some (`String "")
  | "string", `Bool true -> Some (`String "true")
  | "string", `Bool false -> Some (`String "false")
  | "string", `Int n -> Some (`String (string_of_int n))
  | "string", `Float f -> Some (`String (string_of_float f))
  (* null coercions — "" / 0 / false coerce to null; "null" does NOT *)
  | "null", `String "" -> Some `Null
  | "null", `Int 0 -> Some `Null
  | "null", `Float 0.0 -> Some `Null
  | "null", `Bool false -> Some `Null
  (* no applicable coercion *)
  | _ -> None

(** True if [value] already matches [schema_type] without coercion. *)
let matches_type (value : Yojson.Safe.t) (schema_type : string) : bool =
  match (schema_type, value) with
  | "string", `String _ -> true
  | "number", (`Int _ | `Float _) -> true
  | "integer", `Int _ -> true
  | "integer", `Float f -> Float.is_integer f
  | "boolean", `Bool _ -> true
  | "null", `Null -> true
  | "array", `List _ -> true
  | "object", `Assoc _ -> true
  | _ -> false

(** Apply coercion to [value] according to [schema_type]. Returns the (possibly
    coerced) value. *)
let apply_type_coercion (value : Yojson.Safe.t) (schema_type : string) :
    Yojson.Safe.t =
  if matches_type value schema_type then value
  else
    match coerce_primitive value schema_type with
    | Some coerced -> coerced
    | None -> value

(* ── validate ────────────────────────────────────────────────────────────── *)

(** Check that [value] (after coercion) matches the expected type. *)
let check_type (value : Yojson.Safe.t) (expected_type : string) :
    (unit, string) result =
  if matches_type value expected_type then Ok ()
  else
    Error
      (Fmt.str "expected type %s but got %s" expected_type
         (Yojson.Safe.to_string value))

let rec validate (schema : t) (value : Yojson.Safe.t) : (unit, string) result =
  match schema with
  | String _ ->
      let coerced = apply_type_coercion value "string" in
      check_type coerced "string"
  | Number _ ->
      let coerced = apply_type_coercion value "number" in
      check_type coerced "number"
  | Integer _ ->
      let coerced = apply_type_coercion value "integer" in
      check_type coerced "integer"
  | Boolean _ ->
      let coerced = apply_type_coercion value "boolean" in
      check_type coerced "boolean"
  | Array { items; _ } ->
      let coerced = apply_type_coercion value "array" in
      let open Result.Syntax in
      let* () = check_type coerced "array" in
      let items_list = match coerced with `List xs -> xs | _ -> [] in
      List.fold_left
        (fun acc item ->
          let* () = acc in
          validate items item)
        (Ok ()) items_list
  | Enum { values; _ } ->
      let coerced = apply_type_coercion value "string" in
      let open Result.Syntax in
      let* () = check_type coerced "string" in
      let s = match coerced with `String s -> s | _ -> "" in
      if List.mem ~eq:String.equal s values then Ok ()
      else
        Error
          (Fmt.str "value %S is not one of the allowed enum values: [%s]" s
             (String.concat ", " values))
  | Const { value = expected } ->
      if Yojson.Safe.equal value expected then Ok ()
      else
        Error
          (Fmt.str "expected const value %s but got %s"
             (Yojson.Safe.to_string expected)
             (Yojson.Safe.to_string value))
  | Any_of { schemas } ->
      let results = List.map (validate_schema_candidate value) schemas in
      if List.exists Result.is_ok results then Ok ()
      else
        Error
          (Fmt.str "value does not match any of the anyOf schemas: %s"
             (Yojson.Safe.to_string value))
  | Object { properties; required; _ } ->
      validate_object properties required value

and validate_schema_candidate (value : Yojson.Safe.t) (schema : t) :
    (unit, string) result =
  validate schema value

and validate_object (properties : (string * t) list) (required : string list)
    (value : Yojson.Safe.t) : (unit, string) result =
  let open Result.Syntax in
  let pairs =
    match value with
    | `Assoc ps -> ps
    | _ -> (
        let coerced = apply_type_coercion value "object" in
        match coerced with `Assoc ps -> ps | _ -> [])
  in
  (* Check that all required fields are present *)
  let* () =
    List.fold_left
      (fun acc field_name ->
        let* () = acc in
        if List.assoc_opt ~eq:String.equal field_name pairs |> Option.is_some
        then Ok ()
        else Error (Fmt.str "required field '%s' is missing" field_name))
      (Ok ()) required
  in
  (* Validate each present property that has a schema *)
  List.fold_left
    (fun acc (prop_name, prop_schema) ->
      let* () = acc in
      match List.assoc_opt ~eq:String.equal prop_name pairs with
      | None -> Ok ()
      | Some prop_value ->
          validate prop_schema prop_value
          |> Result.map_error (fun e -> Fmt.str "field '%s': %s" prop_name e))
    (Ok ()) properties
