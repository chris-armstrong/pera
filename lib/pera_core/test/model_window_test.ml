open Pera_core

let test_for_model_returns_field () =
  let model =
    Pera_types.Types.
      { id = "claude-haiku-4-5-20251001"; api = "anthropic"; context_window = 200_000 }
  in
  Alcotest.(check int) "context_window field" 200_000 (Model_window.for_model model)

let test_for_model_respects_variant () =
  (* Same id family, different variant: M-token window must round-trip. *)
  let model =
    Pera_types.Types.
      {
        id = "claude-opus-4-7";
        api = "anthropic";
        context_window = 1_000_000;
      }
  in
  Alcotest.(check int) "1M variant" 1_000_000 (Model_window.for_model model)

let test_for_model_openai_compatible () =
  let small_local =
    Pera_types.Types.{ id = "llama-3-8b"; api = "openai-completions"; context_window = 8_192 }
  in
  let gpt4o =
    Pera_types.Types.{ id = "gpt-4o"; api = "openai-completions"; context_window = 128_000 }
  in
  Alcotest.(check int) "8K llama" 8_192 (Model_window.for_model small_local);
  Alcotest.(check int) "128K gpt-4o" 128_000 (Model_window.for_model gpt4o)

let test_default_trigger_tokens () =
  let model =
    Pera_types.Types.
      { id = "claude-haiku-4-5-20251001"; api = "anthropic"; context_window = 200_000 }
  in
  Alcotest.(check int) "default trigger tokens" 140_000
    (Model_window.default_trigger_tokens model)

let test_default_trigger_tokens_custom_ratio () =
  let model =
    Pera_types.Types.{ id = "tiny"; api = "openai-completions"; context_window = 8_192 }
  in
  Alcotest.(check int) "50% ratio" 4_096
    (Model_window.default_trigger_tokens ~ratio:0.5 model)

let () =
  Alcotest.run "model_window"
    [
      ( "for_model",
        [
          Alcotest.test_case "returns_field" `Quick test_for_model_returns_field;
          Alcotest.test_case "respects_variant" `Quick test_for_model_respects_variant;
          Alcotest.test_case "openai_compatible" `Quick test_for_model_openai_compatible;
        ] );
      ( "default_trigger_tokens",
        [
          Alcotest.test_case "default" `Quick test_default_trigger_tokens;
          Alcotest.test_case "custom_ratio" `Quick test_default_trigger_tokens_custom_ratio;
        ] );
    ]
