open Containers

let no_commands = []

let test_parse_compact () =
  match Pera_cli.Input_loop.parse_line ~commands:no_commands "/compact" with
  | Compact -> ()
  | _ -> Alcotest.fail "expected Compact"

let test_parse_quit () =
  match Pera_cli.Input_loop.parse_line ~commands:no_commands "/quit" with
  | Quit -> ()
  | _ -> Alcotest.fail "expected Quit"

let test_parse_q () =
  match Pera_cli.Input_loop.parse_line ~commands:no_commands "/q" with
  | Quit -> ()
  | _ -> Alcotest.fail "expected Quit"

let test_parse_info () =
  match Pera_cli.Input_loop.parse_line ~commands:no_commands "/info" with
  | Info -> ()
  | _ -> Alcotest.fail "expected Info"

let test_parse_custom_command () =
  let commands =
    [
      Pera_cli.Pera_config.
        {
          name = "review";
          description = "Review changes";
          template = "Please review: {args}";
        };
    ]
  in
  match Pera_cli.Input_loop.parse_line ~commands "/review diff" with
  | Send text ->
      Alcotest.(check string) "template expanded" "Please review: diff" text
  | _ -> Alcotest.fail "expected Send"

let test_parse_unknown_command () =
  match Pera_cli.Input_loop.parse_line ~commands:no_commands "/unknown" with
  | Error msg ->
      Alcotest.(check bool)
        "contains unknown" true
        (String.mem ~sub:"unknown" msg)
  | _ -> Alcotest.fail "expected Error"

let test_parse_plain_text () =
  match Pera_cli.Input_loop.parse_line ~commands:no_commands "hello world" with
  | Send text -> Alcotest.(check string) "plain text" "hello world" text
  | _ -> Alcotest.fail "expected Send"

let test_parse_empty () =
  match Pera_cli.Input_loop.parse_line ~commands:no_commands "" with
  | Send "" -> ()
  | _ -> Alcotest.fail "expected Send \"\""

let test_expand_args () =
  let result =
    Pera_cli.Input_loop.expand_template ~template:"echo {args}" ~args:"a b c"
  in
  Alcotest.(check string) "args" "echo a b c" result

let test_expand_positional () =
  let result =
    Pera_cli.Input_loop.expand_template ~template:"{1} + {2}"
      ~args:"hello world"
  in
  Alcotest.(check string) "positional" "hello + world" result

let test_expand_positional_beyond () =
  let result =
    Pera_cli.Input_loop.expand_template ~template:"{1} {2} {3}" ~args:"a"
  in
  Alcotest.(check string) "beyond" "a  " result

let test_is_tty () =
  Alcotest.(check bool)
    "tty true" true
    (Pera_cli.Input_loop.is_tty ~stdin_isatty:true);
  Alcotest.(check bool)
    "tty false" false
    (Pera_cli.Input_loop.is_tty ~stdin_isatty:false)

let () =
  Alcotest.run "input_loop"
    [
      ( "parse_line",
        [
          Alcotest.test_case "/compact" `Quick test_parse_compact;
          Alcotest.test_case "/quit" `Quick test_parse_quit;
          Alcotest.test_case "/q" `Quick test_parse_q;
          Alcotest.test_case "/info" `Quick test_parse_info;
          Alcotest.test_case "custom command" `Quick test_parse_custom_command;
          Alcotest.test_case "unknown command" `Quick test_parse_unknown_command;
          Alcotest.test_case "plain text" `Quick test_parse_plain_text;
          Alcotest.test_case "empty" `Quick test_parse_empty;
        ] );
      ( "expand_template",
        [
          Alcotest.test_case "{args}" `Quick test_expand_args;
          Alcotest.test_case "{1} {2}" `Quick test_expand_positional;
          Alcotest.test_case "{3} beyond" `Quick test_expand_positional_beyond;
        ] );
      ("is_tty", [ Alcotest.test_case "basic" `Quick test_is_tty ]);
    ]
