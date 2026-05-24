open Containers
open Pera_provider

(* ── helpers ────────────────────────────────────────────────────────────── *)

let result_testable =
  Alcotest.testable
    (fun ppf -> function
      | Ok () -> Format.pp_print_string ppf "Ok ()"
      | Error msg -> Format.fprintf ppf "Error %S" msg)
    (fun a b ->
      match (a, b) with
      | Ok (), Ok () -> true
      | Error a, Error b -> String.equal a b
      | _ -> false)

let is_error = function Error _ -> true | Ok _ -> false

(* ── test_validate_coerces_string_to_integer ─────────────────────────────── *)

(** Port of Pi validation.test.ts coercion case: string "42" validates against
    an integer schema. *)
let test_validate_coerces_string_to_integer () =
  let schema = Json_schema.integer () in
  let value = `String "42" in
  let result = Json_schema.validate schema value in
  Alcotest.check result_testable "string '42' coerces to integer" (Ok ()) result

(* ── test_validate_coerces_string_to_boolean ─────────────────────────────── *)

(** Port of Pi validation.test.ts coercion case: string "true" validates against
    a boolean schema. *)
let test_validate_coerces_string_to_boolean () =
  let schema = Json_schema.boolean () in
  let value = `String "true" in
  let result = Json_schema.validate schema value in
  Alcotest.check result_testable "string 'true' coerces to boolean" (Ok ())
    result

(* ── test_validate_rejects_invalid_integer_coercion ─────────────────────── *)

(** Port of Pi rejection case: the string "1" is NOT accepted by a boolean
    schema (only "true" / "false" coerce to boolean). *)
let test_validate_rejects_invalid_integer_coercion () =
  let schema = Json_schema.boolean () in
  let value = `String "1" in
  let result = Json_schema.validate schema value in
  Alcotest.(check bool)
    "string '1' is rejected by boolean schema" true (is_error result)

(* ── test_to_json_renders_object_schema ──────────────────────────────────── *)

(** An object schema with required and optional fields must render as a valid
    JSON Schema draft-07 fragment with "type", "properties", and "required"
    keys. *)
let test_to_json_renders_object_schema () =
  let schema =
    Json_schema.object_
      ~properties:
        [
          ("name", Json_schema.string ());
          ("age", Json_schema.integer ());
          ("notes", Json_schema.optional (Json_schema.string ()));
        ]
      ~required:[ "name"; "age" ] ()
  in
  let json = Json_schema.to_json schema in
  (* Must be an object *)
  let assoc =
    match json with
    | `Assoc pairs -> pairs
    | _ -> Alcotest.fail "to_json did not return a JSON object"
  in
  let get key =
    List.assoc_opt ~eq:String.equal key assoc
    |> Option.get_exn_or (Fmt.str "to_json result missing key '%s'" key)
  in
  (* "type": "object" *)
  Alcotest.(check string)
    "type field" "object"
    (match get "type" with `String s -> s | _ -> "");
  (* "properties" is an object *)
  (match get "properties" with
  | `Assoc props ->
      let has_prop name =
        List.assoc_opt ~eq:String.equal name props |> Option.is_some
      in
      Alcotest.(check bool) "properties has 'name'" true (has_prop "name");
      Alcotest.(check bool) "properties has 'age'" true (has_prop "age");
      Alcotest.(check bool) "properties has 'notes'" true (has_prop "notes")
  | _ -> Alcotest.fail "'properties' is not a JSON object");
  (* "required" contains exactly the required fields *)
  match get "required" with
  | `List items ->
      let names =
        List.filter_map (function `String s -> Some s | _ -> None) items
      in
      Alcotest.(check bool)
        "required contains 'name'" true
        (List.mem ~eq:String.equal "name" names);
      Alcotest.(check bool)
        "required contains 'age'" true
        (List.mem ~eq:String.equal "age" names);
      Alcotest.(check bool)
        "required does not contain 'notes'" false
        (List.mem ~eq:String.equal "notes" names)
  | _ -> Alcotest.fail "'required' is not a JSON array"

(* ── test_validate_required_field_missing ───────────────────────────────── *)

(** An object schema with a required field must reject a value that omits it. *)
let test_validate_required_field_missing () =
  let schema =
    Json_schema.object_
      ~properties:[ ("name", Json_schema.string ()) ]
      ~required:[ "name" ] ()
  in
  let empty_object = `Assoc [] in
  let result = Json_schema.validate schema empty_object in
  Alcotest.(check bool)
    "empty object rejected when required field is missing" true
    (is_error result)

(* ── additional coercion coverage from Pi's validation.test.ts ────────────
   These are not in the 5 mandatory tests but are called out in the plan as
   "14 coercion cases and 4 rejection cases to replicate". *)

let test_validate_coerces_string_false_to_boolean () =
  let schema = Json_schema.boolean () in
  Alcotest.check result_testable "string 'false' coerces to boolean" (Ok ())
    (Json_schema.validate schema (`String "false"))

let test_validate_coerces_int_one_to_boolean () =
  let schema = Json_schema.boolean () in
  Alcotest.check result_testable "integer 1 coerces to boolean" (Ok ())
    (Json_schema.validate schema (`Int 1))

let test_validate_coerces_int_zero_to_boolean () =
  let schema = Json_schema.boolean () in
  Alcotest.check result_testable "integer 0 coerces to boolean" (Ok ())
    (Json_schema.validate schema (`Int 0))

let test_validate_coerces_null_to_boolean () =
  let schema = Json_schema.boolean () in
  Alcotest.check result_testable "null coerces to boolean" (Ok ())
    (Json_schema.validate schema `Null)

let test_validate_coerces_string_to_number () =
  let schema = Json_schema.number () in
  Alcotest.check result_testable "string '42' coerces to number" (Ok ())
    (Json_schema.validate schema (`String "42"))

let test_validate_coerces_bool_to_number () =
  let schema = Json_schema.number () in
  Alcotest.check result_testable "true coerces to number" (Ok ())
    (Json_schema.validate schema (`Bool true))

let test_validate_coerces_null_to_number () =
  let schema = Json_schema.number () in
  Alcotest.check result_testable "null coerces to number" (Ok ())
    (Json_schema.validate schema `Null)

let test_validate_coerces_null_to_string () =
  let schema = Json_schema.string () in
  Alcotest.check result_testable "null coerces to string" (Ok ())
    (Json_schema.validate schema `Null)

let test_validate_coerces_bool_to_string () =
  let schema = Json_schema.string () in
  Alcotest.check result_testable "true coerces to string" (Ok ())
    (Json_schema.validate schema (`Bool true))

(* Rejection cases from Pi *)

let test_validate_rejects_string_zero_to_boolean () =
  let schema = Json_schema.boolean () in
  Alcotest.(check bool)
    "string '0' rejected by boolean schema" true
    (is_error (Json_schema.validate schema (`String "0")))

let test_validate_rejects_string_null_to_null () =
  (* The string "null" does NOT coerce to JSON null *)
  let schema =
    Json_schema.object_
      ~properties:[ ("v", Json_schema.const `Null) ]
      ~required:[ "v" ] ()
  in
  let value = `Assoc [ ("v", `String "null") ] in
  Alcotest.(check bool)
    "string 'null' rejected by null const schema" true
    (is_error (Json_schema.validate schema value))

let test_validate_rejects_float_string_to_integer () =
  let schema = Json_schema.integer () in
  Alcotest.(check bool)
    "string '42.1' rejected by integer schema" true
    (is_error (Json_schema.validate schema (`String "42.1")))

(* ── test suite ─────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "json_schema"
    [
      ( "mandatory",
        [
          Alcotest.test_case "validate_coerces_string_to_integer" `Quick
            test_validate_coerces_string_to_integer;
          Alcotest.test_case "validate_coerces_string_to_boolean" `Quick
            test_validate_coerces_string_to_boolean;
          Alcotest.test_case "validate_rejects_invalid_integer_coercion" `Quick
            test_validate_rejects_invalid_integer_coercion;
          Alcotest.test_case "to_json_renders_object_schema" `Quick
            test_to_json_renders_object_schema;
          Alcotest.test_case "validate_required_field_missing" `Quick
            test_validate_required_field_missing;
        ] );
      ( "coercion_coverage",
        [
          Alcotest.test_case "coerces_string_false_to_boolean" `Quick
            test_validate_coerces_string_false_to_boolean;
          Alcotest.test_case "coerces_int_one_to_boolean" `Quick
            test_validate_coerces_int_one_to_boolean;
          Alcotest.test_case "coerces_int_zero_to_boolean" `Quick
            test_validate_coerces_int_zero_to_boolean;
          Alcotest.test_case "coerces_null_to_boolean" `Quick
            test_validate_coerces_null_to_boolean;
          Alcotest.test_case "coerces_string_to_number" `Quick
            test_validate_coerces_string_to_number;
          Alcotest.test_case "coerces_bool_to_number" `Quick
            test_validate_coerces_bool_to_number;
          Alcotest.test_case "coerces_null_to_number" `Quick
            test_validate_coerces_null_to_number;
          Alcotest.test_case "coerces_null_to_string" `Quick
            test_validate_coerces_null_to_string;
          Alcotest.test_case "coerces_bool_to_string" `Quick
            test_validate_coerces_bool_to_string;
        ] );
      ( "rejection_coverage",
        [
          Alcotest.test_case "rejects_string_zero_to_boolean" `Quick
            test_validate_rejects_string_zero_to_boolean;
          Alcotest.test_case "rejects_string_null_to_null" `Quick
            test_validate_rejects_string_null_to_null;
          Alcotest.test_case "rejects_float_string_to_integer" `Quick
            test_validate_rejects_float_string_to_integer;
        ] );
    ]
