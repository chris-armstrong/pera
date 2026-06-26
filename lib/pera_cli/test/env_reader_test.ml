open Containers

let env_of alist k = List.assoc_opt ~eq:String.equal k alist

let test_api_key_key () =
  match
    Pera_cli.Env_reader.read_api_key_override
      ~getenv_opt:(env_of [ ("PERA_API_KEY", "my-key") ])
  with
  | Ok (Pera_cli.Env_reader.AK_key "my-key") -> ()
  | Ok _ -> Alcotest.fail "expected AK_key"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_api_key_file () =
  match
    Pera_cli.Env_reader.read_api_key_override
      ~getenv_opt:(env_of [ ("PERA_API_KEY_FILE", "/path/to/key") ])
  with
  | Ok (Pera_cli.Env_reader.AK_file "/path/to/key") -> ()
  | Ok _ -> Alcotest.fail "expected AK_file"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_api_key_command () =
  match
    Pera_cli.Env_reader.read_api_key_override
      ~getenv_opt:
        (env_of [ ("PERA_API_KEY_COMMAND", "security find-generic-password") ])
  with
  | Ok (Pera_cli.Env_reader.AK_command [ "security"; "find-generic-password" ])
    ->
      ()
  | Ok _ -> Alcotest.fail "expected AK_command with correct tokens"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_api_key_none () =
  match Pera_cli.Env_reader.read_api_key_override ~getenv_opt:(env_of []) with
  | Ok Pera_cli.Env_reader.AK_none -> ()
  | Ok _ -> Alcotest.fail "expected AK_none"
  | Error e -> Alcotest.failf "unexpected error: %s" e

let test_api_key_multiple_errors () =
  match
    Pera_cli.Env_reader.read_api_key_override
      ~getenv_opt:
        (env_of [ ("PERA_API_KEY", "k"); ("PERA_API_KEY_FILE", "/f") ])
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for multiple API key vars"

let test_partial_config_effort () =
  let cfg =
    Pera_cli.Env_reader.read_partial_config
      ~getenv_opt:(env_of [ ("PERA_EFFORT", "medium") ])
  in
  Alcotest.(check (option string)) "no model" None cfg.default_model;
  match cfg.effort with
  | Some Pera_cli.Pera_config.Medium -> ()
  | _ -> Alcotest.fail "expected Medium effort"

let test_partial_config_cache_policy () =
  let cfg =
    Pera_cli.Env_reader.read_partial_config
      ~getenv_opt:(env_of [ ("PERA_CACHE_POLICY", "conversation") ])
  in
  match cfg.cache with
  | Some { policy = Some Pera_cli.Pera_config.Conversation; _ } -> ()
  | _ -> Alcotest.fail "expected Conversation cache policy"

let test_partial_config_no_compact () =
  let cfg =
    Pera_cli.Env_reader.read_partial_config
      ~getenv_opt:(env_of [ ("PERA_NO_COMPACT", "1") ])
  in
  match cfg.compaction with
  | Some { enabled = Some false; _ } -> ()
  | _ -> Alcotest.fail "expected compaction disabled"

let test_partial_config_empty () =
  let cfg = Pera_cli.Env_reader.read_partial_config ~getenv_opt:(env_of []) in
  Alcotest.(check (option string)) "no model" None cfg.default_model;
  Alcotest.(check (option string))
    "no effort" None
    (Option.map Pera_cli.Pera_config.show_effort cfg.effort);
  Alcotest.(check (option int)) "no max_tokens" None cfg.max_tokens

let suite =
  [
    ("PERA_API_KEY → AK_key", `Quick, test_api_key_key);
    ("PERA_API_KEY_FILE → AK_file", `Quick, test_api_key_file);
    ("PERA_API_KEY_COMMAND → AK_command", `Quick, test_api_key_command);
    ("no API key vars → AK_none", `Quick, test_api_key_none);
    ("multiple API key vars → Error", `Quick, test_api_key_multiple_errors);
    ("PERA_EFFORT → effort field", `Quick, test_partial_config_effort);
    ( "PERA_CACHE_POLICY → cache.policy",
      `Quick,
      test_partial_config_cache_policy );
    ( "PERA_NO_COMPACT → compaction.enabled=false",
      `Quick,
      test_partial_config_no_compact );
    ("empty env → empty partial config", `Quick, test_partial_config_empty);
  ]

let () = Alcotest.run "env_reader" [ ("env_reader", suite) ]
