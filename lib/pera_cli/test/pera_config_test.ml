open Containers

let effort_testable =
  Alcotest.testable Pera_cli.Pera_config.pp_effort
    Pera_cli.Pera_config.equal_effort

let cache_ttl_testable =
  Alcotest.testable Pera_cli.Pera_config.pp_cache_ttl
    Pera_cli.Pera_config.equal_cache_ttl

let arg_type_testable =
  Alcotest.testable Pera_cli.Pera_config.pp_shell_arg_type
    Pera_cli.Pera_config.equal_shell_arg_type

(* Test 1: parse a user config sexp *)
let test_parse_user_config () =
  let sexp_str =
    {|((default_model "anthropic/claude-sonnet-4-6")
       (effort medium)
       (max_tokens 16000)
       (cache ((policy conversation) (ttl one_hour)))
       (session ((dir "/tmp/pera-sessions")))
       (compaction ((enabled true) (threshold 50) (tail 20)))
       (output ((plain true) (show_thinking true) (quiet false))))|}
  in
  let cfg =
    Pera_cli.Pera_config.config_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check (option string))
    "default_model" (Some "anthropic/claude-sonnet-4-6") cfg.default_model;
  Alcotest.(check (option effort_testable))
    "effort" (Some Pera_cli.Pera_config.Medium) cfg.effort;
  Alcotest.(check (option int)) "max_tokens" (Some 16000) cfg.max_tokens;
  match cfg.cache with
  | Some c ->
      Alcotest.(check (option cache_ttl_testable))
        "cache ttl" (Some Pera_cli.Pera_config.One_hour) c.ttl
  | None -> Alcotest.fail "expected cache config"

(* Test 2: parse a project config sexp *)
let test_parse_project_config () =
  let sexp_str =
    {|((default_model "anthropic/claude-sonnet-4-6")
       (tools (((name test-tool) (description "A test tool")
                (command "echo {args}") (parallel_safe true)))))|}
  in
  let cfg =
    Pera_cli.Pera_config.config_of_sexp (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check (option string))
    "default_model" (Some "anthropic/claude-sonnet-4-6") cfg.default_model;
  Alcotest.(check int) "one tool" 1 (List.length cfg.tools)

(* Test 3: shell_tool_def with args *)
let test_shell_tool_def () =
  let sexp_str =
    {|((name test-tool) (description "A test tool")
       (command "echo {message} {count}")
       (parallel_safe true)
       (args (((name message) (arg_type (String (description "The message"))))
              ((name count) (arg_type (Int (description "The count") (min 0) (max 10)))))))|}
  in
  let tool =
    Pera_cli.Pera_config.shell_tool_def_of_sexp
      (Sexplib.Sexp.of_string sexp_str)
  in
  Alcotest.(check string) "name" "test-tool" tool.name;
  Alcotest.(check bool) "parallel_safe" true tool.parallel_safe;
  Alcotest.(check int) "two args" 2 (List.length tool.args);
  match tool.args with
  | [ a1; a2 ] ->
      Alcotest.(check string) "arg1 name" "message" a1.name;
      Alcotest.(check arg_type_testable)
        "arg1 type"
        (Pera_cli.Pera_config.String { description = "The message" })
        a1.arg_type;
      Alcotest.(check string) "arg2 name" "count" a2.name;
      Alcotest.(check arg_type_testable)
        "arg2 type"
        (Pera_cli.Pera_config.Int
           { description = "The count"; min = Some 0; max = Some 10 })
        a2.arg_type
  | _ -> Alcotest.fail "expected exactly two args"

let test_command_api_key_round_trip () =
  let src = Pera_cli.Pera_config.Command [ "vault"; "get"; "my-key" ] in
  let sexp = Pera_cli.Pera_config.sexp_of_api_key_source src in
  let expected =
    Sexplib.Sexp.List
      [
        Sexplib.Sexp.Atom "Command";
        Sexplib.Sexp.List
          [
            Sexplib.Sexp.Atom "vault";
            Sexplib.Sexp.Atom "get";
            Sexplib.Sexp.Atom "my-key";
          ];
      ]
  in
  Alcotest.(check bool) "sexp shape" true (Sexplib.Sexp.equal sexp expected);
  let src' = Pera_cli.Pera_config.api_key_source_of_sexp sexp in
  Alcotest.(check bool)
    "round-trip"
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
    ( "Command api_key source round-trip",
      `Quick,
      test_command_api_key_round_trip );
    ("empty config defaults", `Quick, test_empty_config);
  ]

let () = Alcotest.run "pera_config" [ ("pera_config", suite) ]
