open Containers

let anthropic_model =
  Pera_cli.Models_config.
    {
      name = "claude-sonnet-4-6";
      context_window = 200000;
      max_tokens = 16000;
      thinking = None;
      cost = None;
    }

let thinking_model =
  Pera_cli.Models_config.
    {
      name = "claude-think";
      context_window = 200000;
      max_tokens = 16000;
      thinking = Some { budget_medium = 8000; budget_high = 32000 };
      cost = None;
    }

let anthropic_provider =
  Pera_cli.Models_config.
    {
      name = "anthropic";
      protocol = "anthropic";
      api_key_env = [ "ANTHROPIC_API_KEY" ];
      api = None;
      api_env = None;
      compat = None;
      models = [ anthropic_model; thinking_model ];
    }

let models_file = Pera_cli.Models_config.{ providers = [ anthropic_provider ] }

let empty_args : Pera_cli.Cli_args.parsed_args =
  {
    model = None;
    api_key = None;
    api_key_file = None;
    api_key_command = None;
    effort = None;
    max_tokens = None;
    cache_policy = None;
    cache_ttl = None;
    session = None;
    session_dir = None;
    cwd = Some "/project";
    system = None;
    system_file = None;
    no_compact = false;
    compact_threshold = None;
    compact_tail = None;
    plain = false;
    show_thinking = false;
    quiet = false;
    json = false;
    verbose = false;
  }

let make_inputs ?(parsed_args = empty_args) ?(user_config = None)
    ?(project_config = None) ?(getenv_opt = fun _ -> None)
    ?(home = "/home/user") () =
  Pera_cli.Config_resolver.
    { parsed_args; models_file; user_config; project_config; getenv_opt; home }

let make_config ?default_model ?effort () : Pera_cli.Pera_config.config =
  {
    providers = [];
    default_model;
    effort;
    max_tokens = None;
    cache = None;
    session = None;
    compaction = None;
    output = None;
    commands = [];
    tools = [];
    mcp_servers = [];
  }

(* Test 1: CLI --model overrides user config default_model *)
let test_cli_model_overrides_user_config () =
  let user_config =
    Some (make_config ~default_model:"anthropic/other-model" ())
  in
  let parsed_args =
    { empty_args with model = Some "anthropic/claude-sonnet-4-6" }
  in
  let inputs = make_inputs ~parsed_args ~user_config () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Ok rc ->
      Alcotest.(check string)
        "model id" "claude-sonnet-4-6"
        rc.Pera_cli.Config_resolver.model.Pera_types.Types.id
  | Error e -> Alcotest.failf "unexpected error: %s" e

(* Test 2: PERA_MODEL env var overrides user config *)
let test_env_model_overrides_user_config () =
  let user_config =
    Some (make_config ~default_model:"anthropic/other-model" ())
  in
  let getenv_opt k =
    if String.equal k "PERA_MODEL" then Some "anthropic/claude-sonnet-4-6"
    else None
  in
  let inputs = make_inputs ~user_config ~getenv_opt () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Ok rc ->
      Alcotest.(check string)
        "model id" "claude-sonnet-4-6"
        rc.Pera_cli.Config_resolver.model.Pera_types.Types.id
  | Error e -> Alcotest.failf "unexpected error: %s" e

(* Test 3: project config default_model overrides user config *)
let test_project_config_overrides_user_config () =
  let user_config =
    Some (make_config ~default_model:"anthropic/other-model" ())
  in
  let project_config =
    Some (make_config ~default_model:"anthropic/claude-sonnet-4-6" ())
  in
  let inputs = make_inputs ~user_config ~project_config () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Ok rc ->
      Alcotest.(check string)
        "model id" "claude-sonnet-4-6"
        rc.Pera_cli.Config_resolver.model.Pera_types.Types.id
  | Error e -> Alcotest.failf "unexpected error: %s" e

(* Test 4: no model → Error *)
let test_no_model_gives_error () =
  let inputs = make_inputs () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error when no model specified"

(* Test 5: effort Low → thinking_budget_tokens = None *)
let test_low_effort_no_thinking () =
  let user_config =
    Some
      (make_config ~default_model:"anthropic/claude-sonnet-4-6"
         ~effort:Pera_cli.Pera_config.Low ())
  in
  let inputs = make_inputs ~user_config () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Ok rc ->
      Alcotest.(check (option int))
        "no thinking budget" None
        rc.Pera_cli.Config_resolver.thinking_budget_tokens
  | Error e -> Alcotest.failf "unexpected error: %s" e

(* Test 6: effort Medium with thinking model → Some budget_medium *)
let test_medium_effort_thinking_model () =
  let parsed_args =
    {
      empty_args with
      model = Some "anthropic/claude-think";
      effort = Some Pera_cli.Pera_config.Medium;
    }
  in
  let inputs = make_inputs ~parsed_args () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Ok rc ->
      Alcotest.(check (option int))
        "thinking budget = 8000" (Some 8000)
        rc.Pera_cli.Config_resolver.thinking_budget_tokens
  | Error e -> Alcotest.failf "unexpected error: %s" e

(* Test 7: effort Medium without thinking model → Error *)
let test_medium_effort_no_thinking_model () =
  let parsed_args =
    {
      empty_args with
      model = Some "anthropic/claude-sonnet-4-6";
      effort = Some Pera_cli.Pera_config.Medium;
    }
  in
  let inputs = make_inputs ~parsed_args () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Error e ->
      Alcotest.(check bool)
        "error mentions thinking" true
        (String.mem ~sub:"thinking" e)
  | Ok _ -> Alcotest.fail "expected Error"

(* Test 8: fully-qualified model resolves to provider_spec + model_spec *)
let test_model_resolves_to_provider () =
  let user_config =
    Some (make_config ~default_model:"anthropic/claude-sonnet-4-6" ())
  in
  let inputs = make_inputs ~user_config () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Ok rc ->
      Alcotest.(check string)
        "provider spec name" "anthropic"
        rc.Pera_cli.Config_resolver.provider_spec.Pera_cli.Models_config.name
  | Error e -> Alcotest.failf "unexpected error: %s" e

(* Test 9: unqualified model name → Error *)
let test_unqualified_model_error () =
  let parsed_args = { empty_args with model = Some "claude-sonnet-4-6" } in
  let inputs = make_inputs ~parsed_args () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for unqualified model name"

(* Test 10: unknown model → Error with suggestion text *)
let test_unknown_model_error () =
  let parsed_args =
    { empty_args with model = Some "anthropic/does-not-exist" }
  in
  let inputs = make_inputs ~parsed_args () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Error e ->
      Alcotest.(check bool)
        "error message mentions unknown model" true
        (String.mem ~sub:"does-not-exist" e)
  | Ok _ -> Alcotest.fail "expected Error for unknown model"

(* Test 11: api_key_env resolution via injected getenv_opt *)
let test_api_key_env_resolution () =
  let user_config =
    Some (make_config ~default_model:"anthropic/claude-sonnet-4-6" ())
  in
  let getenv_opt k =
    if String.equal k "ANTHROPIC_API_KEY" then Some "env-api-key" else None
  in
  let inputs = make_inputs ~user_config ~getenv_opt () in
  match Pera_cli.Config_resolver.resolve inputs with
  | Ok rc -> (
      match rc.Pera_cli.Config_resolver.api_key_source with
      | Some (Pera_cli.Pera_config.Key "env-api-key") -> ()
      | Some _ -> Alcotest.fail "wrong api_key_source variant"
      | None -> Alcotest.fail "expected Some api_key_source")
  | Error e -> Alcotest.failf "unexpected error: %s" e

let suite =
  [
    ( "CLI --model overrides user config",
      `Quick,
      test_cli_model_overrides_user_config );
    ( "PERA_MODEL env overrides user config",
      `Quick,
      test_env_model_overrides_user_config );
    ( "project config overrides user config",
      `Quick,
      test_project_config_overrides_user_config );
    ("no model → Error", `Quick, test_no_model_gives_error);
    ("Low effort → no thinking", `Quick, test_low_effort_no_thinking);
    ( "Medium effort with thinking model",
      `Quick,
      test_medium_effort_thinking_model );
    ( "Medium effort without thinking model → Error",
      `Quick,
      test_medium_effort_no_thinking_model );
    ( "fully-qualified model resolves to provider",
      `Quick,
      test_model_resolves_to_provider );
    ("unqualified model name → Error", `Quick, test_unqualified_model_error);
    ("unknown model → Error with hint", `Quick, test_unknown_model_error);
    ("api_key_env resolved via getenv_opt", `Quick, test_api_key_env_resolution);
  ]

let () = Alcotest.run "config_resolver" [ ("config_resolver", suite) ]
