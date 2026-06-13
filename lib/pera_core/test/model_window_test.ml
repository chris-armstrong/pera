open Pera_core

let test_anthropic_window () =
  let model = Pera_types.Types.{ id = "claude-haiku-4-5-20251001"; api = "anthropic" } in
  Alcotest.(check int) "anthropic window" 200_000 (Model_window.for_model model)

let test_openai_window () =
  let model = Pera_types.Types.{ id = "gpt-4o"; api = "openai-completions" } in
  Alcotest.(check int) "openai window" 128_000 (Model_window.for_model model)

let test_unknown_defaults () =
  let model = Pera_types.Types.{ id = "weird"; api = "weird" } in
  Alcotest.(check int) "unknown window defaults to 200_000" 200_000
    (Model_window.for_model model)

let test_default_trigger_tokens () =
  let model = Pera_types.Types.{ id = "claude-haiku-4-5-20251001"; api = "anthropic" } in
  Alcotest.(check int) "default trigger tokens" 140_000
    (Model_window.default_trigger_tokens model)

let () =
  Alcotest.run "model_window"
    [
      ( "for_model",
        [
          Alcotest.test_case "anthropic_window" `Quick test_anthropic_window;
          Alcotest.test_case "openai_window" `Quick test_openai_window;
          Alcotest.test_case "unknown_defaults" `Quick test_unknown_defaults;
        ] );
      ( "default_trigger_tokens",
        [
          Alcotest.test_case "default_trigger_tokens" `Quick test_default_trigger_tokens;
        ] );
    ]
