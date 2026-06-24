open Containers
open Pera_tools
open Pera_core.Agent_types
open Test_util

let string_testable = Alcotest.testable Format.pp_print_string String.equal

let run_tool_test
    (body : (module Pera_env.Execution_env.S) -> Eio.Switch.t -> unit) =
  Eio_main.run @@ fun env ->
  let tmpdir = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  let module E =
    (val Pera_env.Local_env.create ~env ~cwd:tmpdir : Pera_env.Execution_env.S)
  in
  body (module E) sw

(* ── golden tests for canonical tool schema bytes ───────────────────────── *)

let test_read_tool_schema_is_canonical () =
  run_tool_test (fun (module E) _sw ->
      let tool = Read_tool.read in
      let schema_json = Tool.schema tool |> Pera_connector.Json_schema.to_json in
      let actual = Yojson.Safe.to_string schema_json in
      let expected =
        {|{"properties":{"limit":{"anyOf":[{"description":"Maximum number of lines to return. Default is 2000.","type":"integer"},{"const":null}]},"offset":{"anyOf":[{"description":"Start reading from this line number (1-indexed). Default is 0 (beginning).","type":"integer"},{"const":null}]},"path":{"description":"Path to read (use absolute path when possible).","type":"string"}},"required":["path"],"type":"object"}|}
      in
      Alcotest.check string_testable "read tool schema bytes" expected actual)

let test_write_tool_schema_is_canonical () =
  run_tool_test (fun (module E) _sw ->
      let tool = Write_tool.write in
      let schema_json = Tool.schema tool |> Pera_connector.Json_schema.to_json in
      let actual = Yojson.Safe.to_string schema_json in
      let expected =
        {|{"properties":{"content":{"description":"Content to write to the file.","type":"string"},"path":{"description":"Path to write to (relative or absolute).","type":"string"}},"required":["content","path"],"type":"object"}|}
      in
      Alcotest.check string_testable "write tool schema bytes" expected actual)

let test_bash_tool_schema_is_canonical () =
  run_tool_test (fun (module E) _sw ->
      let tool = Bash_tool.bash in
      let schema_json = Tool.schema tool |> Pera_connector.Json_schema.to_json in
      let actual = Yojson.Safe.to_string schema_json in
      let expected =
        {|{"properties":{"command":{"description":"Bash command to execute in the current working directory.","type":"string"},"timeout":{"anyOf":[{"description":"Timeout in seconds.","type":"number"},{"const":null}]}},"required":["command"],"type":"object"}|}
      in
      Alcotest.check string_testable "bash tool schema bytes" expected actual)

let test_grep_tool_schema_is_canonical () =
  run_tool_test (fun (module E) _sw ->
      let tool = Grep_tool.grep in
      let schema_json = Tool.schema tool |> Pera_connector.Json_schema.to_json in
      let actual = Yojson.Safe.to_string schema_json in
      let expected =
        {|{"properties":{"glob":{"anyOf":[{"description":"Filter files by glob pattern (e.g. '*.ml').","type":"string"},{"const":null}]},"path":{"anyOf":[{"description":"File or directory to search (default: current directory).","type":"string"},{"const":null}]},"pattern":{"description":"Search pattern (regular expression).","type":"string"}},"required":["pattern"],"type":"object"}|}
      in
      Alcotest.check string_testable "grep tool schema bytes" expected actual)

let () =
  Alcotest.run "tool_canonical"
    [
      ( "schema_bytes",
        [
          Alcotest.test_case "read_tool_schema_is_canonical" `Quick
            test_read_tool_schema_is_canonical;
          Alcotest.test_case "write_tool_schema_is_canonical" `Quick
            test_write_tool_schema_is_canonical;
          Alcotest.test_case "bash_tool_schema_is_canonical" `Quick
            test_bash_tool_schema_is_canonical;
          Alcotest.test_case "grep_tool_schema_is_canonical" `Quick
            test_grep_tool_schema_is_canonical;
        ] );
    ]
