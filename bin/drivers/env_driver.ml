(** Environment driver — exercises the harness shell and filesystem layer
    standalone against a real OS.

    Scenarios (5): 1. [exec_stdout] — echo hello, verify stdout 2. [exec_stderr]
    — command with mixed stdout/stderr, verify separation 3. [exec_exit_code] —
    exit 42, verify non-zero exit code 4. [exec_timeout] — sleep 10 with 0.1s
    timeout, verify Timeout error 5. [find_sh] — PATH scan for sh, verify
    absolute path returned

    Exit code: 0 if all non-skipped scenarios pass, 1 otherwise. *)

open Containers
open Pera_env

(* ── Types ────────────────────────────────────────────────────────────────── *)

type verdict = Pass | Fail of string | Skip of string

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

(** Create a temporary directory with a unique name under the system temp dir.
*)
let make_temp_dir env =
  let tmpdir = Filename.get_temp_dir_name () in
  let buf = Cstruct.create 8 in
  Eio.Flow.read_exact env#secure_random buf;
  let hex_chars = ref [] in
  for i = 0 to Cstruct.length buf - 1 do
    let code = Cstruct.get_uint8 buf i in
    hex_chars := Printf.sprintf "%02x" code :: !hex_chars
  done;
  let hex = String.concat "" (List.rev !hex_chars) in
  let path = Filename.concat tmpdir ("pera_env_driver_" ^ hex) in
  Eio.Path.(mkdirs ~exists_ok:false ~perm:0o700 (env#fs / path));
  path

(** Clean up a temporary directory (best-effort). *)
let cleanup path =
  try
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote path) in
    ignore (Sys.command cmd)
  with _ -> ()

(** Print a verdict line to stdout. *)
let print_verdict ~scenario = function
  | Pass -> Printf.printf "  %s ... PASS\n" scenario
  | Fail msg -> Printf.printf "  %s ... FAIL: %s\n" scenario msg
  | Skip msg -> Printf.printf "  %s ... SKIP: %s\n" scenario msg

(** Trim trailing newline from a string. *)
let trim_trailing_newline s =
  if String.ends_with ~suffix:"\n" s then String.sub s 0 (String.length s - 1)
  else s

(** Run a command via Sh.exec with all optional args set to None, under
    Eio.Cancel.sub. *)
let exec_cmd ~sw ~command ?timeout (module E : Execution_env.S) =
  Eio.Cancel.sub (fun cancel ->
      E.Sh.exec ~command
        ?cwd:(None : string option)
        ?env:(None : (string * string) list option)
        ?timeout
        ?on_stdout:(None : (string -> unit) option)
        ?on_stderr:(None : (string -> unit) option)
        ~sw ~cancel)

(* ── Scenarios ────────────────────────────────────────────────────────────── *)

(** Scenario 1: Basic exec — echo hello, check stdout. *)
let scenario_exec_stdout ~sw (module E : Execution_env.S) =
  let scenario = "exec stdout" in
  match exec_cmd ~sw ~command:"echo hello" (module E) with
  | Error e ->
      let v = Fail (Printf.sprintf "exec failed: %s" e.message) in
      print_verdict ~scenario v;
      v
  | Ok result ->
      let stdout_trimmed = trim_trailing_newline result.stdout in
      let v =
        if String.equal stdout_trimmed "hello" then Pass
        else Fail (Printf.sprintf "expected 'hello', got '%s'" result.stdout)
      in
      print_verdict ~scenario v;
      v

(** Scenario 2: Exec with stderr — verify stdout/stderr separation. *)
let scenario_exec_stderr ~sw (module E : Execution_env.S) =
  let scenario = "exec stderr" in
  match exec_cmd ~sw ~command:"echo out && echo err >&2" (module E) with
  | Error e ->
      let v = Fail (Printf.sprintf "exec failed: %s" e.message) in
      print_verdict ~scenario v;
      v
  | Ok result ->
      let stdout_trimmed = trim_trailing_newline result.stdout in
      let stderr_trimmed = trim_trailing_newline result.stderr in
      let v =
        if
          String.equal stdout_trimmed "out" && String.equal stderr_trimmed "err"
        then Pass
        else
          Fail
            (Printf.sprintf "stdout='%s' stderr='%s'" result.stdout
               result.stderr)
      in
      print_verdict ~scenario v;
      v

(** Scenario 3: Non-zero exit code — exit 42. *)
let scenario_exec_exit_code ~sw (module E : Execution_env.S) =
  let scenario = "exec exit code" in
  match exec_cmd ~sw ~command:"exit 42" (module E) with
  | Error e ->
      let v = Fail (Printf.sprintf "exec failed: %s" e.message) in
      print_verdict ~scenario v;
      v
  | Ok result ->
      let v =
        if Int.equal result.exit_code 42 then Pass
        else
          Fail (Printf.sprintf "expected exit code 42, got %d" result.exit_code)
      in
      print_verdict ~scenario v;
      v

(** Scenario 4: Timeout — sleep 10 with 0.1s timeout. *)
let scenario_exec_timeout ~sw (module E : Execution_env.S) =
  let scenario = "exec timeout" in
  match exec_cmd ~sw ~command:"sleep 10" ~timeout:0.1 (module E) with
  | Ok _ ->
      let v = Fail "expected timeout error but command succeeded" in
      print_verdict ~scenario v;
      v
  | Error e ->
      let v =
        if Pera_types.Types.equal_execution_error_code e.code Timeout then Pass
        else
          Fail
            (Format.asprintf "expected Timeout, got (%a) %s"
               Pera_types.Types.pp_execution_error_code e.code e.message)
      in
      print_verdict ~scenario v;
      v

(** Scenario 5: Find sh on PATH. *)
let scenario_find_sh (module E : Execution_env.S) =
  let scenario = "find sh" in
  match E.Sh.find_executable ~name:"sh" with
  | None ->
      let v = Skip "sh not found on PATH" in
      print_verdict ~scenario v;
      v
  | Some path ->
      let v =
        if String.starts_with ~prefix:"/" path then Pass
        else Fail (Printf.sprintf "expected absolute path, got '%s'" path)
      in
      print_verdict ~scenario v;
      v

(** Scenario 6: Write a file then read it back; verify content matches. *)
let scenario_fs_write_read ~sw (module E : Execution_env.S) =
  let scenario = "fs write/read" in
  match E.Fs.write_file ~path:"hello.txt" ~content:"hello world" ~sw with
  | Error e ->
      let v = Fail (Printf.sprintf "write failed: %s" e.message) in
      print_verdict ~scenario v;
      v
  | Ok () ->
      let v =
        match E.Fs.read_text_file ~path:"hello.txt" ~sw with
        | Error e -> Fail (Printf.sprintf "read failed: %s" e.message)
        | Ok content ->
            if String.equal (String.trim content) "hello world" then Pass
            else Fail (Printf.sprintf "expected 'hello world', got '%s'" content)
      in
      print_verdict ~scenario v;
      v

(** Scenario 7: Write a file; verify exists returns true; nonexistent returns
    false. *)
let scenario_fs_file_exists ~sw (module E : Execution_env.S) =
  let scenario = "fs file exists" in
  match E.Fs.write_file ~path:"exists.txt" ~content:"x" ~sw with
  | Error e ->
      let v = Fail (Printf.sprintf "write failed: %s" e.message) in
      print_verdict ~scenario v;
      v
  | Ok () ->
      let v =
        match E.Fs.exists ~path:"exists.txt" ~sw with
        | Error e -> Fail (Printf.sprintf "exists check failed: %s" e.message)
        | Ok false -> Fail "exists returned false for written file"
        | Ok true ->
            (match E.Fs.exists ~path:"nonexistent_xyz.txt" ~sw with
            | Error e ->
                Fail (Printf.sprintf "exists check failed: %s" e.message)
            | Ok true ->
                Fail "exists returned true for nonexistent file"
            | Ok false -> Pass)
      in
      print_verdict ~scenario v;
      v

(** Scenario 8: Write two files; verify list_dir contains both. *)
let scenario_fs_list_dir ~sw (module E : Execution_env.S) =
  let scenario = "fs list dir" in
  let writes =
    [
      E.Fs.write_file ~path:"a.txt" ~content:"a" ~sw;
      E.Fs.write_file ~path:"b.txt" ~content:"b" ~sw;
    ]
  in
  let write_error =
    List.find_opt (function Error _ -> true | Ok _ -> false) writes
  in
  match write_error with
  | Some (Error e) ->
      let v = Fail (Printf.sprintf "write failed: %s" e.message) in
      print_verdict ~scenario v;
      v
  | _ ->
      let v =
        match E.Fs.list_dir ~path:"." ~sw with
        | Error e -> Fail (Printf.sprintf "list_dir failed: %s" e.message)
        | Ok infos ->
            let names = List.map (fun (fi : Execution_env.file_info) -> fi.name) infos in
            let has_a = List.exists (String.equal "a.txt") names in
            let has_b = List.exists (String.equal "b.txt") names in
            if has_a && has_b then Pass
            else
              Fail
                (Printf.sprintf "expected a.txt and b.txt, got [%s]"
                   (String.concat "; " names))
      in
      print_verdict ~scenario v;
      v

(** Scenario 9: Read a nonexistent file; verify the result is an Error with
    NotFound code. *)
let scenario_fs_read_nonexistent ~sw (module E : Execution_env.S) =
  let scenario = "fs read nonexistent" in
  let v =
    match E.Fs.read_text_file ~path:"no_such_file_xyz.txt" ~sw with
    | Ok _ -> Fail "expected Error but got Ok"
    | Error e ->
        if Pera_types.Types.equal_file_error_code e.code Pera_types.Types.NotFound
        then Pass
        else
          Fail
            (Format.asprintf "expected NotFound, got (%a) %s"
               Pera_types.Types.pp_file_error_code e.code e.message)
  in
  print_verdict ~scenario v;
  v

(* ── Main ─────────────────────────────────────────────────────────────────── *)

(** Run all scenarios under a switch. Returns exit code. *)
let run_scenarios ~sw env tmpdir =
  let module E = (val Local_env.create ~env ~cwd:tmpdir : Execution_env.S) in
  Printf.printf "Scenario Results:\n%!";
  let verdicts =
    [
      scenario_exec_stdout ~sw (module E);
      scenario_exec_stderr ~sw (module E);
      scenario_exec_exit_code ~sw (module E);
      scenario_exec_timeout ~sw (module E);
      scenario_find_sh (module E);
      scenario_fs_write_read ~sw (module E);
      scenario_fs_file_exists ~sw (module E);
      scenario_fs_list_dir ~sw (module E);
      scenario_fs_read_nonexistent ~sw (module E);
    ]
  in
  let passed =
    List.length
      (List.filter
         (fun v -> match v with Pass -> true | Fail _ | Skip _ -> false)
         verdicts)
  in
  let skipped =
    List.length
      (List.filter
         (fun v -> match v with Skip _ -> true | Pass | Fail _ -> false)
         verdicts)
  in
  let all = List.length verdicts in
  Printf.printf "\n%d/%d scenarios passed (%d skipped).\n" passed all skipped;
  if passed + skipped = all then 0 else 1

let () =
  let exit_code =
    Eio_main.run @@ fun env ->
    let tmpdir = make_temp_dir env in
    let result =
      try Eio.Switch.run (fun sw -> run_scenarios ~sw env tmpdir)
      with e ->
        Printf.eprintf "env_driver crashed: %s\n%!" (Printexc.to_string e);
        1
    in
    cleanup tmpdir;
    result
  in
  exit exit_code
