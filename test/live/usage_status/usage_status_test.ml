open Containers

let usage
    ?(input_tokens = 0)
    ?(output_tokens = 0)
    ?(cache_read_tokens = 0)
    ?(cache_write_tokens = 0)
    ?cost_usd
    () : Pera_types.Types.usage =
  Pera_types.Types.
    { input_tokens; output_tokens; cache_read_tokens; cache_write_tokens; cost_usd }

let test_all_zero () =
  Alcotest.(check string) "all-zero usage"
    "in=0 out=0 cache_read=0 cache_write=0"
    (Usage_status.format (usage ()))

let test_cache_write_populated () =
  let u =
    usage ~input_tokens:12 ~output_tokens:5 ~cache_read_tokens:0
      ~cache_write_tokens:1024 ()
  in
  Alcotest.(check string) "cache write populated"
    "in=12 out=5 cache_read=0 cache_write=1024" (Usage_status.format u)

let test_cache_read_populated () =
  let u =
    usage ~input_tokens:2000 ~output_tokens:1 ~cache_read_tokens:1920
      ~cache_write_tokens:0 ()
  in
  Alcotest.(check string) "cache read populated"
    "in=2000 out=1 cache_read=1920 cache_write=0" (Usage_status.format u)

let test_no_cost_suffix_when_absent () =
  let s = Usage_status.format (usage ()) in
  Alcotest.(check bool) "no cost suffix when absent" false
    (String.contains s '$')

let test_cost_suffix_when_present () =
  let u = usage ~input_tokens:10 ~output_tokens:3 ~cost_usd:(Decimal.of_string "0.0021") () in
  Alcotest.(check string) "cost suffix when present"
    "in=10 out=3 cache_read=0 cache_write=0 cost=$0.0021"
    (Usage_status.format u)

let () =
  Alcotest.run "usage_status"
    [
      ("all_zero", [ Alcotest.test_case "format" `Quick test_all_zero ]);
      ("cache_write_populated", [
        Alcotest.test_case "format" `Quick test_cache_write_populated;
      ]);
      ("cache_read_populated", [
        Alcotest.test_case "format" `Quick test_cache_read_populated;
      ]);
      ("no_cost_suffix_when_absent", [
        Alcotest.test_case "format" `Quick test_no_cost_suffix_when_absent;
      ]);
      ("cost_suffix_when_present", [
        Alcotest.test_case "format" `Quick test_cost_suffix_when_present;
      ]);
    ]