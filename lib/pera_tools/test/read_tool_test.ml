open Containers
open Pera_tools
open Pera_env
open Pera_core.Agent_types
open Test_util

(* ── Truncate tests ────────────────────────────────────────────────────── *)

let test_truncate_head_under_limits_unchanged () =
  let content =
    String.concat "\n" (List.init 5 (fun i -> "line" ^ string_of_int (i + 1)))
  in
  let result_str, info = Truncate.truncate_head content in
  Alcotest.(check bool) "not truncated" false info.truncated;
  Alcotest.(check string) "content unchanged" content result_str

let test_truncate_head_over_line_limit () =
  let content =
    String.concat "\n" (List.init 2001 (fun i -> string_of_int (i + 1)))
  in
  let _result_str, info = Truncate.truncate_head content in
  Alcotest.(check bool) "truncated" true info.truncated;
  Alcotest.(check int) "output_lines" 2000 info.output_lines;
  Alcotest.(check bool)
    "truncated_by lines"
    (match info.truncated_by with Some `Lines -> true | _ -> false)
    true

let test_truncate_tail_shows_end () =
  let lines = List.init 2001 (fun i -> string_of_int (i + 1)) in
  let content = String.concat "\n" lines in
  let result_str, info = Truncate.truncate_tail content in
  Alcotest.(check bool) "truncated" true info.truncated;
  Alcotest.(check bool)
    "contains last line"
    (String.ends_with ~suffix:"2001" result_str)
    true;
  (* First kept line is "2" (line 1 was dropped by tail truncation) *)
  Alcotest.(check bool)
    "head line 1 dropped (tail shows last 2000)"
    (String.starts_with ~prefix:"2" (String.trim result_str))
    true

(* ── Read tool tests ───────────────────────────────────────────────────── *)

let run_read_test (body : (module Execution_env.S) -> Eio.Switch.t -> unit) =
  Eio_main.run @@ fun env ->
  let tmpdir = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  let module E =
    (val Pera_env.Local_env.create ~env ~cwd:tmpdir : Pera_env.Execution_env.S)
  in
  body (module E) sw

let test_read_returns_file_content () =
  run_read_test (fun (module E) sw ->
      let tool = Read_tool.read (module E) in
      write_file (module E) ~path:"hello.txt" ~content:"hello world" ~sw;
      let args = `Assoc [ ("path", `String "hello.txt") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "contains hello world" true
                (String.find ~sub:"hello world" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "read failed: %s" e.message))

let test_read_with_offset_skips_lines () =
  run_read_test (fun (module E) sw ->
      let tool = Read_tool.read (module E) in
      let lines = List.init 5 (fun i -> "line" ^ string_of_int (i + 1)) in
      let content = String.concat "\n" lines in
      write_file (module E) ~path:"test.txt" ~content ~sw;
      let args = `Assoc [ ("path", `String "test.txt"); ("offset", `Int 3) ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              let trimmed = String.trim s in
              Alcotest.(check bool)
                "starts with line3" true
                (String.starts_with ~prefix:"line3" trimmed)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "read failed: %s" e.message))

let test_read_with_limit_caps_output () =
  run_read_test (fun (module E) sw ->
      let tool = Read_tool.read (module E) in
      let lines = List.init 100 (fun i -> string_of_int (i + 1)) in
      let content = String.concat "\n" lines in
      write_file (module E) ~path:"limit_test.txt" ~content ~sw;
      let args =
        `Assoc [ ("path", `String "limit_test.txt"); ("limit", `Int 5) ]
      in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              let output_lines =
                String.trim s |> String.split_on_char '\n'
                |> List.filter (fun line ->
                    (not (String.is_empty line))
                    && not (String.starts_with ~prefix:"[" line))
              in
              Alcotest.(check int)
                "5 lines of content" 5 (List.length output_lines);
              Alcotest.(check bool)
                "footer mentions remaining" true
                (String.find ~sub:"remaining" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "read failed: %s" e.message))

let test_read_missing_file_returns_error () =
  run_read_test (fun (module E) sw ->
      let tool = Read_tool.read (module E) in
      let args = `Assoc [ ("path", `String "does_not_exist.txt") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Error e ->
              Alcotest.(check bool) "is_user_error false" false e.is_user_error
          | Ok _ -> Alcotest.fail "expected Error for missing file"))

let test_read_truncates_at_line_limit () =
  run_read_test (fun (module E) sw ->
      let tool = Read_tool.read (module E) in
      let lines = List.init 2001 (fun i -> string_of_int (i + 1)) in
      let content = String.concat "\n" lines in
      write_file (module E) ~path:"many_lines.txt" ~content ~sw;
      let args = `Assoc [ ("path", `String "many_lines.txt") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "contains Use offset=" true
                (String.find ~sub:"Use offset=" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "read failed: %s" e.message))

let test_read_offset_beyond_eof_returns_user_error () =
  run_read_test (fun (module E) sw ->
      let tool = Read_tool.read (module E) in
      let lines = List.init 5 (fun i -> "line" ^ string_of_int (i + 1)) in
      let content = String.concat "\n" lines in
      write_file (module E) ~path:"short.txt" ~content ~sw;
      let args =
        `Assoc [ ("path", `String "short.txt"); ("offset", `Int 10) ]
      in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Error e ->
              Alcotest.(check bool) "is_user_error true" true e.is_user_error
          | Ok _ -> Alcotest.fail "expected Error for offset beyond EOF"))

let () =
  Alcotest.run "read_tool"
    [
      ( "truncate_head",
        [
          Alcotest.test_case "under_limits_unchanged" `Quick
            test_truncate_head_under_limits_unchanged;
          Alcotest.test_case "over_line_limit" `Quick
            test_truncate_head_over_line_limit;
        ] );
      ( "truncate_tail",
        [ Alcotest.test_case "shows_end" `Quick test_truncate_tail_shows_end ]
      );
      ( "read_tool",
        [
          Alcotest.test_case "returns_file_content" `Quick
            test_read_returns_file_content;
          Alcotest.test_case "with_offset_skips_lines" `Quick
            test_read_with_offset_skips_lines;
          Alcotest.test_case "with_limit_caps_output" `Quick
            test_read_with_limit_caps_output;
          Alcotest.test_case "missing_file_returns_error" `Quick
            test_read_missing_file_returns_error;
          Alcotest.test_case "truncates_at_line_limit" `Quick
            test_read_truncates_at_line_limit;
          Alcotest.test_case "offset_beyond_eof_returns_user_error" `Quick
            test_read_offset_beyond_eof_returns_user_error;
        ] );
    ]
