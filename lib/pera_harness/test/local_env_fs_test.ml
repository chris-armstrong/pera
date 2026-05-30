open Containers
open Pera_harness

(* Helper: create a temporary directory *)
let mkdtemp () =
  let tmpdir : string = Filename.get_temp_dir_name () in
  let pid = Unix.getpid () in
  let time = int_of_float (Unix.time ()) in
  let suffix = Printf.sprintf "%d_%d" pid time in
  let path = Filename.concat tmpdir ("pera_test_" ^ suffix) in
  Unix.mkdir path 0o755;
  path

(* Define Alcotest testables for domain types *)

let file_kind_pp fmt = function
  | `File -> Format.pp_print_string fmt "File"
  | `Directory -> Format.pp_print_string fmt "Directory"
  | `Symlink -> Format.pp_print_string fmt "Symlink"

let file_kind_equal a b =
  match (a, b) with
  | `File, `File | `Directory, `Directory | `Symlink, `Symlink -> true
  | _ -> false

let file_kind_testable = Alcotest.testable file_kind_pp file_kind_equal
let file_error_code_pp fmt c = Pera_types.Types.pp_file_error_code fmt c
let file_error_code_equal = Pera_types.Types.equal_file_error_code

let () =
  let tmpdir = mkdtemp () in
  let cleanup () =
    try
      let cmd = Printf.sprintf "rm -rf %s" (Filename.quote tmpdir) in
      ignore (Sys.command cmd)
    with _ -> ()
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let module E = (val Local_env.create ~env ~cwd:tmpdir : Execution_env.S) in
  let open Result.Syntax in
  Alcotest.run "local_env_fs"
    [
      ( "read_text_file",
        [
          Alcotest.test_case "returns content" `Quick (fun () ->
              match
                let* () =
                  E.Fs.write_file ~path:"hello.txt" ~content:"hello world" ~sw
                in
                E.Fs.read_text_file ~path:"hello.txt" ~sw
              with
              | Ok content ->
                  Alcotest.(check string) "content" "hello world" content
              | Error e -> Alcotest.failf "read_text_file failed: %s" e.message);
          Alcotest.test_case "missing returns NotFound" `Quick (fun () ->
              match E.Fs.read_text_file ~path:"nonexistent.txt" ~sw with
              | Ok _ -> Alcotest.fail "expected Error for missing file"
              | Error e ->
                  if not (file_error_code_equal e.code NotFound) then
                    Alcotest.failf "expected NotFound, got %a"
                      file_error_code_pp e.code);
        ] );
      ( "write_file",
        [
          Alcotest.test_case "creates and is readable" `Quick (fun () ->
              match
                let* () =
                  E.Fs.write_file ~path:"new_file.txt" ~content:"content" ~sw
                in
                E.Fs.read_text_file ~path:"new_file.txt" ~sw
              with
              | Ok read_back ->
                  Alcotest.(check string) "content" "content" read_back
              | Error e -> Alcotest.failf "write/read failed: %s" e.message);
          Alcotest.test_case "creates parent dirs" `Quick (fun () ->
              match
                let* () =
                  E.Fs.write_file ~path:"a/b/c.txt" ~content:"nested" ~sw
                in
                E.Fs.exists ~path:"a/b/c.txt" ~sw
              with
              | Ok exists ->
                  Alcotest.(check bool) "nested file exists" true exists
              | Error e -> Alcotest.failf "write/exists failed: %s" e.message);
        ] );
      ( "append_file",
        [
          Alcotest.test_case "appends content" `Quick (fun () ->
              match
                let* () =
                  E.Fs.write_file ~path:"append_test.txt" ~content:"hello" ~sw
                in
                let* () =
                  E.Fs.append_file ~path:"append_test.txt" ~content:" world" ~sw
                in
                E.Fs.read_text_file ~path:"append_test.txt" ~sw
              with
              | Ok content ->
                  Alcotest.(check string) "content" "hello world" content
              | Error e -> Alcotest.failf "append/read failed: %s" e.message);
        ] );
      ( "list_dir",
        [
          Alcotest.test_case "returns entries" `Quick (fun () ->
              match
                let* () = E.Fs.create_dir ~path:"listdir_test" ~sw in
                let* () =
                  E.Fs.write_file ~path:"listdir_test/file_a.txt" ~content:"a"
                    ~sw
                in
                let* () =
                  E.Fs.write_file ~path:"listdir_test/file_b.txt" ~content:"b"
                    ~sw
                in
                E.Fs.list_dir ~path:"listdir_test" ~sw
              with
              | Ok entries ->
                  Alcotest.(check int) "two entries" 2 (List.length entries);
                  let names =
                    List.map
                      (fun (e : Execution_env.file_info) -> e.name)
                      entries
                  in
                  if not (List.mem ~eq:String.equal "file_a.txt" names) then
                    Alcotest.fail "expected file_a.txt in listing";
                  if not (List.mem ~eq:String.equal "file_b.txt" names) then
                    Alcotest.fail "expected file_b.txt in listing"
              | Error e -> Alcotest.failf "list_dir failed: %s" e.message);
        ] );
      ( "file_info",
        [
          Alcotest.test_case "returns correct metadata" `Quick (fun () ->
              match
                let* () =
                  E.Fs.write_file ~path:"meta_test.txt" ~content:"hello" ~sw
                in
                E.Fs.file_info ~path:"meta_test.txt" ~sw
              with
              | Ok info ->
                  Alcotest.(check file_kind_testable) "kind" `File info.kind;
                  Alcotest.(check int) "size" 5 info.size
              | Error e -> Alcotest.failf "file_info failed: %s" e.message);
        ] );
      ( "exists",
        [
          Alcotest.test_case "true for existing" `Quick (fun () ->
              match
                let* () =
                  E.Fs.write_file ~path:"exists_test.txt" ~content:"test" ~sw
                in
                E.Fs.exists ~path:"exists_test.txt" ~sw
              with
              | Ok exists -> Alcotest.(check bool) "file exists" true exists
              | Error e -> Alcotest.failf "exists failed: %s" e.message);
          Alcotest.test_case "false for missing" `Quick (fun () ->
              match E.Fs.exists ~path:"does_not_exist_12345" ~sw with
              | Error e ->
                  Alcotest.failf "expected Ok false but got Error: %s" e.message
              | Ok false -> ()
              | Ok true -> Alcotest.fail "expected false for missing file");
        ] );
      ( "create_dir",
        [
          Alcotest.test_case "makes directory" `Quick (fun () ->
              match
                let* () = E.Fs.create_dir ~path:"newdir" ~sw in
                E.Fs.file_info ~path:"newdir" ~sw
              with
              | Ok info ->
                  Alcotest.(check file_kind_testable)
                    "kind" `Directory info.kind
              | Error e ->
                  Alcotest.failf "create_dir/file_info failed: %s" e.message);
        ] );
      ( "absolute_path",
        [
          Alcotest.test_case "resolves relative" `Quick (fun () ->
              match E.Fs.absolute_path "foo/bar" with
              | Error e ->
                  Alcotest.failf "expected Ok but got Error: %s" e.message
              | Ok resolved ->
                  let expected = tmpdir ^ "/foo/bar" in
                  Alcotest.(check string) "resolved path" expected resolved);
          Alcotest.test_case "passes through absolute" `Quick (fun () ->
              match E.Fs.absolute_path "/etc/hosts" with
              | Error e ->
                  Alcotest.failf "expected Ok but got Error: %s" e.message
              | Ok resolved ->
                  Alcotest.(check string) "unchanged" "/etc/hosts" resolved);
        ] );
    ];
  cleanup ()
