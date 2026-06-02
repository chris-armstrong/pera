(** Tool driver — manual binary exercising all four tools against a real OS.

    Scenarios (7): 1. [read] Basic read — write a file, read it back, check
    content. 2. [read] Offset/limit — write multi-line file, read with
    offset+limit. 3. [write] Create — write content, read via env to verify. 4.
    [write] Overwrite + bytes — overwrite existing file, check message. 5.
    [bash] Echo hello — simple command, verify stdout. 6. [bash] Exit code —
    exit 99, verify error message. 7. [grep] Pattern search — create file with
    pattern, search; SKIP if rg absent.

    Exit code: 0 if all non-skipped scenarios pass, 1 otherwise. *)

open Containers
open Pera_tools
open Pera_harness
open Pera_core.Agent_types

(* ── Types ────────────────────────────────────────────────────────────────── *)

type verdict = Pass | Fail of string | Skip of string

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

(** Check if [sub] is a substring of [s]. *)
let is_substring ~sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  if sub_len > s_len then false
  else
    let max_start = s_len - sub_len in
    let rec check i =
      if i > max_start then false
      else if String.starts_with ~prefix:sub (String.sub s i (s_len - i)) then
        true
      else check (i + 1)
    in
    check 0

(** Find a tool by name in a tool list. Raises [Failure] if not found. *)
let find_tool ~name tools =
  match
    List.find_opt (fun (t : unit tool) -> String.equal t.name name) tools
  with
  | Some t -> t
  | None -> failwith (Printf.sprintf "tool_driver: tool '%s' not found" name)

(** Create a temporary directory with a unique name under the system temp dir.
*)
let make_temp_dir env =
  let tmpdir = Filename.get_temp_dir_name () in
  let pid = Unix.getpid () in
  let ts = Int64.of_float (Unix.gettimeofday ()) in
  let name = Printf.sprintf "pera_tool_driver_%d_%Ld" pid ts in
  let path = Filename.concat tmpdir name in
  Eio.Path.(mkdirs ~exists_ok:false ~perm:0o700 (env#fs / path));
  path

(** Clean up a temporary directory (best-effort). *)
let cleanup path =
  try
    let cmd = Printf.sprintf "rm -rf %s" (Filename.quote path) in
    ignore (Sys.command cmd)
  with _ -> ()

(** Print a verdict line to stdout. *)
let print_verdict ~tool ~scenario = function
  | Pass -> Printf.printf "[%s] %s ... PASS\n" tool scenario
  | Fail msg -> Printf.printf "[%s] %s ... FAIL: %s\n" tool scenario msg
  | Skip msg -> Printf.printf "[%s] %s ... SKIP: %s\n" tool scenario msg

(** Write a file via the write tool. Returns [Ok ()] or [Error string]. *)
let write_file ~(t : unit tool) ~path ~content ~sw ~cancel =
  let args = `Assoc [ ("path", `String path); ("content", `String content) ] in
  match t.execute ~ctx:() ~args ~sw ~cancel with
  | Ok _ -> Ok ()
  | Error e -> Error e.message

(** Read a file via the read tool. Returns [Ok string] or [Error string]. *)
let read_file ~(t : unit tool) ~path ~sw ~cancel =
  let args = `Assoc [ ("path", `String path) ] in
  match t.execute ~ctx:() ~args ~sw ~cancel with
  | Ok (Tool_text s) -> Ok s
  | Ok _ -> Error "read returned non-text output"
  | Error e -> Error e.message

(** Execute a bash command via the bash tool. Returns [Ok string] or
    [Error string]. *)
let run_bash ~(t : unit tool) ~command ~sw ~cancel =
  let args = `Assoc [ ("command", `String command) ] in
  match t.execute ~ctx:() ~args ~sw ~cancel with
  | Ok (Tool_text s) -> Ok s
  | Ok _ -> Error "bash returned non-text output"
  | Error e -> Error e.message

(* ── Scenario helpers (≤ 2 levels of nesting each) ───────────────────────── *)

(** Scenario 1 helper: read a file and check it contains expected substring. *)
let check_read_contains ~(read : unit tool) ~path ~expected ~tool ~scenario ~sw
    ~cancel =
  match read_file ~t:read ~path ~sw ~cancel with
  | Error msg ->
      let v = Fail (Printf.sprintf "read failed: %s" msg) in
      print_verdict ~tool ~scenario v;
      v
  | Ok content ->
      let v =
        if is_substring ~sub:expected content then Pass
        else Fail (Printf.sprintf "expected '%s', got '%s'" expected content)
      in
      print_verdict ~tool ~scenario v;
      v

(** Scenario 2 helper: write a 10-line file, read with offset=3/limit=2, return
    the trimmed output string or error. *)
let write_and_read_offset ~(write : unit tool) ~(read : unit tool) ~sw ~cancel =
  let lines =
    String.concat "\n" (List.init 10 (fun i -> string_of_int (i + 1)))
  in
  match write_file ~t:write ~path:"numbers.txt" ~content:lines ~sw ~cancel with
  | Error msg -> Error msg
  | Ok () -> (
      let args =
        `Assoc
          [
            ("path", `String "numbers.txt");
            ("offset", `Int 3);
            ("limit", `Int 2);
          ]
      in
      match read.execute ~ctx:() ~args ~sw ~cancel with
      | Ok (Tool_text s) -> Ok (String.trim s)
      | Ok _ -> Error "read returned non-text output"
      | Error e -> Error e.message)

(** Scenario 4 helper: write "first", then overwrite with "second" (6 bytes),
    return the overwrite output message. *)
let overwrite_twice ~(t : unit tool) ~sw ~cancel =
  let args_first =
    `Assoc [ ("path", `String "overwrite.txt"); ("content", `String "first") ]
  in
  match t.execute ~ctx:() ~args:args_first ~sw ~cancel with
  | Error e -> Error e.message
  | Ok _ -> (
      let args_second =
        `Assoc
          [ ("path", `String "overwrite.txt"); ("content", `String "second") ]
      in
      match t.execute ~ctx:() ~args:args_second ~sw ~cancel with
      | Ok (Tool_text msg) -> Ok msg
      | Ok _ -> Error "write returned non-text output"
      | Error e -> Error e.message)

(** Scenario 7 helper: write a file with a unique pattern, run grep, return
    output or error. *)
let write_and_grep ~(write : unit tool) ~(grep : unit tool) ~sw ~cancel =
  match
    write_file ~t:write ~path:"grep_test.txt" ~content:"unique_grep_pattern_xyz"
      ~sw ~cancel
  with
  | Error msg -> Error msg
  | Ok () -> (
      let args = `Assoc [ ("pattern", `String "unique_grep_pattern") ] in
      match grep.execute ~ctx:() ~args ~sw ~cancel with
      | Ok (Tool_text s) -> Ok s
      | Ok _ -> Error "grep returned non-text output"
      | Error e -> Error e.message)

(* ── Scenarios (≤ 2 levels of nesting each) ──────────────────────────────── *)

(** Scenario 1: Basic read — write "hello world", read it back, verify. *)
let scenario_read_basic ~(read : unit tool) ~(write : unit tool) ~sw ~cancel =
  let scenario = "basic read" in
  let tool_name = read.name in
  match
    write_file ~t:write ~path:"hello.txt" ~content:"hello world" ~sw ~cancel
  with
  | Error msg ->
      let v = Fail (Printf.sprintf "write failed: %s" msg) in
      print_verdict ~tool:tool_name ~scenario v;
      v
  | Ok () ->
      check_read_contains ~read ~path:"hello.txt" ~expected:"hello world"
        ~tool:tool_name ~scenario ~sw ~cancel

(** Scenario 2: Read with offset/limit — write 10 lines, read from line 3,
    expect output starts with "3". *)
let scenario_read_offset ~(read : unit tool) ~(write : unit tool) ~sw ~cancel =
  let scenario = "read with offset/limit" in
  match write_and_read_offset ~write ~read ~sw ~cancel with
  | Error msg ->
      let v = Fail msg in
      print_verdict ~tool:read.name ~scenario v;
      v
  | Ok trimmed ->
      let v =
        if String.starts_with ~prefix:"3" trimmed then Pass
        else
          Fail
            (Printf.sprintf "expected output to start with '3', got: '%s'"
               trimmed)
      in
      print_verdict ~tool:read.name ~scenario v;
      v

(** Scenario 3: Write create — write a file, read via env to verify content. *)
let scenario_write_create ~(read : unit tool) ~(write : unit tool) ~sw ~cancel =
  let scenario = "create file" in
  let tool_name = write.name in
  match
    write_file ~t:write ~path:"created.txt" ~content:"write test" ~sw ~cancel
  with
  | Error msg ->
      let v = Fail (Printf.sprintf "write failed: %s" msg) in
      print_verdict ~tool:tool_name ~scenario v;
      v
  | Ok () ->
      check_read_contains ~read ~path:"created.txt" ~expected:"write test"
        ~tool:tool_name ~scenario ~sw ~cancel

(** Scenario 4: Write overwrite + bytes — write twice, check message contains "6
    bytes". *)
let scenario_write_overwrite ~(write : unit tool) ~sw ~cancel =
  let scenario = "overwrite + bytes" in
  match overwrite_twice ~t:write ~sw ~cancel with
  | Error msg ->
      let v = Fail msg in
      print_verdict ~tool:write.name ~scenario v;
      v
  | Ok msg ->
      let v =
        if is_substring ~sub:"6 bytes" msg then Pass
        else
          Fail
            (Printf.sprintf "expected message containing '6 bytes', got: '%s'"
               msg)
      in
      print_verdict ~tool:write.name ~scenario v;
      v

(** Scenario 5: Bash echo — run "echo hello", check output. *)
let scenario_bash_echo ~(bash : unit tool) ~sw ~cancel =
  let scenario = "echo hello" in
  match run_bash ~t:bash ~command:"echo hello" ~sw ~cancel with
  | Error msg ->
      let v = Fail msg in
      print_verdict ~tool:bash.name ~scenario v;
      v
  | Ok content ->
      let v =
        if is_substring ~sub:"hello" content then Pass
        else Fail (Printf.sprintf "expected 'hello', got '%s'" content)
      in
      print_verdict ~tool:bash.name ~scenario v;
      v

(** Scenario 6: Bash exit code — run "exit 99", check error message. *)
let scenario_bash_exit_code ~(bash : unit tool) ~sw ~cancel =
  let scenario = "exit code handling" in
  let args = `Assoc [ ("command", `String "exit 99") ] in
  match bash.execute ~ctx:() ~args ~sw ~cancel with
  | Error e ->
      let v =
        if is_substring ~sub:"99" e.message then Pass
        else
          Fail
            (Printf.sprintf "error message did not contain '99': '%s'" e.message)
      in
      print_verdict ~tool:bash.name ~scenario v;
      v
  | Ok _ ->
      let v = Fail "expected Error for non-zero exit, got Ok" in
      print_verdict ~tool:bash.name ~scenario v;
      v

(** Scenario 7: Grep pattern search — create file with unique pattern, search
    for it. Skips if ripgrep (rg) is not installed. *)
let scenario_grep_search ~(grep : unit tool) ~(write : unit tool) env ~sw
    ~cancel =
  let scenario = "pattern search" in
  let module E = (val env : Execution_env.S) in
  match E.Sh.find_executable ~name:"rg" with
  | None ->
      let v = Skip "ripgrep not installed" in
      print_verdict ~tool:grep.name ~scenario v;
      v
  | Some _ -> (
      let tool_name = grep.name in
      match write_and_grep ~write ~grep ~sw ~cancel with
      | Error msg ->
          let v = Fail msg in
          print_verdict ~tool:tool_name ~scenario v;
          v
      | Ok output ->
          let v =
            if is_substring ~sub:"grep_test.txt" output then Pass
            else
              Fail
                (Printf.sprintf "expected file name in grep output, got '%s'"
                   output)
          in
          print_verdict ~tool:tool_name ~scenario v;
          v)

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  let exit_code =
    Eio_main.run @@ fun env ->
    let tmpdir = make_temp_dir env in
    let result =
      try
        Eio.Switch.run @@ fun sw ->
        let module E = (val Local_env.create ~env ~cwd:tmpdir : Execution_env.S)
        in
        let tools = Tools.default (module E) in
        let read = find_tool ~name:"read" tools in
        let write = find_tool ~name:"write" tools in
        let bash = find_tool ~name:"bash" tools in
        let grep = find_tool ~name:"grep" tools in
        (* All scenarios run under the same cancel context (never cancelled) *)
        let verdicts =
          Eio.Cancel.sub (fun cancel ->
              [
                scenario_read_basic ~read ~write ~sw ~cancel;
                scenario_read_offset ~read ~write ~sw ~cancel;
                scenario_write_create ~read ~write ~sw ~cancel;
                scenario_write_overwrite ~write ~sw ~cancel;
                scenario_bash_echo ~bash ~sw ~cancel;
                scenario_bash_exit_code ~bash ~sw ~cancel;
                scenario_grep_search ~grep ~write (module E) ~sw ~cancel;
              ])
        in
        Printf.printf "\n";
        let passed =
          List.length
            (List.filter
               (fun v -> match v with Pass -> true | _ -> false)
               verdicts)
        in
        let skipped =
          List.length
            (List.filter
               (fun v -> match v with Skip _ -> true | _ -> false)
               verdicts)
        in
        let all = List.length verdicts in
        Printf.printf "%d/%d scenarios passed (%d skipped).\n" passed all
          skipped;
        if passed + skipped = all then 0 else 1
      with e ->
        Printf.eprintf "tool_driver crashed: %s\n%!" (Printexc.to_string e);
        1
    in
    cleanup tmpdir;
    result
  in
  exit exit_code
