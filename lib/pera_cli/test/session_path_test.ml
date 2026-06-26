open Containers

let fixed_time =
  Unix.
    {
      tm_year = 124;
      tm_mon = 5;
      tm_mday = 26;
      tm_hour = 10;
      tm_min = 30;
      tm_sec = 0;
      tm_wday = 3;
      tm_yday = 177;
      tm_isdst = false;
    }

let fixed_random buf = Bytes.fill buf 0 (Bytes.length buf) '\x00'

let test_filename_pattern () =
  let name =
    Pera_cli.Session_path.generate_filename ~secure_random:fixed_random
      ~wall_time:(fun () -> fixed_time)
  in
  let re =
    Re.(
      compile
        (seq
           [
             repn digit 8 (Some 8);
             char '_';
             repn digit 6 (Some 6);
             char '_';
             repn (alt [ alnum; char '-' ]) 36 (Some 36);
             str ".jsonl";
             eos;
           ]))
  in
  Alcotest.(check bool) "matches filename pattern" true (Re.execp re name)

let test_filename_date_content () =
  let name =
    Pera_cli.Session_path.generate_filename ~secure_random:fixed_random
      ~wall_time:(fun () -> fixed_time)
  in
  Alcotest.(check bool)
    "starts with expected date prefix" true
    (String.prefix ~pre:"20240626_103000_" name)

let test_resolve_with_override () =
  let path =
    Pera_cli.Session_path.resolve
      ~session_override:(Some "/tmp/my-session.jsonl") ~session_dir:"/sessions"
      ~secure_random:fixed_random ~wall_time:(fun () -> fixed_time)
  in
  Alcotest.(check string) "returns override path" "/tmp/my-session.jsonl" path

let test_resolve_without_override () =
  let path =
    Pera_cli.Session_path.resolve ~session_override:None
      ~session_dir:"/sessions" ~secure_random:fixed_random ~wall_time:(fun () ->
        fixed_time)
  in
  Alcotest.(check bool)
    "starts with session_dir" true
    (String.prefix ~pre:"/sessions/" path);
  Alcotest.(check bool)
    "ends with .jsonl" true
    (String.suffix ~suf:".jsonl" path)

let test_default_session_dir () =
  let dir = Pera_cli.Session_path.default_session_dir "/home/alice" in
  Alcotest.(check string)
    "correct sessions path" "/home/alice/.local/state/pera/sessions" dir

let suite =
  [
    ("filename matches pattern", `Quick, test_filename_pattern);
    ("filename contains date and time", `Quick, test_filename_date_content);
    ("resolve with override", `Quick, test_resolve_with_override);
    ("resolve without override", `Quick, test_resolve_without_override);
    ("default_session_dir", `Quick, test_default_session_dir);
  ]

let () = Alcotest.run "session_path" [ ("session_path", suite) ]
