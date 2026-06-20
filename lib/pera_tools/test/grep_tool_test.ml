open Containers
open Pera_tools
open Pera_env
open Pera_core.Agent_types
open Test_util

(** Check if ripgrep is available in the environment, skipping the test if not.
*)
let require_rg (module E : Execution_env.S) =
  (* nosemgrep: semgrep.no-silent-none-ignore *)
  match E.Sh.find_executable ~name:"rg" with
  | Some _ -> ()
  | None -> Alcotest.skip ()

(** Test runner for grep tests that need a real env. Exceptions (including
    Alcotest failures and skips) propagate to the test runner after cleanup. *)
let run_grep_test (body : (module Execution_env.S) -> Eio.Switch.t -> unit) =
  Eio_main.run @@ fun env ->
  let tmpdir = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  let module E =
    (val Pera_env.Local_env.create ~env ~cwd:tmpdir : Pera_env.Execution_env.S)
  in
  require_rg (module E);
  body (module E) sw

(* ── Grep tool tests ────────────────────────────────────────────────────── *)

let test_grep_finds_pattern_in_file () =
  run_grep_test (fun (module E) sw ->
      let tool = Grep_tool.grep (module E) in
      write_file (module E) ~path:"test.ml" ~content:"foo bar baz" ~sw;
      let args = `Assoc [ ("pattern", `String "foo") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "output contains test.ml" true
                (String.find ~sub:"test.ml" s >= 0);
              Alcotest.(check bool)
                "output contains matched line" true
                (String.find ~sub:"foo bar baz" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "grep failed: %s" e.message))

let test_grep_no_match_returns_message () =
  run_grep_test (fun (module E) sw ->
      let tool = Grep_tool.grep (module E) in
      write_file (module E) ~path:"hello.txt" ~content:"hello world" ~sw;
      let args = `Assoc [ ("pattern", `String "xyz") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check string)
                "no matches message" "No matches found." (String.trim s)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "grep failed: %s" e.message))

let test_grep_caps_at_100_matches () =
  run_grep_test (fun (module E) sw ->
      let tool = Grep_tool.grep (module E) in
      let lines = List.init 200 (fun i -> "match" ^ string_of_int i) in
      let content = String.concat "\n" lines in
      write_file (module E) ~path:"many.txt" ~content ~sw;
      let args = `Assoc [ ("pattern", `String "^match") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              let output_lines =
                String.trim s |> String.split_on_char '\n'
                |> List.filter (fun line ->
                    (not (String.is_empty line))
                    && not (String.find ~sub:"Match limit" line >= 0))
              in
              Alcotest.(check bool)
                "at most 100 match lines" true
                (List.length output_lines <= 100);
              Alcotest.(check bool)
                "contains cap notice" true
                (String.find ~sub:"Match limit" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "grep failed: %s" e.message))

let test_grep_glob_filters_file_types () =
  run_grep_test (fun (module E) sw ->
      let tool = Grep_tool.grep (module E) in
      write_file (module E) ~path:"file.ml" ~content:"target" ~sw;
      write_file (module E) ~path:"file.py" ~content:"target" ~sw;
      let args =
        `Assoc [ ("pattern", `String "target"); ("glob", `String "*.ml") ]
      in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "file.ml found" true
                (String.find ~sub:"file.ml" s >= 0);
              Alcotest.(check bool)
                "file.py absent" false
                (String.find ~sub:"file.py" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "grep failed: %s" e.message))

let test_grep_ripgrep_not_found_returns_error () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let module E =
    (val Pera_env.Local_env.create ~env ~cwd:"/tmp" : Pera_env.Execution_env.S)
  in
  let module MockSh = struct
    let exec = E.Sh.exec
    let find_executable ~name:_ = None
  end in
  let module MockEnv = struct
    module Fs = E.Fs
    module Sh = MockSh
  end in
  let tool = Grep_tool.grep (module MockEnv) in
  let args = `Assoc [ ("pattern", `String "foo") ] in
  Eio.Cancel.sub (fun cancel ->
      match tool.execute ~ctx:() ~args ~sw ~cancel with
      | Error e ->
          Alcotest.(check bool) "is_user_error false" false e.is_user_error;
          Alcotest.(check bool)
            "message contains ripgrep" true
            (String.find ~sub:"ripgrep" e.message >= 0)
      | Ok _ -> Alcotest.fail "expected Error for rg not found")

let () =
  Alcotest.run "grep_tool"
    [
      ( "grep_tool",
        [
          Alcotest.test_case "finds_pattern_in_file" `Quick
            test_grep_finds_pattern_in_file;
          Alcotest.test_case "no_match_returns_message" `Quick
            test_grep_no_match_returns_message;
          Alcotest.test_case "caps_at_100_matches" `Quick
            test_grep_caps_at_100_matches;
          Alcotest.test_case "glob_filters_file_types" `Quick
            test_grep_glob_filters_file_types;
          Alcotest.test_case "ripgrep_not_found_returns_error" `Quick
            test_grep_ripgrep_not_found_returns_error;
        ] );
    ]
