open Containers

let yojson_testable =
  Alcotest.testable
    (fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v))
    (fun a b ->
      String.equal (Yojson.Safe.to_string a) (Yojson.Safe.to_string b))

let test_repair_invalid_backslash_escape () =
  (* JSON with \H is repaired to \\H, making it parseable *)
  let input = {|{"path":"A\H"}|} in
  let repaired = Pera_provider.Json_repair.repair input in
  let json =
    match Yojson.Safe.from_string repaired with
    | exception _ ->
        Alcotest.failf "repair did not produce valid JSON; repaired = %s"
          repaired
    | v -> v
  in
  let path_value =
    match json with
    | `Assoc fields ->
        List.assoc_opt ~eq:String.equal "path" fields
        |> Option.get_exn_or "expected 'path' field in parsed JSON"
    | _ -> Alcotest.fail "expected JSON object"
  in
  match path_value with
  | `String s ->
      Alcotest.(check string) "path value contains backslash-H" "A\\H" s
  | _ -> Alcotest.fail "expected string value for 'path'"

let test_repair_raw_tab_character () =
  (* JSON containing a literal 0x09 byte inside a string is repaired to \t *)
  let input = "{\"text\":\"col1\tcol2\"}" in
  let repaired = Pera_provider.Json_repair.repair input in
  let () =
    match Yojson.Safe.from_string repaired with
    | exception _ ->
        Alcotest.failf "repair did not produce valid JSON; repaired = %s"
          repaired
    | _ -> ()
  in
  (* The repaired string should contain \t escape, not a raw tab *)
  let contains_raw_tab = String.exists (fun c -> Char.equal c '\t') repaired in
  Alcotest.(check bool)
    "repaired string does not contain raw tab" false contains_raw_tab;
  let contains_tab_escape = String.mem ~sub:"\\t" repaired in
  Alcotest.(check bool)
    "repaired string contains \\t escape sequence" true contains_tab_escape

let test_repair_does_not_corrupt_valid_json () =
  let input = {|{"a":"hello world"}|} in
  let repaired = Pera_provider.Json_repair.repair input in
  Alcotest.(check string) "valid JSON unchanged" input repaired

let test_repair_preserves_valid_unicode_escape () =
  let input = {|{"a":"\u0041"}|} in
  let repaired = Pera_provider.Json_repair.repair input in
  Alcotest.(check string) "unicode escape preserved" input repaired

let test_parse_streaming_returns_ok_on_valid_json () =
  let result = Pera_provider.Json_repair.parse_streaming (Some {|{"k":1}|}) in
  let expected = `Assoc [ ("k", `Int 1) ] in
  Alcotest.(check (result yojson_testable string))
    "parse result" (Ok expected) result

let test_parse_streaming_repairs_and_returns_ok () =
  (* JSON with invalid escape \H should be repaired and parse successfully *)
  let input = Some {|{"path":"A\H"}|} in
  let result = Pera_provider.Json_repair.parse_streaming input in
  match result with
  | Error msg -> Alcotest.failf "expected Ok after repair but got Error: %s" msg
  | Ok json -> (
      let path_value =
        match json with
        | `Assoc fields ->
            List.assoc_opt ~eq:String.equal "path" fields
            |> Option.get_exn_or "expected 'path' field"
        | _ -> Alcotest.fail "expected JSON object"
      in
      match path_value with
      | `String s ->
          Alcotest.(check string) "path value repaired correctly" "A\\H" s
      | _ -> Alcotest.fail "expected string value for 'path'")

let () =
  Alcotest.run "Json_repair"
    [
      ( "repair",
        [
          Alcotest.test_case "invalid_backslash_escape" `Quick
            test_repair_invalid_backslash_escape;
          Alcotest.test_case "raw_tab_character" `Quick
            test_repair_raw_tab_character;
          Alcotest.test_case "does_not_corrupt_valid_json" `Quick
            test_repair_does_not_corrupt_valid_json;
          Alcotest.test_case "preserves_valid_unicode_escape" `Quick
            test_repair_preserves_valid_unicode_escape;
        ] );
      ( "parse_streaming",
        [
          Alcotest.test_case "returns_ok_on_valid_json" `Quick
            test_parse_streaming_returns_ok_on_valid_json;
          Alcotest.test_case "repairs_and_returns_ok" `Quick
            test_parse_streaming_repairs_and_returns_ok;
        ] );
    ]
