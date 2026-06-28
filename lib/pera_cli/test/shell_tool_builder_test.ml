open Containers

let test_build_no_args () =
  let def =
    Pera_cli.Pera_config.
      {
        name = "hello";
        description = "Say hello";
        command = "echo hello";
        parallel_safe = true;
        args = [];
      }
  in
  match Pera_cli.Shell_tool_builder.build def with
  | Ok _tool -> ()
  | Error _ -> Alcotest.fail "expected Ok"

let test_build_with_args () =
  let def =
    Pera_cli.Pera_config.
      {
        name = "greet";
        description = "Greet someone";
        command = "echo {name}";
        parallel_safe = true;
        args =
          [
            {
              name = "name";
              arg_type = String { description = "Name to greet" };
            };
          ];
      }
  in
  match Pera_cli.Shell_tool_builder.build def with
  | Ok _tool -> ()
  | Error _ -> Alcotest.fail "expected Ok"

let test_build_unknown_placeholder () =
  let def =
    Pera_cli.Pera_config.
      {
        name = "bad";
        description = "Bad tool";
        command = "echo {missing}";
        parallel_safe = true;
        args = [];
      }
  in
  match Pera_cli.Shell_tool_builder.build def with
  | Error (Pera_cli.Shell_tool_builder.Unknown_placeholder "missing") -> ()
  | Error (Pera_cli.Shell_tool_builder.Unknown_placeholder p) ->
      Alcotest.failf "expected Unknown_placeholder \"missing\", got %S" p
  | Ok _ -> Alcotest.fail "expected Error"

let test_build_all_short_circuits () =
  let good =
    Pera_cli.Pera_config.
      {
        name = "good";
        description = "Good";
        command = "echo hi";
        parallel_safe = true;
        args = [];
      }
  in
  let bad =
    Pera_cli.Pera_config.
      {
        name = "bad";
        description = "Bad";
        command = "echo {x}";
        parallel_safe = true;
        args = [];
      }
  in
  match Pera_cli.Shell_tool_builder.build_all [ good; bad ] with
  | Error (Pera_cli.Shell_tool_builder.Unknown_placeholder "x") -> ()
  | Error (Pera_cli.Shell_tool_builder.Unknown_placeholder p) ->
      Alcotest.failf "expected Unknown_placeholder \"x\", got %S" p
  | Ok _ -> Alcotest.fail "expected Error"

let test_build_all_success () =
  let def =
    Pera_cli.Pera_config.
      {
        name = "t1";
        description = "Tool 1";
        command = "echo hi";
        parallel_safe = true;
        args = [];
      }
  in
  match Pera_cli.Shell_tool_builder.build_all [ def; def ] with
  | Ok tools -> Alcotest.(check int) "two tools" 2 (List.length tools)
  | Error _ -> Alcotest.fail "expected Ok"

let test_substitute () =
  let result =
    Pera_cli.Shell_tool_builder.substitute "echo {name}" [ ("name", "world") ]
  in
  Alcotest.(check string) "substitutes" "echo 'world'" result

let test_substitute_quotes () =
  let result =
    Pera_cli.Shell_tool_builder.substitute "echo {name}"
      [ ("name", "hello world") ]
  in
  Alcotest.(check string) "quotes" "echo 'hello world'" result

let test_build_all_error_first () =
  let bad =
    Pera_cli.Pera_config.
      {
        name = "bad";
        description = "Bad";
        command = "echo {x}";
        parallel_safe = true;
        args = [];
      }
  in
  let good =
    Pera_cli.Pera_config.
      {
        name = "good";
        description = "Good";
        command = "echo hi";
        parallel_safe = true;
        args = [];
      }
  in
  match Pera_cli.Shell_tool_builder.build_all [ bad; good ] with
  | Error (Pera_cli.Shell_tool_builder.Unknown_placeholder "x") -> ()
  | Error (Pera_cli.Shell_tool_builder.Unknown_placeholder p) ->
      Alcotest.failf "expected Unknown_placeholder \"x\", got %S" p
  | Ok _ -> Alcotest.fail "expected Error"

let () =
  Alcotest.run "shell_tool_builder"
    [
      ( "build",
        [
          Alcotest.test_case "no args" `Quick test_build_no_args;
          Alcotest.test_case "with args" `Quick test_build_with_args;
          Alcotest.test_case "unknown placeholder" `Quick
            test_build_unknown_placeholder;
        ] );
      ( "build_all",
        [
          Alcotest.test_case "short circuits on error (error last)" `Quick
            test_build_all_short_circuits;
          Alcotest.test_case "short circuits on error (error first)" `Quick
            test_build_all_error_first;
          Alcotest.test_case "success" `Quick test_build_all_success;
        ] );
      ( "substitute",
        [
          Alcotest.test_case "simple" `Quick test_substitute;
          Alcotest.test_case "quotes special chars" `Quick
            test_substitute_quotes;
        ] );
    ]
