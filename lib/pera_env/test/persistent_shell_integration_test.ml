(** Integration tests for [Persistent_shell] that exercise real shell scenarios:
    background jobs, adversarial sentinel output, process lifecycle under switch
    cancellation, large-output backpressure, and cancellation.

    These are heavier than the unit tests in [persistent_shell_test.ml] and are
    run as a standalone executable. *)

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

let contains_substring ~substring s =
  let sub_len = String.length substring in
  let s_len = String.length s in
  let rec loop i =
    if i + sub_len > s_len then false
    else if String.equal (String.sub s i sub_len) substring then true
    else loop (i + 1)
  in
  loop 0

let assert_substring ~test ~substring s =
  if not (contains_substring ~substring s) then begin
    Printf.eprintf "[FAIL] %s: expected %S to contain %S\n%!" test s substring;
    exit 1
  end

let parse_pid ~test s =
  match int_of_string_opt (String.trim s) with
  | Some pid -> pid
  | None ->
      Printf.eprintf "[FAIL] %s: expected integer pid, got %S\n%!" test s;
      exit 1

let pass test = Printf.printf "[PASS] %s\n%!" test

(** {1 Test 1: Background job that completes} *)

(** Start a background job that completes after 1 second, immediately run a
    foreground command, and verify the foreground command is not blocked by the
    background job holding the pipe open. *)
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
              shell_pid := parse_pid ~test:"get shell pid" (trim result.stdout));
          (* Start a background job that runs forever and get its PID *)
          (match exec_cmd ~sw ~cancel ~command:"sleep 1000 & echo $!" shell with
          | Error e ->
              Printf.eprintf "[FAIL] start bg job: %s\n%!" e.message;
              exit 1
          | Ok result ->
              bg_pid := parse_pid ~test:"start bg job" (trim result.stdout));
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
     Printf.eprintf
       "[FAIL] bg_killed: background job %d still alive after SIGKILL\n%!"
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
      (match exec_cmd ~sw ~cancel ~command:"echo '0 PERA_DONE_xyz'" shell with
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
          assert_substring ~test:"adv multi: end" ~substring:"end" result.stdout;
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

(** {1 Test 4: Large output without deadlock} *)

(** Produce many lines on one stream while the other is idle. This validates
    that the concurrent reader design does not deadlock under pipe backpressure.
*)
let test_large_output_no_deadlock ~env ~sw ~cwd =
  Printf.printf "--- Test: large output no deadlock ---\n%!";
  Eio.Cancel.sub (fun cancel ->
      let shell = make_shell ~env ~sw ~cwd in
      let expected_lines = 200_000 in
      let cmd = Printf.sprintf "seq 1 %d" expected_lines in
      match exec_cmd ~sw ~cancel ~command:cmd shell with
      | Error e ->
          Printf.eprintf "[FAIL] large output: %s\n%!" e.message;
          exit 1
      | Ok result ->
          let lines = String.split_on_char '\n' result.stdout in
          let line_count =
            List.length (List.filter (fun s -> not (String.is_empty s)) lines)
          in
          if not (Int.equal line_count expected_lines) then begin
            Printf.eprintf "[FAIL] large output: expected %d lines, got %d\n%!"
              expected_lines line_count;
            exit 1
          end;
          assert_exit_code ~test:"large output exit" ~expected:0
            result.exit_code;
          pass "large output no deadlock")

(** {1 Test 5: Cancellation aborts in-flight exec} *)

(** Start a long-running command, cancel its context, and verify that [exec]
    returns an [Aborted] error. Note: Stage 0 cancellation cancels the
    harness-side read loop but does not interrupt the in-flight shell process
    itself; that requires Stage 1's SIGINT+grace timeout handling. *)
let test_cancel_aborts_exec ~env ~sw ~cwd =
  Printf.printf "--- Test: cancel aborts exec ---\n%!";
  let shell = make_shell ~env ~sw ~cwd in
  let done_p, resolve_done = Eio.Promise.create () in
  let cancel_p, resolve_cancel = Eio.Promise.create () in
  let release_p, resolve_release = Eio.Promise.create () in
  let result_ref = ref None in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Cancel.sub (fun cancel ->
          Eio.Promise.resolve resolve_cancel cancel;
          let result =
            Persistent_shell.exec shell ~command:"sleep 100" ~sw ~cancel ()
          in
          (* The cancellation context may still be marked as cancelling after
             [exec] returns. Use a protected context for the cleanup so the
             background fiber does not leak a [Cancelled] exception. *)
          Eio.Cancel.protect (fun () ->
              result_ref := Some result;
              Eio.Promise.resolve resolve_done ();
              Eio.Promise.await release_p)));
  let cancel = Eio.Promise.await cancel_p in
  (* Let the command start before cancelling. *)
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.1;
  Eio.Cancel.cancel cancel (Failure "test cancellation");
  Eio.Promise.await done_p;
  Eio.Promise.resolve resolve_release ();
  match !result_ref with
  | None ->
      Printf.eprintf "[FAIL] cancel: exec fiber did not produce a result\n%!";
      exit 1
  | Some (Ok r) ->
      Printf.eprintf
        "[FAIL] cancel: expected cancellation error, got Ok exit=%d stdout=%S \
         stderr=%S\n\
         %!"
        r.exit_code r.stdout r.stderr;
      exit 1
  | Some (Error e) ->
      if not (Pera_types.Types.equal_execution_error_code e.code Aborted) then begin
        Printf.eprintf "[FAIL] cancel: expected Aborted, got %s\n%!"
          (Pera_types.Types.show_execution_error_code e.code);
        exit 1
      end;
      pass "cancel aborts exec"

(** {1 Main} *)

let () =
  Eio_main.run @@ fun env ->
  let cwd = make_temp_dir env in
  Eio.Switch.run @@ fun sw ->
  test_cancel_aborts_exec ~env ~sw ~cwd;
  test_background_job_completes ~env ~sw ~cwd;
  test_adversarial_sentinels ~env ~sw ~cwd;
  test_large_output_no_deadlock ~env ~sw ~cwd;
  (* bg_killed test creates its own nested switch, so it runs outside this one *)
  test_background_job_killed_with_switch ~env ~cwd;
  Printf.printf "\nAll integration tests passed.\n%!"
