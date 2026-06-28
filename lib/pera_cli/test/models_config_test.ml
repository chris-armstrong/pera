open Containers

(* Test 1: parse a minimal valid models sexp *)
let test_parse_minimal () =
  let sexp_str =
    {|((providers (((name anthropic) (protocol anthropic)
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
            protocol = "test-api";
            api_key_env = [];
            api = None;
            base_url_env = None;
            compat = None;
            models =
              [
                {
                  name = "test-model";
                  context_window = 100000;
                  max_tokens = 8000;
                  thinking = None;
                  cost = None;
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
    {|((providers (((name anthropic) (protocol anthropic)
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
    {|((providers (((name openai) (protocol openai-completions)
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

(* Test 5: model_cost round-trip through sexp *)
let test_model_cost_round_trip () =
  let open Pera_cli.Models_config in
  let cost =
    {
      input_per_mtok = Decimal.of_string "3.00";
      output_per_mtok = Decimal.of_string "15.00";
      cache_read_per_mtok = Some (Decimal.of_string "0.30");
      cache_write_per_mtok = Some (Decimal.of_string "3.75");
    }
  in
  let sexp = Pera_cli.Models_config.sexp_of_model_cost cost in
  let cost' = Pera_cli.Models_config.model_cost_of_sexp sexp in
  Alcotest.(check bool)
    "round-trip equal"
    (Pera_cli.Models_config.equal_model_cost cost cost')
    true

(* Test 6: "3.00" atom parses to Decimal.(of_string "3.00") *)
let test_decimal_parsing () =
  let sexp_str = {|((input_per_mtok "3.00") (output_per_mtok "15.00"))|} in
  let cost = Pera_cli.Models_config.model_cost_of_sexp
      (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check string)
    "decimal value" "3.00"
    (Decimal.to_string cost.Pera_cli.Models_config.input_per_mtok)

(* Test 7: "0.30" atom parses correctly — no float rounding loss *)
let test_decimal_no_rounding () =
  let sexp_str = {|((input_per_mtok "0.30") (output_per_mtok "15.00"))|} in
  let cost = Pera_cli.Models_config.model_cost_of_sexp
      (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check string)
    "decimal value" "0.30"
    (Decimal.to_string cost.Pera_cli.Models_config.input_per_mtok)

(* Test 8: cache fields absent in sexp parse to None *)
let test_cost_cache_defaults () =
  let sexp_str =
    {|((input_per_mtok "3.00") (output_per_mtok "15.00"))|}
  in
  let cost = Pera_cli.Models_config.model_cost_of_sexp
      (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check (option string))
    "cache_read absent" None
    (Option.map Decimal.to_string cost.Pera_cli.Models_config.cache_read_per_mtok);
  Alcotest.(check (option string))
    "cache_write absent" None
    (Option.map Decimal.to_string cost.Pera_cli.Models_config.cache_write_per_mtok)

(* Test 9: cost absent in model_spec sexp parses to None *)
let test_model_cost_absent () =
  let sexp_str =
    {|((providers (((name anthropic) (protocol anthropic)
      (models (((name claude-sonnet-4-6) (context_window 200000)
                (max_tokens 16000))))))))|}
  in
  let mf =
    Pera_cli.Models_config.models_file_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  match mf.providers with
  | [ p ] -> (
      match p.models with
      | [ m ] ->
          Alcotest.(check (option string))
            "cost absent" None
            (Option.map
               (fun _ -> "present")
               m.Pera_cli.Models_config.cost)
      | _ -> Alcotest.fail "expected exactly one model")
  | _ -> Alcotest.fail "expected exactly one provider"

(* Test 10: model_spec with cost present round-trips *)
let test_model_with_cost_round_trip () =
  let open Pera_cli.Models_config in
  let m =
    {
      name = "claude-sonnet-4-6";
      context_window = 200000;
      max_tokens = 16000;
      thinking = None;
      cost =
        Some
          {
            input_per_mtok = Decimal.of_string "3.00";
            output_per_mtok = Decimal.of_string "15.00";
            cache_read_per_mtok = None;
            cache_write_per_mtok = None;
          };
    }
  in
  let sexp = Pera_cli.Models_config.sexp_of_model_spec m in
  let m' = Pera_cli.Models_config.model_spec_of_sexp sexp in
  Alcotest.(check bool)
    "round-trip equal"
    (Pera_cli.Models_config.equal_model_spec m m')
    true

(* Test 11: api_key_env as string list *)
let test_api_key_env_list () =
  let sexp_str =
    {|((providers (((name github) (protocol openai-completions)
      (api_key_env (GITHUB_TOKEN GH_TOKEN))
      (models (((name gpt-4) (context_window 128000)
                (max_tokens 16000))))))))|}
  in
  let mf =
    Pera_cli.Models_config.models_file_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  match mf.providers with
  | [ p ] ->
      Alcotest.(check (list string))
        "api_key_env list" [ "GITHUB_TOKEN"; "GH_TOKEN" ]
        p.Pera_cli.Models_config.api_key_env
  | _ -> Alcotest.fail "expected exactly one provider"

(* Test 12: api field (base URL) parses correctly *)
let test_api_field () =
  let sexp_str =
    {|((providers (((name ollama) (protocol openai-completions)
      (api "http://localhost:11434/v1")
      (models (((name llama3) (context_window 8192)
                (max_tokens 4096))))))))|}
  in
  let mf =
    Pera_cli.Models_config.models_file_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  match mf.providers with
  | [ p ] ->
      Alcotest.(check (option string))
        "api base URL" (Some "http://localhost:11434/v1") p.api
  | _ -> Alcotest.fail "expected exactly one provider"

let suite =
  [
    ("parse minimal models sexp", `Quick, test_parse_minimal);
    ("round-trip sexp_of then of_sexp", `Quick, test_round_trip);
    ("thinking_spec parsing", `Quick, test_thinking_spec);
    ("compat_config defaults", `Quick, test_compat_defaults);
    ("model_cost round-trip", `Quick, test_model_cost_round_trip);
    ("decimal parsing", `Quick, test_decimal_parsing);
    ("decimal no rounding", `Quick, test_decimal_no_rounding);
    ("cost cache defaults", `Quick, test_cost_cache_defaults);
    ("cost absent in model_spec", `Quick, test_model_cost_absent);
    ("model with cost round-trip", `Quick, test_model_with_cost_round_trip);
    ("api_key_env as string list", `Quick, test_api_key_env_list);
    ("api field (base URL)", `Quick, test_api_field);
  ]

let () = Alcotest.run "models_config" [ ("models_config", suite) ]
