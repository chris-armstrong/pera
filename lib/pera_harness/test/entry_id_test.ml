open Containers

let test_generate_returns_36_chars () =
  let id = Pera_harness.Entry_id.generate () in
  Alcotest.(check int) "length is 36" 36 (String.length id)

let test_generate_returns_lowercase_hex_and_hyphens () =
  let id = Pera_harness.Entry_id.generate () in
  let is_hex_or_hyphen c =
    (Char.compare c '0' >= 0 && Char.compare c '9' <= 0)
    || (Char.compare c 'a' >= 0 && Char.compare c 'f' <= 0)
    || Char.equal c '-'
  in
  Alcotest.(check bool) "only lowercase hex and hyphens" true
    (String.for_all is_hex_or_hyphen id);
  (* UUIDv7: position 14 must be '7' (version nibble),
     position 19 must be in [89ab] (variant bits) *)
  Alcotest.(check char) "version nibble is 7" '7' (String.get id 14);
  let variant = String.get id 19 in
  Alcotest.(check bool) "variant nibble is [89ab]" true
    (List.mem ~eq:Char.equal variant [ '8'; '9'; 'a'; 'b' ])

let test_generate_ids_are_unique () =
  let ids = List.init 1000 (fun _ -> Pera_harness.Entry_id.generate ()) in
  let seen = Hashtbl.create 1000 in
  let all_unique = List.for_all (fun id ->
    if Hashtbl.mem seen id then false
    else (Hashtbl.add seen id (); true)) ids in
  Alcotest.(check bool) "1000 ids are distinct" true all_unique

let consecutive_pairs = function
  | [] | [_] -> []
  | lst ->
    let n = List.length lst - 1 in
    List.init n (fun i -> (List.nth lst i, List.nth lst (i + 1)))

let test_generate_ids_are_lexicographically_ordered_over_time () =
  let ids = List.init 10 (fun _ ->
    let id = Pera_harness.Entry_id.generate () in
    Unix.sleepf 0.002;
    id) in
  let pairs = consecutive_pairs ids in
  let inversions =
    List.length (List.filter (fun (a, b) -> String.compare a b > 0) pairs)
  in
  (* Allow at most 1 inversion for clock skew tolerance *)
  Alcotest.(check bool) "at most 1 inversion" true (inversions <= 1)

let () =
  Alcotest.run "entry_id"
    [
      ( "entry_id",
        [
          Alcotest.test_case "returns 36 chars" `Quick test_generate_returns_36_chars;
          Alcotest.test_case "lowercase hex and hyphens" `Quick test_generate_returns_lowercase_hex_and_hyphens;
          Alcotest.test_case "1000 ids are unique" `Quick test_generate_ids_are_unique;
          Alcotest.test_case "lexicographic order over time" `Quick test_generate_ids_are_lexicographically_ordered_over_time;
        ] );
    ]
