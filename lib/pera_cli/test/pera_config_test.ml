open Containers

let effort_testable =
  Alcotest.testable
    Pera_cli.Pera_config.pp_effort
    Pera_cli.Pera_config.equal_effort

(* Test 1: parse a user config sexp *)
let test_parse_user_config () =
  let sexp_str =
    {|((default_model "anthropic/claude-sonnet-4-6")
       (effort medium)
       (max_tokens 16000)
       (cache ((policy conversation) (ttl 300)))
       (session ((dir "/tmp/pera-sessions")))
       (compaction ((enabled true) (threshold 50) (tail 20)))
       (output ((plain true) (show_thinking true) (quiet false))))|}
  in
  let cfg =
    Pera_cli.Pera_config.config_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check (option string)) "default_model"
    (Some "anthropic/claude-sonnet-4-6") cfg.default_model;
  Alcotest.(check (option effort_testable)) "effort"
    (Some Pera_cli.Pera_config.Medium) cfg.effort;
  Alcotest.(check (option int)) "max_tokens" (Some 16000) cfg.max_tokens

(* Test 2: parse a project config sexp *)
let test_parse_project_config () =
  let sexp_str =
    {|((default_model "anthropic/claude-sonnet-4-6")
       (tools (((name test-tool) (description "A test tool")
                (command "echo") (args (((name message) (arg_type single))))))))|}
  in
  let cfg =
    Pera_cli.Pera_config.config_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check (option string)) "default_model"
    (Some "anthropic/claude-sonnet-4-6") cfg.default_model;
  Alcotest.(check int) "one tool" 1 (List.length cfg.tools)

(* Test 3: shell_tool_def with args *)
let test_shell_tool_def () =
  let sexp_str =
    {|((name test-tool) (description "A test tool")
       (command "echo")
       (args (((name message) (arg_type single) (description "The message"))
              ((name rest) (arg_type rest)))))|}
  in
  let tool =
    Pera_cli.Pera_config.shell_tool_def_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check string) "name" "test-tool" tool.name;
  Alcotest.(check int) "two args" 2 (List.length tool.args);
  match tool.args with
  | [a1; a2] ->
      Alcotest.(check string) "arg1 name" "message" a1.name;
      Alcotest.(check bool) "arg1 type"
        (match a1.arg_type with Pera_cli.Pera_config.Single -> true | _ -> false) true;
      Alcotest.(check (option string)) "arg1 desc"
        (Some "The message") a1.description;
      Alcotest.(check string) "arg2 name" "rest" a2.name;
      Alcotest.(check bool) "arg2 type"
        (match a2.arg_type with Pera_cli.Pera_config.Rest -> true | _ -> false) true
  | _ -> Alcotest.fail "expected exactly two args"

(* Test 4: Command api_key source round-trip *)
let test_command_api_key_round_trip () =
  let src = Pera_cli.Pera_config.Command [ "vault"; "get"; "my-key" ] in
  let sexp = Pera_cli.Pera_config.sexp_of_api_key_source src in
  let src' = Pera_cli.Pera_config.api_key_source_of_sexp sexp in
  Alcotest.(check bool) "round-trip"
    (Pera_cli.Pera_config.equal_api_key_source src src')
    true

(* Test 5: empty config defaults *)
let test_empty_config () =
  let sexp_str = "()" in
  let cfg =
    Pera_cli.Pera_config.config_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check (option string)) "no default_model" None cfg.default_model;
  Alcotest.(check int) "no commands" 0 (List.length cfg.commands);
  Alcotest.(check int) "no tools" 0 (List.length cfg.tools);
  Alcotest.(check int) "no mcp_servers" 0 (List.length cfg.mcp_servers);
  Alcotest.(check int) "no providers" 0 (List.length cfg.providers)

let suite =
  [
    ("parse user config sexp", `Quick, test_parse_user_config);
    ("parse project config sexp", `Quick, test_parse_project_config);
    ("shell_tool_def with args", `Quick, test_shell_tool_def);
    ("Command api_key source round-trip", `Quick, test_command_api_key_round_trip);
    ("empty config defaults", `Quick, test_empty_config);
  ]

let () =
  Alcotest.run "pera_config" [ ("pera_config", suite) ]
