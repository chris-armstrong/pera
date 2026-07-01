let test_effort_conv_low () =
  match Cmdliner.Arg.conv_parser Pera_cli.Cli_args.effort_conv "low" with
  | Ok Pera_cli.Pera_config.Low -> ()
  | _ -> Alcotest.fail "expected Low"

let test_effort_conv_medium () =
  match Cmdliner.Arg.conv_parser Pera_cli.Cli_args.effort_conv "medium" with
  | Ok Pera_cli.Pera_config.Medium -> ()
  | _ -> Alcotest.fail "expected Medium"

let test_effort_conv_high_upper () =
  match Cmdliner.Arg.conv_parser Pera_cli.Cli_args.effort_conv "HIGH" with
  | Ok Pera_cli.Pera_config.High -> ()
  | _ -> Alcotest.fail "expected High (case-insensitive)"

let test_effort_conv_rejects_unknown () =
  match Cmdliner.Arg.conv_parser Pera_cli.Cli_args.effort_conv "extreme" with
  | Error (`Msg _) -> ()
  | Ok _ -> Alcotest.fail "expected Error for unknown effort"

let test_cache_policy_conv () =
  let check s expected =
    match Cmdliner.Arg.conv_parser Pera_cli.Cli_args.cache_policy_conv s with
    | Ok p when Pera_cli.Pera_config.equal_cache_policy p expected -> ()
    | Ok _ -> Alcotest.failf "wrong policy for %S" s
    | Error (`Msg e) -> Alcotest.failf "unexpected error for %S: %s" s e
  in
  check "no_cache" Pera_cli.Pera_config.No_cache;
  check "conversation" Pera_cli.Pera_config.Conversation;
  check "system_and_tools" Pera_cli.Pera_config.System_and_tools

let test_cache_ttl_conv () =
  (match
     Cmdliner.Arg.conv_parser Pera_cli.Cli_args.cache_ttl_conv "five_minutes"
   with
  | Ok Pera_cli.Pera_config.Five_minutes -> ()
  | _ -> Alcotest.fail "expected Five_minutes");
  match
    Cmdliner.Arg.conv_parser Pera_cli.Cli_args.cache_ttl_conv "one_hour"
  with
  | Ok Pera_cli.Pera_config.One_hour -> ()
  | _ -> Alcotest.fail "expected One_hour"

let make_args ?(model = None) ?(api_key = None) ?(api_key_file = None)
    ?(api_key_command = None) ?(effort = None) ?(max_tokens = None)
    ?(cache_policy = None) ?(cache_ttl = None) ?(session = None)
    ?(session_dir = None) ?(cwd = None) ?(system = None) ?(system_file = None)
    ?(no_compact = false) ?(compact_threshold = None) ?(compact_tail = None)
    ?(show_thinking = false) ?(quiet = false) ?(json = false)
    ?(input = None) ?(input_file = None) ?(list_models = false) () =
  Pera_cli.Cli_args.
    {
      model;
      api_key;
      api_key_file;
      api_key_command;
      effort;
      max_tokens;
      cache_policy;
      cache_ttl;
      session;
      session_dir;
      cwd;
      system;
      system_file;
      no_compact;
      compact_threshold;
      compact_tail;
      show_thinking;
      quiet;
      json;
      input;
      input_file;
      list_models;
    }

let test_to_partial_no_compact () =
  let args = make_args ~no_compact:true () in
  let cfg = Pera_cli.Cli_args.to_partial_config args in
  match cfg.compaction with
  | Some { enabled = Some false; _ } -> ()
  | _ -> Alcotest.fail "expected compaction.enabled=false"

let test_to_partial_show_thinking () =
  let args = make_args ~show_thinking:true () in
  let cfg = Pera_cli.Cli_args.to_partial_config args in
  match cfg.output with
  | Some { show_thinking = Some true; _ } -> ()
  | _ -> Alcotest.fail "expected output.show_thinking=true"

let test_to_partial_quiet () =
  let args = make_args ~quiet:true () in
  let cfg = Pera_cli.Cli_args.to_partial_config args in
  match cfg.output with
  | Some { quiet = Some true; _ } -> ()
  | _ -> Alcotest.fail "expected output.quiet=true"

let test_to_partial_model () =
  let args = make_args ~model:(Some "anthropic/claude-sonnet-4-6") () in
  let cfg = Pera_cli.Cli_args.to_partial_config args in
  Alcotest.(check (option string))
    "model" (Some "anthropic/claude-sonnet-4-6") cfg.default_model

let test_to_partial_no_flags () =
  let args = make_args () in
  let cfg = Pera_cli.Cli_args.to_partial_config args in
  Alcotest.(check (option string)) "no model" None cfg.default_model;
  Alcotest.(check (option int)) "no max_tokens" None cfg.max_tokens

let suite =
  [
    ("effort_conv: low", `Quick, test_effort_conv_low);
    ("effort_conv: medium", `Quick, test_effort_conv_medium);
    ("effort_conv: HIGH (case-insensitive)", `Quick, test_effort_conv_high_upper);
    ("effort_conv: rejects unknown", `Quick, test_effort_conv_rejects_unknown);
    ("cache_policy_conv: all values", `Quick, test_cache_policy_conv);
    ("cache_ttl_conv: all values", `Quick, test_cache_ttl_conv);
    ("to_partial_config: no_compact", `Quick, test_to_partial_no_compact);
    ("to_partial_config: show_thinking", `Quick, test_to_partial_show_thinking);
    ("to_partial_config: quiet", `Quick, test_to_partial_quiet);
    ("to_partial_config: model", `Quick, test_to_partial_model);
    ("to_partial_config: no flags", `Quick, test_to_partial_no_flags);
  ]

let () = Alcotest.run "cli_args" [ ("cli_args", suite) ]
