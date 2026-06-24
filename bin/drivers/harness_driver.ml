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

let large_filler = String.make 1200 'x'

let large_tool_use_turn tool_call_id tool_name arguments =
  let msg =
    Types.
      {
        content =
          [
            AText large_filler;
            AToolCall { id = tool_call_id; name = tool_name; arguments };
          ];
        stop_reason = ToolUse;
        provenance = faux_provenance;
        usage = faux_usage;
      }
  in
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

let summary_turn () =
  let msg =
    Types.
      {
        content = [ AText "COMPACTED SUMMARY" ];
        stop_reason = EndTurn;
        provenance = faux_provenance;
        usage = faux_usage;
      }
  in
  Faux_provider.Turn
    Faux_provider.
      { events = [ Types.AME_text_start { partial = msg } ]; final = msg }

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
    system_prompt = Pera_agent.Agent_harness.default_system_prompt;
    thinking_budget_tokens = None;
    compaction = None;
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

(* ── Compaction scenario verify helpers ───────────────────────────────────── *)

let positions_of pred events =
  List.filter_map
    (fun (i, e) -> if pred e then Some i else None)
    (List.mapi (fun i e -> (i, e)) events)

let check_compaction_event_counts events =
  let open Result.Syntax in
  let count pred = List.length (List.filter pred events) in
  let n_start =
    count (function Agent_types.AE_compaction_start -> true | _ -> false)
  in
  let n_end =
    count (function Agent_types.AE_compaction_end _ -> true | _ -> false)
  in
  let n_error =
    count (function Agent_types.AE_compaction_error _ -> true | _ -> false)
  in
  let* () =
    if Int.equal n_start 1 then Ok ()
    else
      Error
        (Printf.sprintf "expected 1 AE_compaction_start, got %d" n_start)
  in
  let* () =
    if Int.equal n_end 1 then Ok ()
    else
      Error (Printf.sprintf "expected 1 AE_compaction_end, got %d" n_end)
  in
  let* () =
    if Int.equal n_error 0 then Ok ()
    else Error "unexpected AE_compaction_error event"
  in
  if List.exists (function Agent_types.AE_agent_end _ -> true | _ -> false) events
  then Ok ()
  else Error "missing AE_agent_end"

let check_compaction_event_ordering events =
  let turn_end_positions =
    positions_of (function Agent_types.AE_turn_end _ -> true | _ -> false) events
  in
  let compaction_start_positions =
    positions_of
      (function Agent_types.AE_compaction_start -> true | _ -> false)
      events
  in
  match (List.drop 2 turn_end_positions, compaction_start_positions) with
  | t3_pos :: t4_pos :: _, [ cs_pos ] ->
      if not (cs_pos > t3_pos) then
        Error
          (Printf.sprintf
             "AE_compaction_start (pos %d) not after 3rd AE_turn_end (pos %d)"
             cs_pos t3_pos)
      else if not (cs_pos < t4_pos) then
        Error
          (Printf.sprintf
             "AE_compaction_start (pos %d) not before final AE_turn_end \
              (pos %d)"
             cs_pos t4_pos)
      else Ok ()
  | turn_tail, cs_positions ->
      Error
        (Printf.sprintf
           "unexpected shape: %d AE_turn_end after drop-2, %d \
            AE_compaction_start"
           (List.length turn_tail)
           (List.length cs_positions))

let find_compaction_idx entries =
  let rec go i = function
    | [] -> None
    | e :: rest ->
        if String.equal (get_string "type" e) "compaction" then Some i
        else go (i + 1) rest
  in
  go 0 entries

let check_compaction_summary_field compaction_entry =
  match get_string_opt "summary" compaction_entry with
  | None -> Error "compaction entry missing 'summary'"
  | Some s when String.equal s "" -> Error "compaction entry 'summary' is empty"
  | Some _ -> Ok ()

let find_text_in_content content_json =
  let blocks =
    try Yojson.Safe.Util.to_list content_json with _ -> []
  in
  match
    List.find_opt
      (fun b ->
        match get_string_opt "type" b with
        | Some "text" -> true
        | _ -> false)
      blocks
  with
  | None -> None
  | Some b -> get_string_opt "text" b

let check_synthetic_follows_compaction compaction_entry synth_entry =
  let open Result.Syntax in
  let comp_id = get_string "id" compaction_entry in
  let msg_json = Yojson.Safe.Util.member "message" synth_entry in
  let* () =
    match get_string_opt "role" msg_json with
    | Some r when String.equal r "user" -> Ok ()
    | Some r ->
        Error (Printf.sprintf "synthetic role='%s', expected 'user'" r)
    | None -> Error "synthetic message entry has no 'role' field"
  in
  let content_json = Yojson.Safe.Util.member "content" msg_json in
  let* text =
    match find_text_in_content content_json with
    | Some t -> Ok t
    | None -> Error "synthetic message has no text block"
  in
  let framing = Pera_core.Agent_types.compaction_framing in
  let* () =
    if Int.equal (String.find ~sub:framing text) 0 then Ok ()
    else Error "synthetic message text does not start with compaction_framing"
  in
  let synth_parent = get_string_opt "parent_id" synth_entry in
  if Option.exists (String.equal comp_id) synth_parent then Ok ()
  else
    Error
      (Printf.sprintf
         "synthetic parent_id='%s', expected compaction id='%s'"
         (Option.value ~default:"<none>" synth_parent)
         comp_id)

let check_leaf_count entries expected =
  let n =
    List.length
      (List.filter
         (fun e -> String.equal (get_string "type" e) "leaf")
         entries)
  in
  if Int.equal n expected then Ok ()
  else
    Error (Printf.sprintf "expected %d leaf entries, got %d" expected n)

let verify_autonomous_compaction_session entries =
  (* Expected session structure for a 3-tool-turn run with one compaction:
     session_info, user, asst×3 interleaved with tool_result×3,
     compaction, synthetic_user, leaf (compaction-time),
     asst4 (final text), leaf (end-of-run). *)
  let expected_types =
    [
      "session_info";
      "message";
      "message";
      "message";
      "message";
      "message";
      "message";
      "message";
      "compaction";
      "message";
      "leaf";
      "message";
      "leaf";
    ]
  in
  let actual_types = List.map (get_string "type") entries in
  let open Result.Syntax in
  let checks =
    let* () =
      if List.equal String.equal actual_types expected_types then Ok ()
      else
        Error
          (Printf.sprintf "types mismatch: got [%s]"
             (String.concat "; " actual_types))
    in
    let* () = check_leaf_count entries 2 in
    let* ci =
      match find_compaction_idx entries with
      | Some i -> Ok i
      | None -> Error "no compaction entry found"
    in
    match (List.get_at_idx ci entries, List.get_at_idx (ci + 1) entries) with
    | None, _ -> Error "compaction entry not accessible by index"
    | _, None -> Error "no entry immediately after compaction entry"
    | Some ce, Some se ->
        let* () = check_compaction_summary_field ce in
        check_synthetic_follows_compaction ce se
  in
  match checks with
  | Error msg -> Fail msg
  | Ok () -> verify_chain_and_leaves entries

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

let scenario_autonomous_compaction ~tmpdir ~env =
  (* Scripts consumed in call order:
     [0] turn 1 — large bash tool call (echo a)
     [1] turn 2 — large bash tool call (echo b)
     [2] turn 3 — large bash tool call (echo c)  ← compaction fires after this
     [3] summarisation call — consumed by Compaction.compact inside should_stop
     [4] turn 4 — final text turn (EndTurn)
     trigger_tokens=1000: estimate after turn 3 ≈ 1250 > 1000; after turn 2 ≈ 840. *)
  Eio.Switch.run @@ fun sw ->
  let session_path =
    Filename.concat tmpdir "autonomous_compaction.jsonl"
  in
  let bash_args cmd = `Assoc [ ("command", `String cmd) ] in
  let scripts =
    [
      large_tool_use_turn "tc-1" "bash" (bash_args "echo a");
      large_tool_use_turn "tc-2" "bash" (bash_args "echo b");
      large_tool_use_turn "tc-3" "bash" (bash_args "echo c");
      summary_turn ();
      text_turn "All done.";
    ]
  in
  let stream_fn = Faux_provider.stream_fn_of_scripts scripts in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let compaction_cfg =
    Pera_agent.Agent_harness.{ trigger_tokens = 1000; tail_size = 2 }
  in
  let config : Pera_agent.Agent_harness.config =
    {
      cwd = tmpdir;
      model = faux_model;
      session_path;
      stream_fn;
      max_tokens = 1024;
      exec_env;
      system_prompt = Pera_agent.Agent_harness.default_system_prompt;
      thinking_budget_tokens = None;
      compaction = Some compaction_cfg;
    }
  in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      let collected = ref [] in
      let _unsub =
        Pera_agent.Agent_harness.subscribe h (fun event ->
            collected := event :: !collected)
      in
      Pera_agent.Agent_harness.send h "do task";
      let events = List.rev !collected in
      let entries = parse_session_file session_path in
      let event_check =
        let open Result.Syntax in
        let* () = check_compaction_event_counts events in
        let* () = check_compaction_event_ordering events in
        Ok ()
      in
      (match event_check with
      | Error msg -> Fail ("event check: " ^ msg)
      | Ok () -> verify_autonomous_compaction_session entries)

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
            ( "autonomous_compaction",
              scenario_autonomous_compaction ~tmpdir ~env );
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
