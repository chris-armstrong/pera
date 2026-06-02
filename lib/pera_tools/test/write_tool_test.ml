[@@@warning "-33"]

open Containers
open Pera_tools
open Pera_harness
open Pera_core.Agent_types
open Test_util

let run_write_test (body : (module Execution_env.S) -> Eio.Switch.t -> unit) =
  Eio_main.run @@ fun env ->
  let tmpdir = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  let module E =
    (val Pera_harness.Local_env.create ~env ~cwd:tmpdir
        : Pera_harness.Execution_env.S)
  in
  body (module E) sw

(* ── Write tool tests ──────────────────────────────────────────────────── *)

let test_write_creates_file_with_correct_content () =
  run_write_test (fun (module E) sw ->
      let tool = Write_tool.write (module E) in
      let args =
        `Assoc
          [ ("path", `String "out.txt"); ("content", `String "hello world") ]
      in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text _) -> (
              (* Verify content via env *)
              match E.Fs.read_text_file ~path:"out.txt" ~sw with
              | Ok content ->
                  Alcotest.(check string) "file content" "hello world" content
              | Error e ->
                  Alcotest.failf "failed to read back file: %s" e.message)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "write failed: %s" e.message))

let test_write_creates_parent_directories () =
  run_write_test (fun (module E) sw ->
      let tool = Write_tool.write (module E) in
      let args =
        `Assoc [ ("path", `String "a/b/c.txt"); ("content", `String "nested") ]
      in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text _) -> (
              match E.Fs.exists ~path:"a/b/c.txt" ~sw with
              | Ok true -> ()
              | Ok false -> Alcotest.fail "expected file at a/b/c.txt to exist"
              | Error e ->
                  Alcotest.failf "failed to check file existence: %s" e.message)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e ->
              Alcotest.failf "write to nested path failed: %s" e.message))

let test_write_overwrites_existing_file () =
  run_write_test (fun (module E) sw ->
      let tool = Write_tool.write (module E) in
      (* Write first content *)
      write_file (module E) ~path:"overwrite.txt" ~content:"first version" ~sw;
      (* Write second content via tool *)
      let args =
        `Assoc
          [
            ("path", `String "overwrite.txt");
            ("content", `String "second version");
          ]
      in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text _) -> (
              match E.Fs.read_text_file ~path:"overwrite.txt" ~sw with
              | Ok content ->
                  Alcotest.(check string)
                    "overwritten content" "second version" content
              | Error e ->
                  Alcotest.failf "failed to read back file: %s" e.message)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "write overwrite failed: %s" e.message))

let test_write_returns_bytes_written () =
  run_write_test (fun (module E) sw ->
      let tool = Write_tool.write (module E) in
      let args =
        `Assoc
          [ ("path", `String "bytes_test.txt"); ("content", `String "hello") ]
      in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "reports 5 bytes written" true
                (String.find ~sub:"5 bytes written" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "write failed: %s" e.message))

let () =
  Alcotest.run "write_tool"
    [
      ( "write_tool",
        [
          Alcotest.test_case "creates_file_with_correct_content" `Quick
            test_write_creates_file_with_correct_content;
          Alcotest.test_case "creates_parent_directories" `Quick
            test_write_creates_parent_directories;
          Alcotest.test_case "overwrites_existing_file" `Quick
            test_write_overwrites_existing_file;
          Alcotest.test_case "returns_bytes_written" `Quick
            test_write_returns_bytes_written;
        ] );
    ]
