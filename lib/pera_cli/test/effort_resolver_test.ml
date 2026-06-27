open Containers

let make_model ~name ?thinking () =
  Pera_cli.Models_config.
    { name; context_window = 200000; max_tokens = 16000; thinking }

let make_thinking ~medium ~high =
  Pera_cli.Models_config.{ budget_medium = medium; budget_high = high }

let test_low_no_thinking () =
  let model = make_model ~name:"m" () in
  match
    Pera_cli.Effort_resolver.resolve ~effort:Pera_cli.Pera_config.Low
      ~model_spec:model
  with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "expected None for Low effort"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_low_with_thinking () =
  let model =
    make_model ~name:"m" ~thinking:(make_thinking ~medium:8000 ~high:32000) ()
  in
  match
    Pera_cli.Effort_resolver.resolve ~effort:Pera_cli.Pera_config.Low
      ~model_spec:model
  with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "expected None for Low effort"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_medium_with_thinking () =
  let model =
    make_model ~name:"m" ~thinking:(make_thinking ~medium:8000 ~high:32000) ()
  in
  match
    Pera_cli.Effort_resolver.resolve ~effort:Pera_cli.Pera_config.Medium
      ~model_spec:model
  with
  | Ok (Some 8000) -> ()
  | Ok (Some n) -> Alcotest.failf "expected 8000, got %d" n
  | Ok None -> Alcotest.fail "expected Some budget"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_high_with_thinking () =
  let model =
    make_model ~name:"m" ~thinking:(make_thinking ~medium:8000 ~high:32000) ()
  in
  match
    Pera_cli.Effort_resolver.resolve ~effort:Pera_cli.Pera_config.High
      ~model_spec:model
  with
  | Ok (Some 32000) -> ()
  | Ok (Some n) -> Alcotest.failf "expected 32000, got %d" n
  | Ok None -> Alcotest.fail "expected Some budget"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_medium_without_thinking () =
  let model = make_model ~name:"no-think" () in
  match
    Pera_cli.Effort_resolver.resolve ~effort:Pera_cli.Pera_config.Medium
      ~model_spec:model
  with
  | Error e ->
      Alcotest.(check bool)
        "error mentions model name" true
        (String.mem ~sub:"no-think" e)
  | Ok _ -> Alcotest.fail "expected Error"

let test_high_without_thinking () =
  let model = make_model ~name:"no-think" () in
  match
    Pera_cli.Effort_resolver.resolve ~effort:Pera_cli.Pera_config.High
      ~model_spec:model
  with
  | Error e ->
      Alcotest.(check bool)
        "error mentions model name" true
        (String.mem ~sub:"no-think" e)
  | Ok _ -> Alcotest.fail "expected Error"

let suite =
  [
    ("Low → None for model without thinking", `Quick, test_low_no_thinking);
    ("Low → None for model with thinking", `Quick, test_low_with_thinking);
    ( "Medium → Some budget_medium for thinking model",
      `Quick,
      test_medium_with_thinking );
    ( "High → Some budget_high for thinking model",
      `Quick,
      test_high_with_thinking );
    ( "Medium → Error for non-thinking model",
      `Quick,
      test_medium_without_thinking );
    ("High → Error for non-thinking model", `Quick, test_high_without_thinking);
  ]

let () = Alcotest.run "effort_resolver" [ ("effort_resolver", suite) ]
