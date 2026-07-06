open Containers
open Pera_env
open Harness_test_util

(** {1 Helpers} *)

(** Create a persistent shell for testing. *)
let make_shell ~env ~sw ~cwd =
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let shell_env = Unix.environment () in
  Persistent_shell.create ~proc_mgr ~clock ~sw ~env:shell_env ~cwd ()

(** Run a command through the persistent shell, returning the result. *)
let exec_cmd ~sw ~cancel ~command ?timeout shell =
  let out_buf = Buffer.create 256 in
  let err_buf = Buffer.create 256 in
  Persistent_shell.exec shell ~command
    ~on_stdout:(fun s -> Buffer.add_string out_buf s)
    ~on_stderr:(fun s -> Buffer.add_string err_buf s)
    ?timeout ~sw ~cancel ()

(** Trim trailing newline from a string. *)
let trim_trailing_newline s =
  if String.ends_with ~suffix:"\n" s then String.sub s 0 (String.length s - 1)
  else s

(** {1 Test cases} *)

(** Verify that executing a simple command captures stdout. *)
let test_exec_returns_stdout ~env ~sw ~cwd =
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      match exec_cmd ~sw ~cancel ~command:"echo hello" shell with
      | Error e -> Alcotest.failf "exec failed: %s" e.message
      | Ok result ->
          let stdout_trimmed = trim_trailing_newline result.stdout in
          let ok = String.equal stdout_trimmed "hello" in
          if not ok then
            Alcotest.failf "expected stdout 'hello', got '%S' (exit_code=%d)"
              result.stdout result.exit_code;
          Alcotest.(check int) "exit code" 0 result.exit_code)

(** Verify that a non-zero exit code is surfaced correctly. *)
let test_exec_nonzero_exit_code ~env ~sw ~cwd =
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      match exec_cmd ~sw ~cancel ~command:"sh -c 'exit 42'" shell with
      | Error e -> Alcotest.failf "exec failed: %s" e.message
      | Ok result -> Alcotest.(check int) "exit code" 42 result.exit_code)

(** Verify that stdout and stderr are both populated and correctly tagged. *)
let test_stdout_and_stderr ~env ~sw ~cwd =
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      match exec_cmd ~sw ~cancel ~command:"echo out; echo err 1>&2" shell with
      | Error e -> Alcotest.failf "exec failed: %s" e.message
      | Ok result ->
          let stdout_trimmed = trim_trailing_newline result.stdout in
          let stderr_trimmed = trim_trailing_newline result.stderr in
          let ok =
            String.equal stdout_trimmed "out"
            && String.equal stderr_trimmed "err"
          in
          if not ok then
            Alcotest.failf
              "expected stdout='out' stderr='err', got stdout='%S' stderr='%S' \
               (exit_code=%d)"
              result.stdout result.stderr result.exit_code;
          Alcotest.(check int) "exit code" 0 result.exit_code)

(** Verify that cwd persists across two exec calls. *)
let test_cwd_persistence ~env ~sw ~cwd =
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      (* First call: cd to a directory *)
      (match exec_cmd ~sw ~cancel ~command:"cd /" shell with
      | Error e -> Alcotest.failf "first exec failed: %s" e.message
      | Ok _ -> ());
      (* Second call: pwd should reflect the new cwd *)
      match exec_cmd ~sw ~cancel ~command:"pwd" shell with
      | Error e -> Alcotest.failf "second exec failed: %s" e.message
      | Ok result ->
          let pwd = trim_trailing_newline result.stdout in
          if not (String.equal pwd "/") then
            Alcotest.failf
              "expected cwd to be '/', got '%S' (exit_code=%d)" pwd
              result.exit_code;
          Alcotest.(check int) "exit code" 0 result.exit_code)

(** Verify that env vars persist across two exec calls. *)
let test_env_persistence ~env ~sw ~cwd =
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      (* First call: export a variable *)
      (match exec_cmd ~sw ~cancel ~command:"export FOO=bar" shell with
      | Error e -> Alcotest.failf "first exec failed: %s" e.message
      | Ok _ -> ());
      (* Second call: echo the variable *)
      match exec_cmd ~sw ~cancel ~command:"echo $FOO" shell with
      | Error e -> Alcotest.failf "second exec failed: %s" e.message
      | Ok result ->
          let val_ = trim_trailing_newline result.stdout in
          if not (String.equal val_ "bar") then
            Alcotest.failf "expected FOO='bar', got '%S' (exit_code=%d)" val_
              result.exit_code;
          Alcotest.(check int) "exit code" 0 result.exit_code)

(** Verify that a timeout returns an error with Timeout code. *)
let test_exec_timeout_returns_error ~env ~sw ~cwd =
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      match exec_cmd ~sw ~cancel ~command:"sleep 10" ~timeout:0.1 shell with
      | Ok _ -> Alcotest.fail "expected timeout error but command succeeded"
      | Error e ->
          if not (Pera_types.Types.equal_execution_error_code e.code Timeout)
          then
            Alcotest.failf "expected Timeout error code but got %a"
              Pera_types.Types.pp_execution_error_code e.code)

(** Verify that chunks are populated with correct stream tags. *)
let test_chunks_have_stream_tags ~env ~sw ~cwd =
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      match exec_cmd ~sw ~cancel ~command:"echo out; echo err 1>&2" shell with
      | Error e -> Alcotest.failf "exec failed: %s" e.message
      | Ok result ->
          let stdout_chunks =
            List.filter
              (fun (c : Execution_env.output_chunk) ->
                match c.stream with Stdout -> true | Stderr -> false)
              result.chunks
          in
          let stderr_chunks =
            List.filter
              (fun (c : Execution_env.output_chunk) ->
                match c.stream with Stderr -> true | Stdout -> false)
              result.chunks
          in
          let has_stdout =
            List.exists
              (fun (c : Execution_env.output_chunk) ->
                try
                  let _ = String.index c.line 'o' in
                  let _ = String.index c.line 'u' in
                  let _ = String.index c.line 't' in
                  true
                with Not_found -> false)
              stdout_chunks
          in
          let has_stderr =
            List.exists
              (fun (c : Execution_env.output_chunk) ->
                try
                  let _ = String.index c.line 'e' in
                  let _ = String.index c.line 'r' in
                  let _ = String.index c.line 'r' in
                  true
                with Not_found -> false)
              stderr_chunks
          in
          if not has_stdout then
            Alcotest.fail "expected stdout chunk with 'out'";
          if not has_stderr then
            Alcotest.fail "expected stderr chunk with 'err'")

(** {1 Suite registration} *)

let () =
  Eio_main.run @@ fun env ->
  let cwd = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  Alcotest.run "persistent_shell"
    [
      ( "exec",
        [
          Alcotest.test_case "returns_stdout" `Quick (fun () ->
              test_exec_returns_stdout ~env ~sw ~cwd);
          Alcotest.test_case "nonzero_exit_code" `Quick (fun () ->
              test_exec_nonzero_exit_code ~env ~sw ~cwd);
          Alcotest.test_case "stdout_and_stderr" `Quick (fun () ->
              test_stdout_and_stderr ~env ~sw ~cwd);
          Alcotest.test_case "cwd_persistence" `Quick (fun () ->
              test_cwd_persistence ~env ~sw ~cwd);
          Alcotest.test_case "env_persistence" `Quick (fun () ->
              test_env_persistence ~env ~sw ~cwd);
          Alcotest.test_case "timeout_returns_error" `Quick (fun () ->
              test_exec_timeout_returns_error ~env ~sw ~cwd);
          Alcotest.test_case "chunks_have_stream_tags" `Quick (fun () ->
              test_chunks_have_stream_tags ~env ~sw ~cwd);
        ] );
    ]
