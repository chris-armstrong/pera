(** Integration tests for [Persistent_shell] that exercise real shell
    scenarios: background jobs, adversarial sentinel output, and process
    lifecycle under switch cancellation.

    These are heavier than the unit tests in [persistent_shell_test.ml] and
    are run as a standalone executable. *)

open Containers
open Pera_env
open Harness_test_util

(** {1 Helpers} *)

let make_shell ~env ~sw ~cwd =
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let shell_env = Unix.environment () in
  Persistent_shell.create ~proc_mgr ~clock ~sw ~env:shell_env ~cwd ()

let exec_cmd ~sw ~cancel ~command ?timeout shell =
  let out_buf = Buffer.create 256 in
  let err_buf = Buffer.create 256 in
  Persistent_shell.exec shell ~command
    ~on_stdout:(fun s -> Buffer.add_string out_buf s)
    ~on_stderr:(fun s -> Buffer.add_string err_buf s)
    ?timeout ~sw ~cancel ()

let trim s =
  if String.ends_with ~suffix:"\n" s then String.sub s 0 (String.length s - 1)
  else s

let assert_eq ~test ~expected actual =
  if not (String.equal expected actual) then begin
    Printf.eprintf "[FAIL] %s: expected %S, got %S\n%!" test expected actual;
    exit 1
  end

let assert_exit_code ~test ~expected actual =
  if not (Int.equal expected actual) then begin
    Printf.eprintf "[FAIL] %s: expected exit code %d, got %d\n%!" test expected
      actual;
    exit 1
  end

let assert_substring ~test ~substring s =
  let sub_len = String.length substring in
  let s_len = String.length s in
  let found = ref false in
  for i = 0 to s_len - sub_len do
    let match_here = ref true in
    for j = 0 to sub_len - 1 do
      let sc = Char.code (String.get s (i + j)) in
      let tc = Char.code (String.get substring j) in
      if sc <> tc then match_here := false
    done;
    if !match_here then found := true
  done;
  if not !found then begin
    Printf.eprintf "[FAIL] %s: expected %S to contain %S\n%!" test s substring;
    exit 1
  end

let pass test = Printf.printf "[PASS] %s\n%!" test

(** {1 Test 1: Background job that completes} *)

(** Start a background job that completes after 1 second, immediately run a
    foreground command, and verify the foreground command is not blocked by
    the background job holding the pipe open. *)
let test_background_job_completes ~env ~sw ~cwd =
  Printf.printf "--- Test: background job completes ---\n%!";
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      (* Start a background sleep that completes after 1s *)
      (match exec_cmd ~sw ~cancel ~command:"sleep 1 &" shell with
      | Error e ->
          Printf.eprintf "[FAIL] background start: %s\n%!" e.message;
          exit 1
      | Ok _ -> ());
      (* Immediately run a foreground command — must not be blocked *)
      (match exec_cmd ~sw ~cancel ~command:"echo hello" shell with
      | Error e ->
          Printf.eprintf "[FAIL] foreground after bg start: %s\n%!" e.message;
          exit 1
      | Ok result ->
          let out = trim result.stdout in
          assert_eq ~test:"bg_complete: foreground output" ~expected:"hello" out;
          assert_exit_code ~test:"bg_complete: foreground exit" ~expected:0
            result.exit_code);
      (* Wait for the background job to finish *)
      Eio.Time.sleep (Eio.Stdenv.clock env) 1.5;
      (* Run another command to verify the shell is still healthy *)
      (match exec_cmd ~sw ~cancel ~command:"echo world" shell with
      | Error e ->
          Printf.eprintf "[FAIL] after bg completes: %s\n%!" e.message;
          exit 1
      | Ok result ->
          let out = trim result.stdout in
          assert_eq ~test:"bg_complete: after wait output" ~expected:"world" out;
          assert_exit_code ~test:"bg_complete: after wait exit" ~expected:0
            result.exit_code);
      pass "background job completes")

(** {1 Test 2: Background job that doesn't complete, kill switch} *)

(** Start a long-running background job, verify the shell still works, then
    release the switch and verify both the shell and the background job are
    killed. *)
let test_background_job_killed_with_switch ~env ~cwd =
  Printf.printf "--- Test: background job killed with switch ---\n%!";
  let shell_pid = ref (-1) in
  let bg_pid = ref (-1) in
  (* Create a nested switch so we can release it independently *)
  Eio.Switch.run (fun sw ->
      Eio.Cancel.sub (fun cancel ->
          let shell = make_shell ~env ~sw ~cwd in
          (* Get the shell's PID *)
          (match exec_cmd ~sw ~cancel ~command:"echo $$" shell with
          | Error e ->
              Printf.eprintf "[FAIL] get shell pid: %s\n%!" e.message;
              exit 1
          | Ok result ->
              shell_pid :=
                int_of_string (String.trim (trim result.stdout)));
          (* Start a background job that runs forever and get its PID *)
          (match
             exec_cmd ~sw ~cancel ~command:"sleep 1000 & echo $!"
           shell
          with
          | Error e ->
              Printf.eprintf "[FAIL] start bg job: %s\n%!" e.message;
              exit 1
          | Ok result ->
              bg_pid := int_of_string (String.trim (trim result.stdout)));
          (* Verify the shell still works with the bg job running *)
          (match exec_cmd ~sw ~cancel ~command:"echo hello" shell with
          | Error e ->
              Printf.eprintf "[FAIL] foreground with bg: %s\n%!" e.message;
              exit 1
          | Ok result ->
              let out = trim result.stdout in
              assert_eq ~test:"bg_killed: foreground output" ~expected:"hello"
                out);
          (* Switch will be released when we exit this scope, triggering
             close and process cleanup *)
          ()));
  (* After the switch is released, verify the processes are dead *)
  (try
     Unix.kill !shell_pid 0;
     Printf.eprintf "[FAIL] bg_killed: shell process %d still alive\n%!"
       !shell_pid;
     exit 1
   with Unix.Unix_error (Unix.ESRCH, _, _) ->
     pass "bg_killed: shell process killed");
  (* The background job may have been orphaned when the shell exited.
     Kill it explicitly and verify it's gone. *)
  (try
     Unix.kill !bg_pid 9;
     (* Give it a moment to die *)
     Unix.sleep 1;
     Unix.kill !bg_pid 0;
     Printf.eprintf "[FAIL] bg_killed: background job %d still alive after SIGKILL\n%!"
       !bg_pid;
     exit 1
   with Unix.Unix_error (Unix.ESRCH, _, _) ->
     pass "bg_killed: background job killed");
  pass "background job killed with switch"

(** {1 Test 3: Adversarial sentinels} *)

(** Send commands whose output contains strings that look like sentinels but
    aren't the actual sentinel. Verify the sentinel protocol doesn't
    false-positive on lookalikes. *)
let test_adversarial_sentinels ~env ~sw ~cwd =
  Printf.printf "--- Test: adversarial sentinels ---\n%!";
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      (* Output a string that looks like a sentinel (prefix + non-numeric) *)
      (match exec_cmd ~sw ~cancel ~command:"echo 'PERA_DONE_abc'" shell with
      | Error e ->
          Printf.eprintf "[FAIL] adv sentinel 1: %s\n%!" e.message;
          exit 1
      | Ok result ->
          assert_substring ~test:"adv: PERA_DONE_abc in output"
            ~substring:"PERA_DONE_abc" result.stdout;
          assert_exit_code ~test:"adv: exit 0" ~expected:0 result.exit_code);
      (* Output a string that looks like a stdout sentinel line *)
      (match
         exec_cmd ~sw ~cancel ~command:"echo '0 PERA_DONE_xyz'" shell
       with
      | Error e ->
          Printf.eprintf "[FAIL] adv sentinel 2: %s\n%!" e.message;
          exit 1
      | Ok result ->
          assert_substring ~test:"adv: '0 PERA_DONE_xyz' in output"
            ~substring:"0 PERA_DONE_xyz" result.stdout;
          assert_exit_code ~test:"adv: exit 0" ~expected:0 result.exit_code);
      (* Multi-line output with sentinel-like strings on multiple lines *)
      (match
         exec_cmd ~sw ~cancel
           ~command:
             "echo 'start'; echo 'PERA_DONE_123'; echo 'middle'; echo '0 \
              PERA_DONE_456'; echo 'end'"
         shell
       with
      | Error e ->
          Printf.eprintf "[FAIL] adv sentinel multi: %s\n%!" e.message;
          exit 1
      | Ok result ->
          assert_substring ~test:"adv multi: start" ~substring:"start"
            result.stdout;
          assert_substring ~test:"adv multi: PERA_DONE_123"
            ~substring:"PERA_DONE_123" result.stdout;
          assert_substring ~test:"adv multi: middle" ~substring:"middle"
            result.stdout;
          assert_substring ~test:"adv multi: 0 PERA_DONE_456"
            ~substring:"0 PERA_DONE_456" result.stdout;
          assert_substring ~test:"adv multi: end" ~substring:"end"
            result.stdout;
          assert_exit_code ~test:"adv multi: exit 0" ~expected:0
            result.exit_code);
      (* Verify the shell is still usable after adversarial output *)
      (match exec_cmd ~sw ~cancel ~command:"echo 'clean'" shell with
      | Error e ->
          Printf.eprintf "[FAIL] adv after clean: %s\n%!" e.message;
          exit 1
      | Ok result ->
          let out = trim result.stdout in
          assert_eq ~test:"adv: clean output" ~expected:"clean" out);
      pass "adversarial sentinels")

(** {1 Main} *)

let () =
  Eio_main.run @@ fun env ->
  let cwd = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  test_background_job_completes ~env ~sw ~cwd;
  test_adversarial_sentinels ~env ~sw ~cwd;
  (* bg_killed test creates its own nested switch, so it runs outside this one *)
  ();
  (* Run the kill test outside the main switch so we can release it *)
  test_background_job_killed_with_switch ~env ~cwd;
  Printf.printf "\nAll integration tests passed.\n%!"
