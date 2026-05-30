open Containers
open Pera_tools
open Pera_harness
open Pera_core.Agent_types

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

let run_bash_test (body : (module Execution_env.S) -> Eio.Switch.t -> unit) =
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

(* ── Bash tool tests ────────────────────────────────────────────────────── *)

let test_bash_returns_stdout_on_success () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash (module E) in
      let args = `Assoc [ ("command", `String "echo hello") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "contains hello" true
                (is_substring ~sub:"hello" s)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "bash failed: %s" e.message))

let test_bash_nonzero_exit_returns_error () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash (module E) in
      let args = `Assoc [ ("command", `String "exit 42") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Error e ->
              Alcotest.(check bool) "is_user_error false" false e.is_user_error;
              Alcotest.(check bool)
                "message contains 42" true
                (is_substring ~sub:"42" e.message)
          | Ok _ -> Alcotest.fail "expected Error for non-zero exit"))

let test_bash_stderr_in_combined_output () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash (module E) in
      let args = `Assoc [ ("command", `String "echo err >&2 && exit 0") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "stderr content in combined output" true
                (is_substring ~sub:"err" s)
          | Ok _ -> Alcotest.fail "expected Tool_text"
          | Error e -> Alcotest.failf "bash failed: %s" e.message))

let test_bash_timeout_returns_error () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash (module E) in
      let args =
        `Assoc [ ("command", `String "sleep 10"); ("timeout", `Float 0.05) ]
      in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Error e ->
              Alcotest.(check bool) "is_user_error false" false e.is_user_error
          | Ok _ -> Alcotest.fail "expected Error for timed-out command"))

let test_bash_tail_truncation_preserves_end () =
  run_bash_test (fun (module E) sw ->
      let tool = Bash_tool.bash (module E) in
      let args = `Assoc [ ("command", `String "seq 1 2001") ] in
      Eio.Cancel.sub (fun cancel ->
          match tool.execute ~ctx:() ~args ~sw ~cancel with
          | Ok (Tool_text s) ->
              Alcotest.(check bool)
                "contains last line 2001" true
                (is_substring ~sub:"2001" s);
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
          Alcotest.test_case "tail_truncation_preserves_end" `Quick
            test_bash_tail_truncation_preserves_end;
        ] );
    ]
