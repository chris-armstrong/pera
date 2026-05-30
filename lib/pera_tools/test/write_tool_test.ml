open Containers
open Pera_tools
open Pera_harness
open Pera_core.Agent_types
open Test_util

let make_temp_dir env =
  let tmpdir = Filename.get_temp_dir_name () in
  let buf = Cstruct.create 8 in
  Eio.Flow.read_exact env#secure_random buf;
  let bytes = Cstruct.to_string buf in
  let len = String.length bytes in
  let hex_chars = ref [] in
  for i = 0 to len - 1 do
    let code = Char.code (String.get bytes i) in
    hex_chars := Printf.sprintf "%02x" code :: !hex_chars
  done;
  let hex = String.concat "" (List.rev !hex_chars) in
  let path = Filename.concat tmpdir ("pera_test_" ^ hex) in
  Eio.Path.(mkdirs ~exists_ok:false ~perm:0o700 (env#fs / path));
  path

let cleanup tmpdir =
  try
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote tmpdir) in
    ignore (Sys.command cmd)
  with _ -> ()

(** Write a file via env, asserting success for test setup. *)
let write_file (module E : Execution_env.S) ~path ~content ~sw =
  match E.Fs.write_file ~path ~content ~sw with
  | Ok () -> ()
  | Error e -> Alcotest.failf "write_file %s failed: %s" path e.message

let run_write_test (body : (module Execution_env.S) -> Eio.Switch.t -> unit) =
  Eio_main.run @@ fun env ->
  let tmpdir = make_temp_dir env in
  (try
     Eio.Switch.run @@ fun sw ->
     let module E =
       (val Pera_harness.Local_env.create ~env ~cwd:tmpdir
           : Pera_harness.Execution_env.S)
     in
     body (module E) sw
   with e ->
     cleanup tmpdir;
     raise e);
  cleanup tmpdir

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
                (is_substring ~sub:"5 bytes written" s)
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
