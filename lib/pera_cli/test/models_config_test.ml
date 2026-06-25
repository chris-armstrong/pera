open Containers

(* Test 1: parse a minimal valid models sexp *)
let test_parse_minimal () =
  let sexp_str =
    {|((providers (((name anthropic) (api anthropic)
      (models (((name claude-sonnet-4-6) (context_window 200000)
                (max_tokens 16000))))))))|}
  in
  let mf =
    Pera_cli.Models_config.models_file_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check int) "one provider" 1 (List.length mf.providers);
  match mf.providers with
  | [ p ] ->
      Alcotest.(check string) "provider name" "anthropic" p.name;
      Alcotest.(check int) "one model" 1 (List.length p.models)
  | _ -> Alcotest.fail "expected exactly one provider"

(* Test 2: round-trip sexp_of then of_sexp *)
let test_round_trip () =
  let open Pera_cli.Models_config in
  let mf =
    {
      providers =
        [
          {
            name = "test";
            api = "test-api";
            api_key_env = None;
            base_url = None;
            base_url_env = None;
            compat = None;
            models =
              [
                {
                  name = "test-model";
                  context_window = 100000;
                  max_tokens = 8000;
                  thinking = None;
                };
              ];
          };
        ];
    }
  in
  let sexp = Pera_cli.Models_config.sexp_of_models_file mf in
  let mf' = Pera_cli.Models_config.models_file_of_sexp sexp in
  Alcotest.(check bool)
    "round-trip equal"
    (Pera_cli.Models_config.equal_models_file mf mf')
    true

(* Test 3: thinking_spec parsing *)
let test_thinking_spec () =
  let sexp_str =
    {|((providers (((name anthropic) (api anthropic)
      (models (((name claude-sonnet-4-6) (context_window 200000)
                (max_tokens 16000)
                (thinking ((budget_medium 4000) (budget_high 8000))))))))))|}
  in
  let mf =
    Pera_cli.Models_config.models_file_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  match mf.providers with
  | [ p ] -> (
      match p.models with
      | [ m ] -> (
          match m.thinking with
          | Some t ->
              Alcotest.(check int) "budget_medium" 4000 t.budget_medium;
              Alcotest.(check int) "budget_high" 8000 t.budget_high
          | None -> Alcotest.fail "expected thinking spec")
      | _ -> Alcotest.fail "expected exactly one model")
  | _ -> Alcotest.fail "expected exactly one provider"

(* Test 4: compat_config @sexp.option defaults *)
let test_compat_defaults () =
  let sexp_str =
    {|((providers (((name openai) (api openai-completions)
      (compat ((reasoning_field "reasoning_effort")))
      (models (((name gpt-4) (context_window 128000)
                (max_tokens 16000))))))))|}
  in
  let mf =
    Pera_cli.Models_config.models_file_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  match mf.providers with
  | [ p ] -> (
      match p.compat with
      | Some c ->
          Alcotest.(check (option string))
            "reasoning_field" (Some "reasoning_effort") c.reasoning_field;
          Alcotest.(check (option string))
            "max_tokens_field" None c.max_tokens_field;
          Alcotest.(check (option bool))
            "require_tool_result_name" None c.require_tool_result_name;
          Alcotest.(check (option string))
            "enable_thinking_field" None c.enable_thinking_field
      | None -> Alcotest.fail "expected compat config")
  | _ -> Alcotest.fail "expected exactly one provider"

let suite =
  [
    ("parse minimal models sexp", `Quick, test_parse_minimal);
    ("round-trip sexp_of then of_sexp", `Quick, test_round_trip);
    ("thinking_spec parsing", `Quick, test_thinking_spec);
    ("compat_config defaults", `Quick, test_compat_defaults);
  ]

let () = Alcotest.run "models_config" [ ("models_config", suite) ]
