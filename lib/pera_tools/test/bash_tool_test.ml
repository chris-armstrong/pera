open Containers
open Pera_tools
open Pera_env
open Pera_core.Agent_types
open Test_util

let run_bash_test (body : (module Execution_env.S) -> Eio.Switch.t -> unit) =
  Eio_main.run @@ fun env ->
  let tmpdir = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  let module E =
    (val Pera_env.Local_env.create ~env ~cwd:tmpdir : Pera_env.Execution_env.S)
  in
  body (module E) sw

(* ── Bash tool tests ────────────────────────────────────────────────────── *)

let test_bash_returns_stdout_on_success () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash in
      let args = `Assoc [ ("command", `String "echo hello") ] in
      Eio.Cancel.sub (fun cancel ->
          match Tool.execute tool ~ctx:(module E : Pera_env.Execution_env.S) ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "contains hello" true
                (String.find ~sub:"hello" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "bash failed: %s" e.message))

let test_bash_nonzero_exit_returns_error () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash in
      let args = `Assoc [ ("command", `String "exit 42") ] in
      Eio.Cancel.sub (fun cancel ->
          match Tool.execute tool ~ctx:(module E : Pera_env.Execution_env.S) ~args ~sw ~cancel with
          | Error e ->
              Alcotest.(check bool) "is_user_error false" false e.is_user_error;
              Alcotest.(check bool)
                "message contains 42" true
                (String.find ~sub:"42" e.message >= 0)
          | Ok _ -> Alcotest.fail "expected Error for non-zero exit"))

let test_bash_stderr_in_combined_output () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash in
      let args = `Assoc [ ("command", `String "echo err >&2 && exit 0") ] in
      Eio.Cancel.sub (fun cancel ->
          match Tool.execute tool ~ctx:(module E : Pera_env.Execution_env.S) ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "stderr content in combined output" true
                (String.find ~sub:"err" s >= 0)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "bash failed: %s" e.message))

let test_bash_timeout_returns_error () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash in
      let args =
        `Assoc [ ("command", `String "sleep 10"); ("timeout", `Float 0.05) ]
      in
      Eio.Cancel.sub (fun cancel ->
          match Tool.execute tool ~ctx:(module E : Pera_env.Execution_env.S) ~args ~sw ~cancel with
          | Error e ->
              Alcotest.(check bool) "is_user_error false" false e.is_user_error
          | Ok _ -> Alcotest.fail "expected Error for timed-out command"))

let test_bash_no_output_command_returns_no_output () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash in
      let args = `Assoc [ ("command", `String "true") ] in
      Eio.Cancel.sub (fun cancel ->
          match Tool.execute tool ~ctx:(module E : Pera_env.Execution_env.S) ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "(no output) text" true
                (String.equal s "(no output)")
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "bash failed: %s" e.message))

let test_bash_tail_truncation_preserves_end () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash in
      let args = `Assoc [ ("command", `String "seq 1 2001") ] in
      Eio.Cancel.sub (fun cancel ->
          match Tool.execute tool ~ctx:(module E : Pera_env.Execution_env.S) ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "contains last line 2001" true
                (String.find ~sub:"2001" s >= 0);
              Alcotest.(check bool)
                "first line is NOT 1 (tail truncation)" false
                (String.starts_with ~prefix:"1" (String.trim s))
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "bash failed: %s" e.message))

let () =
  Alcotest.run "bash_tool"
    [
      ( "bash_tool",
        [
          Alcotest.test_case "returns_stdout_on_success" `Quick
            test_bash_returns_stdout_on_success;
          Alcotest.test_case "nonzero_exit_returns_error" `Quick
            test_bash_nonzero_exit_returns_error;
          Alcotest.test_case "stderr_in_combined_output" `Quick
            test_bash_stderr_in_combined_output;
          Alcotest.test_case "timeout_returns_error" `Quick
            test_bash_timeout_returns_error;
          Alcotest.test_case "no_output_command_returns_no_output" `Quick
            test_bash_no_output_command_returns_no_output;
          Alcotest.test_case "tail_truncation_preserves_end" `Quick
            test_bash_tail_truncation_preserves_end;
        ] );
    ]
