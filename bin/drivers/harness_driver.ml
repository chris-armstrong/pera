(** Harness driver — exercises Agent_harness against Faux_provider.

    Three scenarios verifying session log contents and parent chain correctness:
    1. text_only — one text turn; 4 entries in correct order. 2. tool_use — bash
    tool call + follow-up text; 6 entries; tool_result present. 3.
    subscriber_events — text-only; collected events include key lifecycle
    markers.

    Exit code: 0 if all scenarios pass, 1 otherwise. *)

open Containers
open Pera_types
open Pera_core
open Pera_core_test_util
open Session_jsonl_helpers

(* ── Faux script helpers ──────────────────────────────────────────────────── *)

let faux_model : Types.model =
  { id = "faux-model"; api = "faux"; context_window = 200_000 }

let faux_provenance : Types.provenance =
  { api = "faux"; provider = "faux"; model = "faux"; error_message = None }

let faux_usage : Types.usage =
  {
    input_tokens = 0;
    output_tokens = 0;
    cache_read_tokens = 0;
    cache_write_tokens = 0;
    cost_usd = None;
  }

let make_assistant_msg text =
  Types.
    {
      content = [ AText text ];
      stop_reason = EndTurn;
      provenance = faux_provenance;
      usage = faux_usage;
    }

let make_tool_use_msg tool_call_id tool_name arguments =
  Types.
    {
      content = [ AToolCall { id = tool_call_id; name = tool_name; arguments } ];
      stop_reason = ToolUse;
      provenance = faux_provenance;
      usage = faux_usage;
    }

let text_turn text =
  let msg = make_assistant_msg text in
  Faux_provider.Turn
    Faux_provider.
      { events = [ Types.AME_text_start { partial = msg } ]; final = msg }

let tool_use_turn tool_call_id tool_name arguments =
  let msg = make_tool_use_msg tool_call_id tool_name arguments in
  Faux_provider.Turn
    Faux_provider.
      {
        events =
          [
            Types.AME_tool_call_start
              { index = 0; id = tool_call_id; name = tool_name; partial = msg };
          ];
        final = msg;
      }

(* ── Harness config helper ────────────────────────────────────────────────── *)

let make_harness_config ~tmpdir ~session_path ~stream_fn ~exec_env :
    Pera_agent.Agent_harness.config =
  {
    cwd = tmpdir;
    model = faux_model;
    session_path;
    stream_fn;
    max_tokens = 1024;
    exec_env;
  }

(* ── Entry predicate ──────────────────────────────────────────────────────── *)

let is_tool_result_entry e =
  if not (String.equal (get_string "type" e) "message") then false
  else
    let msg_json = Yojson.Safe.Util.member "message" e in
    match get_string_opt "role" msg_json with
    | Some r -> String.equal r "tool_result"
    | None -> false

(* ── Verify helpers ───────────────────────────────────────────────────────── *)

let verify_text_only_entries entries =
  match entries with
  | [ _si; user_msg; _asst; _leaf ] -> (
      let types = List.map (get_string "type") entries in
      let expected = [ "session_info"; "message"; "message"; "leaf" ] in
      if not (List.equal String.equal types expected) then
        Fail (Printf.sprintf "types mismatch: [%s]" (String.concat "; " types))
      else
        let msg_json = Yojson.Safe.Util.member "message" user_msg in
        match get_string_opt "role" msg_json with
        | Some r when String.equal r "user" -> verify_chain_and_leaves entries
        | Some r ->
            Fail (Printf.sprintf "second entry role='%s', expected 'user'" r)
        | None -> Fail "second entry has no role field")
  | _ ->
      Fail (Printf.sprintf "expected 4 entries, got %d" (List.length entries))

let verify_tool_use_entries entries =
  match entries with
  | [ _; _; _; _; _; _ ] ->
      let types = List.map (get_string "type") entries in
      let expected =
        [ "session_info"; "message"; "message"; "message"; "message"; "leaf" ]
      in
      if not (List.equal String.equal types expected) then
        Fail (Printf.sprintf "types mismatch: [%s]" (String.concat "; " types))
      else if not (List.exists is_tool_result_entry entries) then
        Fail "no tool_result message entry found"
      else verify_chain_and_leaves entries
  | _ ->
      Fail (Printf.sprintf "expected 6 entries, got %d" (List.length entries))

(* ── Scenarios (each runs under its own sub-switch) ──────────────────────── *)

let scenario_text_only ~tmpdir ~env =
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "text_only.jsonl" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ text_turn "Hello!" ] in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config = make_harness_config ~tmpdir ~session_path ~stream_fn ~exec_env in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      Pera_agent.Agent_harness.send h "What is 2+2?";
      verify_text_only_entries (parse_session_file session_path)

let scenario_tool_use ~tmpdir ~env =
  (* Turn 1: bash "echo hello". Turn 2: text EndTurn. *)
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "tool_use.jsonl" in
  let bash_args = `Assoc [ ("command", `String "echo hello") ] in
  let script1 = tool_use_turn "tc-bash-1" "bash" bash_args in
  let script2 = text_turn "Done." in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config = make_harness_config ~tmpdir ~session_path ~stream_fn ~exec_env in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      Pera_agent.Agent_harness.send h "Run bash echo.";
      verify_tool_use_entries (parse_session_file session_path)

let scenario_subscriber_events ~tmpdir ~env =
  Eio.Switch.run @@ fun sw ->
  let session_path = Filename.concat tmpdir "subscriber.jsonl" in
  let stream_fn =
    Faux_provider.stream_fn_of_scripts [ text_turn "Hello sub!" ]
  in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config = make_harness_config ~tmpdir ~session_path ~stream_fn ~exec_env in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      let collected = ref [] in
      let _unsub =
        Pera_agent.Agent_harness.subscribe h (fun event ->
            collected := event :: !collected)
      in
      Pera_agent.Agent_harness.send h "Subscribe test.";
      let events = List.rev !collected in
      let has ev_pred = List.exists ev_pred events in
      if not (has (function Agent_types.AE_agent_start -> true | _ -> false))
      then Fail "missing AE_agent_start"
      else if
        not (has (function Agent_types.AE_turn_start -> true | _ -> false))
      then Fail "missing AE_turn_start"
      else if
        not (has (function Agent_types.AE_agent_end _ -> true | _ -> false))
      then Fail "missing AE_agent_end"
      else Pass

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  let exit_code =
    Eio_main.run @@ fun env ->
    let tmpdir = make_temp_dir env ~prefix:"pera_harness_driver" in
    let result =
      try
        let scenarios =
          [
            ("text_only", scenario_text_only ~tmpdir ~env);
            ("tool_use", scenario_tool_use ~tmpdir ~env);
            ("subscriber_events", scenario_subscriber_events ~tmpdir ~env);
          ]
        in
        List.iter
          (fun (name, v) -> print_verdict ~tag:"harness" ~scenario:name v)
          scenarios;
        Printf.printf "\n";
        let passed = count_passed scenarios in
        let total = List.length scenarios in
        Printf.printf "%d/%d scenarios passed.\n" passed total;
        if passed = total then 0 else 1
      with e ->
        Printf.eprintf "harness_driver crashed: %s\n%!" (Printexc.to_string e);
        1
    in
    cleanup tmpdir;
    result
  in
  exit exit_code
