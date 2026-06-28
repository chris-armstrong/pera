open Containers

let api_key_source_testable =
  Alcotest.testable Pera_cli.Pera_config.pp_api_key_source
    Pera_cli.Pera_config.equal_api_key_source

let make_config ?default_model ?effort ?max_tokens ?cache ?session ?compaction
    ?output ?(commands = []) ?(tools = []) ?(mcp_servers = []) ?(providers = [])
    () =
  Pera_cli.Pera_config.
    {
      default_model;
      effort;
      max_tokens;
      cache;
      session;
      compaction;
      output;
      commands;
      tools;
      mcp_servers;
      providers;
    }

(* Test 1: merge replaces Some field *)
let test_merge_replaces_field () =
  let base = make_config ~default_model:"old-model" () in
  let overlay = make_config ~default_model:"new-model" () in
  let result = Pera_cli.Config_loader.merge ~base ~overlay in
  Alcotest.(check (option string))
    "default_model updated" (Some "new-model") result.default_model

(* Test 2: merge keeps base value when overlay is None *)
let test_merge_keeps_base () =
  let base = make_config ~default_model:"old-model" () in
  let overlay = make_config () in
  let result = Pera_cli.Config_loader.merge ~base ~overlay in
  Alcotest.(check (option string))
    "default_model unchanged" (Some "old-model") result.default_model

(* Test 3: merge replaces list fields entirely *)
let test_merge_replaces_list () =
  let base =
    make_config
      ~commands:
        [
          {
            Pera_cli.Pera_config.name = "old";
            description = "old command";
            template = "old";
          };
        ]
      ()
  in
  let overlay =
    make_config
      ~commands:
        [
          {
            Pera_cli.Pera_config.name = "new";
            description = "new command";
            template = "new";
          };
        ]
      ()
  in
  let result = Pera_cli.Config_loader.merge ~base ~overlay in
  Alcotest.(check int) "one command" 1 (List.length result.commands);
  match result.commands with
  | [ c ] -> Alcotest.(check string) "command name" "new" c.name
  | _ -> Alcotest.fail "expected exactly one command"

(* Test 4: load_project_config rejects api_key *)
let test_rejects_api_key () =
  let tmpdir = Filename.get_temp_dir_name () in
  let test_file = Filename.concat tmpdir "pera_test_reject.pera" in
  let sexp_str =
    {|((providers (((name anthropic) (api_key (key "test-key"))))))|}
  in
  let oc = open_out test_file in
  output_string oc sexp_str;
  close_out oc;
  let result = Pera_cli.Config_loader.load_project_config ~path:test_file in
  (match result with
  | Error Pera_cli.Config_loader.Api_key_in_project_config -> ()
  | Ok _ -> Alcotest.fail "expected Api_key_in_project_config error"
  | Error (Parse_error _) ->
      Alcotest.fail "expected Api_key_in_project_config, got Parse_error");
  Sys.remove test_file

(* Test 5: load_project_config rejects api_key even when api is present *)
let test_rejects_api_key_with_api () =
  let tmpdir = Filename.get_temp_dir_name () in
  let test_file = Filename.concat tmpdir "pera_test_api_reject.pera" in
  let sexp_str =
    {|((default_model "anthropic/claude-sonnet-4-6")
       (providers (((name anthropic) (api "https://example.com")
                    (api_key (key "test-key"))))))|}
  in
  let oc = open_out test_file in
  output_string oc sexp_str;
  close_out oc;
  let result = Pera_cli.Config_loader.load_project_config ~path:test_file in
  (match result with
  | Error Pera_cli.Config_loader.Api_key_in_project_config -> ()
  | Ok _ -> Alcotest.fail "expected Api_key_in_project_config error"
  | Error (Parse_error _) ->
      Alcotest.fail "expected Api_key_in_project_config, got Parse_error");
  Sys.remove test_file

(* Test 6: load_project_config allows api override *)
let test_allows_api_override () =
  let tmpdir = Filename.get_temp_dir_name () in
  let test_file = Filename.concat tmpdir "pera_test_api.pera" in
  let sexp_str =
    {|((default_model "anthropic/claude-sonnet-4-6")
       (providers (((name anthropic) (api "https://example.com")))))|}
  in
  let oc = open_out test_file in
  output_string oc sexp_str;
  close_out oc;
  let result = Pera_cli.Config_loader.load_project_config ~path:test_file in
  (match result with
  | Ok (Some cfg) -> (
      match cfg.providers with
      | [ p ] ->
          Alcotest.(check string) "provider name" "anthropic" p.name;
          Alcotest.(check (option string))
            "api" (Some "https://example.com") p.api;
          Alcotest.(check (option api_key_source_testable))
            "no api_key" None p.api_key
      | _ -> Alcotest.fail "expected exactly one provider")
  | Ok None -> Alcotest.fail "expected Some config"
  | Error _ -> Alcotest.fail "expected Ok");
  Sys.remove test_file

(* Test 7: load_project_config allows empty providers list *)
let test_allows_empty_providers () =
  let tmpdir = Filename.get_temp_dir_name () in
  let test_file = Filename.concat tmpdir "pera_test_empty.pera" in
  let sexp_str = {|((default_model "anthropic/claude-sonnet-4-6"))|} in
  let oc = open_out test_file in
  output_string oc sexp_str;
  close_out oc;
  let result = Pera_cli.Config_loader.load_project_config ~path:test_file in
  (match result with
  | Ok (Some cfg) ->
      Alcotest.(check (option string))
        "default_model" (Some "anthropic/claude-sonnet-4-6") cfg.default_model
  | Ok None -> Alcotest.fail "expected Some config"
  | Error _ -> Alcotest.fail "expected Ok");
  Sys.remove test_file

(* Test 8: find_project_config walks up to parent dir *)
let test_find_project_config () =
  let tmpdir = Filename.get_temp_dir_name () in
  let test_dir = Filename.concat tmpdir "pera_test_find" in
  let sub_dir = Filename.concat test_dir "sub" in
  let pera_file = Filename.concat test_dir ".pera" in
  Unix.mkdir test_dir 0o755;
  Unix.mkdir sub_dir 0o755;
  let fd = Unix.openfile pera_file [ Unix.O_CREAT; Unix.O_WRONLY ] 0o644 in
  Unix.close fd;
  let found = Pera_cli.Config_loader.find_project_config ~cwd:sub_dir in
  (match found with
  | Some p ->
      Alcotest.check Alcotest.bool "found .pera file" (String.equal p pera_file)
        true
  | None -> Alcotest.fail "expected to find .pera file");
  Unix.unlink pera_file;
  Unix.rmdir sub_dir;
  Unix.rmdir test_dir

(* Test 9: find_project_config returns None at root *)
let test_find_project_config_none () =
  let found = Pera_cli.Config_loader.find_project_config ~cwd:"/" in
  Alcotest.(check (option string)) "no .pera at root" None found

let suite =
  [
    ("merge replaces Some field", `Quick, test_merge_replaces_field);
    ( "merge keeps base value when overlay is None",
      `Quick,
      test_merge_keeps_base );
    ("merge replaces list fields entirely", `Quick, test_merge_replaces_list);
    ("load_project_config rejects api_key", `Quick, test_rejects_api_key);
    ( "load_project_config rejects api_key even with api",
      `Quick,
      test_rejects_api_key_with_api );
    ("load_project_config allows api override", `Quick, test_allows_api_override);
    ( "load_project_config allows empty providers",
      `Quick,
      test_allows_empty_providers );
    ( "find_project_config walks up to parent dir",
      `Quick,
      test_find_project_config );
    ( "find_project_config returns None at root",
      `Quick,
      test_find_project_config_none );
  ]

let () = Alcotest.run "config_loader" [ ("config_loader", suite) ]
