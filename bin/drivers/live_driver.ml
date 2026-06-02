(** Live driver — exercises the full Agent_harness stack against the real
    Anthropic API with real filesystem tools and session logging.

    Requires ANTHROPIC_API_KEY. Skipped if absent.

    Three scenarios:
    1. bash_echo   — run a sentinel echo command; validate the tool result and
                     assistant response both contain the sentinel string.
    2. file_write  — ask the agent to write a file; validate the file on disk
                     and the session tool_result entry both carry the sentinel.
    3. multi_turn  — two sequential sends; validate the second response
                     references output from the first (proves conversation
                     history threads through send calls).

    Exit code: 0 if all pass, 1 otherwise. *)

open Containers
open Pera_types
open Pera_provider
open Pera_core
open Session_jsonl_helpers

(* ── Model ────────────────────────────────────────────────────────────────── *)

let default_model : Types.model =
  { id = "claude-haiku-4-5-20251001"; api = "anthropic" }

let model_of_argv () =
  if Array.length Sys.argv > 1 then Types.{ id = Sys.argv.(1); api = "anthropic" }
  else default_model

(* ── Session content helpers ──────────────────────────────────────────────── *)

let text_blocks_of_content content_json =
  let blocks = Yojson.Safe.Util.to_list content_json in
  List.filter_map
    (fun block ->
      match get_string_opt "type" block with
      | Some "text" -> get_string_opt "text" block
      | _ -> None)
    blocks

(** All text strings from assistant message entries in the session. *)
let collect_assistant_texts entries =
  List.concat_map
    (fun e ->
      if not (String.equal (get_string "type" e) "message") then []
      else
        let msg = Yojson.Safe.Util.member "message" e in
        match get_string_opt "role" msg with
        | Some "assistant" ->
            text_blocks_of_content (Yojson.Safe.Util.member "content" msg)
        | _ -> [])
    entries

(** All tool-result content strings from tool_result entries in the session. *)
let collect_tool_result_strings entries =
  List.filter_map
    (fun e ->
      if not (String.equal (get_string "type" e) "message") then None
      else
        let msg = Yojson.Safe.Util.member "message" e in
        match get_string_opt "role" msg with
        | Some "tool_result" ->
            let content = Yojson.Safe.Util.member "content" msg in
            (match content with
            | `String s -> Some s
            | other -> Some (Yojson.Safe.to_string other))
        | _ -> None)
    entries

let has_tool_results entries =
  not (List.is_empty (collect_tool_result_strings entries))

let contains_sub ~needle s = String.find ~sub:needle s >= 0

(** True if [needle] appears in any assistant text or tool result in
    [entries]. *)
let session_output_contains ~needle entries =
  List.exists (contains_sub ~needle) (collect_assistant_texts entries)
  || List.exists (contains_sub ~needle) (collect_tool_result_strings entries)

(* ── Harness config helper ────────────────────────────────────────────────── *)

let make_harness_config ~model ~tmpdir ~session_path ~stream_fn ~exec_env :
    Pera_agent.Agent_harness.config =
  { cwd = tmpdir; model; session_path; stream_fn; max_tokens = 1024; exec_env }

(* ── Verify helpers ───────────────────────────────────────────────────────── *)

let verify_bash_echo sentinel entries =
  if not (has_tool_results entries) then Fail "no tool_result entries in session"
  else if not (session_output_contains ~needle:sentinel entries) then
    Fail
      (Printf.sprintf "sentinel '%s' not found in tool output or assistant response"
         sentinel)
  else verify_chain_and_leaves entries

let verify_file_write ~output_file ~sentinel entries =
  if not (Sys.file_exists output_file) then Fail "output file was not created"
  else
    let content = Stdlib.In_channel.(with_open_text output_file input_all) in
    if not (contains_sub ~needle:sentinel content) then
      Fail
        (Printf.sprintf "file missing sentinel '%s'; first 80 chars: '%s'"
           sentinel (String.take 80 content))
    else if not (has_tool_results entries) then
      Fail "no tool_result entries in session"
    else verify_chain_and_leaves entries

let verify_multi_turn ~sentinel entries =
  (* The read tool result from send 2 must contain the sentinel — this can only
     come from the file on disk, not from context recall. *)
  let tool_results = collect_tool_result_strings entries in
  let read_result_has_sentinel =
    List.exists (contains_sub ~needle:sentinel) tool_results
  in
  if not read_result_has_sentinel then
    Fail
      (Printf.sprintf
         "sentinel '%s' not found in any tool result — read tool did not execute or \
          returned wrong content"
         sentinel)
  else
    match List.last_opt (collect_assistant_texts entries) with
    | None -> Fail "no assistant text found after send 2"
    | Some last ->
        if not (contains_sub ~needle:sentinel last) then
          Fail
            (Printf.sprintf
               "send-2 response does not contain sentinel '%s'; got: '%s'"
               sentinel (String.take 100 last))
        else verify_chain_and_leaves entries

(* ── Provider setup ───────────────────────────────────────────────────────── *)

let build_anthropic_registry () =
  Provider_registry.register Provider_registry.empty ~name:"anthropic"
    (module Anthropic_provider)

(* ── Scenarios ────────────────────────────────────────────────────────────── *)

let scenario_bash_echo ~model ~tmpdir ~env ~registry =
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "bash_echo.jsonl" in
  let sentinel = "pera_echo_42" in
  let adapter = Provider_adapter.create ~registry ~env ~sw in
  let stream_fn = Provider_adapter.stream_fn adapter in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config = make_harness_config ~model ~tmpdir ~session_path ~stream_fn ~exec_env in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      Pera_agent.Agent_harness.send h
        (Printf.sprintf
           "Use the bash tool to run the command `echo %s` and report the exact output."
           sentinel);
      verify_bash_echo sentinel (parse_session_file session_path)

let scenario_file_write ~model ~tmpdir ~env ~registry =
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "file_write.jsonl" in
  let output_file = Filename.concat tmpdir "live_output.txt" in
  let sentinel = "pera_sentinel_xyz" in
  let prompt =
    Printf.sprintf
      "Use the write tool to create the file %s. \
       The file must contain exactly the text `%s` — no extra content, \
       no newline, no explanation."
      output_file sentinel
  in
  let adapter = Provider_adapter.create ~registry ~env ~sw in
  let stream_fn = Provider_adapter.stream_fn adapter in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config = make_harness_config ~model ~tmpdir ~session_path ~stream_fn ~exec_env in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      Pera_agent.Agent_harness.send h prompt;
      verify_file_write ~output_file ~sentinel (parse_session_file session_path)

let scenario_multi_turn ~model ~tmpdir ~env ~registry =
  (* Send 1: write a sentinel to disk. Send 2: use the read tool to read it
     back and reproduce the value. The sentinel in the send-2 tool result can
     only come from the file — the model cannot fabricate it from context
     without actually calling the read tool. *)
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "multi_turn.jsonl" in
  let data_file = Filename.concat tmpdir "mt_data.txt" in
  let sentinel = "pera_token_789" in
  let adapter = Provider_adapter.create ~registry ~env ~sw in
  let stream_fn = Provider_adapter.stream_fn adapter in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config = make_harness_config ~model ~tmpdir ~session_path ~stream_fn ~exec_env in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      Pera_agent.Agent_harness.send h
        (Printf.sprintf
           "Use the write tool to write exactly `%s` to the file %s."
           sentinel data_file);
      Pera_agent.Agent_harness.send h
        (Printf.sprintf
           "Use the read tool to read the file %s and tell me exactly what it contains."
           data_file);
      verify_multi_turn ~sentinel (parse_session_file session_path)

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | None ->
      print_endline "[live] skipped: ANTHROPIC_API_KEY not set";
      exit 0
  | Some _ ->
      let exit_code =
        Eio_main.run @@ fun env ->
        let tmpdir = make_temp_dir env ~prefix:"pera_live_driver" in
        let result =
          try
            let model = model_of_argv () in
            let registry = build_anthropic_registry () in
            Printf.printf "model: %s\n%!" model.Types.id;
            let scenarios =
              [
                ( "bash_echo",
                  scenario_bash_echo ~model ~tmpdir ~env ~registry );
                ( "file_write",
                  scenario_file_write ~model ~tmpdir ~env ~registry );
                ( "multi_turn",
                  scenario_multi_turn ~model ~tmpdir ~env ~registry );
              ]
            in
            List.iter (fun (name, v) -> print_verdict ~tag:"live" ~scenario:name v) scenarios;
            Printf.printf "\n";
            let passed = count_passed scenarios in
            let total = List.length scenarios in
            Printf.printf "%d/%d scenarios passed.\n" passed total;
            if passed = total then 0 else 1
          with e ->
            Printf.eprintf "live_driver crashed: %s\n%!" (Printexc.to_string e);
            1
        in
        cleanup tmpdir;
        result
      in
      exit exit_code
