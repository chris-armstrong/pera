open Containers
open Pera_env
open Harness_test_util

(** {1 Helpers} *)

(** Trim trailing newline from a string. *)
let trim_trailing_newline s =
  if String.ends_with ~suffix:"\n" s then String.sub s 0 (String.length s - 1)
  else s

(** {1 Test cases} *)

(** Run a command returning its combined result.

    Passes callbacks for both stdout and stderr (matching the pattern used by
    the bash tool) to ensure pipe readers are scheduled correctly. *)
let exec_cmd ~sw ~command ?timeout (module E : Execution_env.S) =
  let open Result.Syntax in
  let out_buf = Buffer.create 256 in
  let err_buf = Buffer.create 256 in
  Eio.Cancel.sub (fun cancel ->
      let* result =
        E.Sh.exec ~command
          ?cwd:(None : string option)
          ?env:(None : (string * string) list option)
          ?timeout
          ~on_stdout:(fun s -> Buffer.add_string out_buf s)
          ~on_stderr:(fun s -> Buffer.add_string err_buf s)
          ~sw ~cancel
      in
      Ok
        {
          Execution_env.stdout = Buffer.contents out_buf;
          stderr = Buffer.contents err_buf;
          exit_code = result.exit_code;
        })

(** Verify that executing a simple command captures stdout. *)
let test_exec_returns_stdout sw (module E : Execution_env.S) =
  match exec_cmd ~sw ~command:"echo hello" (module E) with
  | Error e -> Alcotest.failf "exec failed: %s" e.message
  | Ok result ->
      let stdout_trimmed = trim_trailing_newline result.stdout in
      let ok = String.equal stdout_trimmed "hello" in
      if not ok then
        Alcotest.failf "expected stdout 'hello', got '%S' (exit_code=%d)"
          result.stdout result.exit_code;
      Alcotest.(check int) "exit code" 0 result.exit_code

(** Verify that stderr output is captured separately from stdout. *)
let test_exec_captures_stderr sw (module E : Execution_env.S) =
  match exec_cmd ~sw ~command:"echo hello 1>&2" (module E) with
  | Error e -> Alcotest.failf "exec failed: %s" e.message
  | Ok result ->
      (* stdout should be empty, stderr should have "hello" *)
      let stderr_trimmed = trim_trailing_newline result.stderr in
      let ok =
        String.equal result.stdout "" && String.equal stderr_trimmed "hello"
      in
      if not ok then
        Alcotest.failf
          "expected stdout='' stderr='hello', got stdout='%S' stderr='%S' \
           (exit_code=%d)"
          result.stdout result.stderr result.exit_code;
      Alcotest.(check int) "exit code" 0 result.exit_code

(** Verify that a non-zero exit code is surfaced correctly. *)
let test_exec_nonzero_exit_code sw (module E : Execution_env.S) =
  match exec_cmd ~sw ~command:"exit 42" (module E) with
  | Error e -> Alcotest.failf "exec failed: %s" e.message
  | Ok result -> Alcotest.(check int) "exit code" 42 result.exit_code

(** Verify that a timeout returns an error with Timeout code. *)
let test_exec_timeout_returns_error sw (module E : Execution_env.S) =
  match exec_cmd ~sw ~command:"sleep 10" ~timeout:0.1 (module E) with
  | Ok _ -> Alcotest.fail "expected timeout error but command succeeded"
  | Error e ->
      if not (Pera_types.Types.equal_execution_error_code e.code Timeout) then
        Alcotest.failf "expected Timeout error code but got %a"
          Pera_types.Types.pp_execution_error_code e.code

(** Verify that [find_executable] can locate [/bin/sh]. *)
let test_find_executable_finds_sh (module E : Execution_env.S) =
  match E.Sh.find_executable ~name:"sh" with
  | None -> Alcotest.fail "find_executable did not find 'sh' on PATH"
  | Some path ->
      Alcotest.(check bool)
        "path is absolute" true
        (String.starts_with ~prefix:"/" path)

(** {1 Suite registration} *)

let () =
  Eio_main.run @@ fun env ->
  let tmpdir = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  let module E = (val Local_env.create ~env ~cwd:tmpdir : Execution_env.S) in
  Alcotest.run "local_env_sh"
    [
      ( "exec",
        [
          Alcotest.test_case "returns_stdout" `Quick (fun () ->
              test_exec_returns_stdout sw (module E));
          Alcotest.test_case "captures_stderr" `Quick (fun () ->
              test_exec_captures_stderr sw (module E));
          Alcotest.test_case "nonzero_exit_code" `Quick (fun () ->
              test_exec_nonzero_exit_code sw (module E));
          Alcotest.test_case "timeout_returns_error" `Quick (fun () ->
              test_exec_timeout_returns_error sw (module E));
        ] );
      ( "find_executable",
        [
          Alcotest.test_case "finds_sh" `Quick (fun () ->
              test_find_executable_finds_sh (module E));
        ] );
    ]
