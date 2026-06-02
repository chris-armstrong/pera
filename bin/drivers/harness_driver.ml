(** Harness driver — exercises Agent_harness against Faux_provider.

    Three scenarios verifying session log contents and parent chain correctness:
    1. text_only — one text turn; 4 entries in correct order.
    2. tool_use — bash tool call + follow-up text; 6 entries; tool_result present.
    3. subscriber_events — text-only; collected events include key lifecycle markers.

    Exit code: 0 if all scenarios pass, 1 otherwise. *)

open Containers
open Pera_types
open Pera_core
open Pera_core_test_util

(* ── Types ────────────────────────────────────────────────────────────────── *)

type verdict = Pass | Fail of string

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

let make_temp_dir env =
  let tmpdir = Filename.get_temp_dir_name () in
  let pid = Unix.getpid () in
  let ts = Int64.of_float (Unix.gettimeofday ()) in
  let name = Printf.sprintf "pera_harness_driver_%d_%Ld" pid ts in
  let path = Filename.concat tmpdir name in
  Eio.Path.(mkdirs ~exists_ok:false ~perm:0o700 (env#fs / path));
  path

let cleanup path =
  try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote path)))
  with _ -> ()

let print_verdict ~scenario = function
  | Pass -> Printf.printf "[harness] %s ... PASS\n" scenario
  | Fail msg -> Printf.printf "[harness] %s ... FAIL: %s\n" scenario msg

let parse_session_file path =
  let contents = Stdlib.In_channel.(with_open_text path input_all) in
  let lines = String.split_on_char '\n' contents in
  let nonempty = List.filter (fun s -> not (String.is_empty s)) lines in
  List.map Yojson.Safe.from_string nonempty

let get_string key json = Yojson.Safe.Util.(member key json |> to_string)

let get_string_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Null | `String "" -> None
  | `String s -> Some s
  | _ -> None

(** Exclude leaf entries, then check each entry's parent_id = previous id. *)
let check_content_chain entries =
  let content =
    List.filter (fun e -> not (String.equal (get_string "type" e) "leaf")) entries
  in
  let rec check = function
    | [] | [ _ ] -> None
    | prev :: (cur :: _ as rest) ->
        let prev_id = get_string "id" prev in
        let cur_parent = get_string_opt "parent_id" cur in
        (match cur_parent with
        | None ->
            Some (Printf.sprintf "entry '%s' has no parent_id" (get_string "id" cur))
        | Some pid ->
            if String.equal pid prev_id then check rest
            else
              Some
                (Printf.sprintf "chain broken at '%s': parent='%s' expected='%s'"
                   (get_string "id" cur) pid prev_id))
  in
  check content

(** Assert no entry references a leaf id as its parent_id. *)
let assert_leaves_childless entries =
  let leaf_ids =
    List.filter_map
      (fun e ->
        if String.equal (get_string "type" e) "leaf" then Some (get_string "id" e)
        else None)
      entries
  in
  List.find_opt
    (fun e ->
      match get_string_opt "parent_id" e with
      | Some pid -> List.mem pid leaf_ids
      | None -> false)
    entries

(* ── Faux script helpers ──────────────────────────────────────────────────── *)

let faux_model : Types.model = { id = "faux-model"; api = "faux" }

let make_assistant_msg ?(stop_reason = Types.EndTurn) text =
  Types.
    {
      content = [ AText text ];
      stop_reason;
      provenance = { api = "faux"; provider = "faux"; model = "faux"; error_message = None };
      usage =
        {
          input_tokens = 0;
          output_tokens = 0;
          cache_read_tokens = 0;
          cache_write_tokens = 0;
          cost_usd = None;
        };
    }

let make_tool_use_msg tool_call_id tool_name arguments =
  Types.
    {
      content = [ AToolCall { id = tool_call_id; name = tool_name; arguments } ];
      stop_reason = ToolUse;
      provenance = { api = "faux"; provider = "faux"; model = "faux"; error_message = None };
      usage =
        {
          input_tokens = 0;
          output_tokens = 0;
          cache_read_tokens = 0;
          cache_write_tokens = 0;
          cost_usd = None;
        };
    }

let text_turn text =
  let msg = make_assistant_msg text in
  Faux_provider.Turn
    Faux_provider.
      {
        events = [ Types.AME_text_start { partial = msg } ];
        final = msg;
      }

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

(* ── Scenarios ────────────────────────────────────────────────────────────── *)

let scenario_text_only ~tmpdir ~env ~sw =
  let session_path = Filename.concat tmpdir "text_only.jsonl" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ text_turn "Hello!" ] in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config =
    Pera_agent.Agent_harness.
      {
        cwd = tmpdir;
        model = faux_model;
        session_path;
        stream_fn;
        max_tokens = 1024;
        exec_env;
      }
  in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      Pera_agent.Agent_harness.send h "What is 2+2?";
      let entries = parse_session_file session_path in
      if List.length entries <> 4 then
        Fail (Printf.sprintf "expected 4 entries, got %d" (List.length entries))
      else
        let types = List.map (get_string "type") entries in
        let expected = [ "session_info"; "message"; "message"; "leaf" ] in
        if not (List.equal String.equal types expected) then
          Fail (Printf.sprintf "types mismatch: [%s]" (String.concat "; " types))
        else
          match check_content_chain entries with
          | Some msg -> Fail ("content chain broken: " ^ msg)
          | None ->
              match assert_leaves_childless entries with
              | Some _ -> Fail "a leaf has a child entry"
              | None ->
                  (* Verify second entry role is 'user' *)
                  let user_entry = List.nth entries 1 in
                  let msg_json = Yojson.Safe.Util.(member "message" user_entry) in
                  let role = get_string "role" msg_json in
                  if not (String.equal role "user") then
                    Fail (Printf.sprintf "second entry role='%s', expected 'user'" role)
                  else Pass

let scenario_tool_use ~tmpdir ~env ~sw =
  (* Turn 1: bash tool call "echo hello". Turn 2: text EndTurn. *)
  let session_path = Filename.concat tmpdir "tool_use.jsonl" in
  let bash_args = `Assoc [ ("command", `String "echo hello") ] in
  let script1 = tool_use_turn "tc-bash-1" "bash" bash_args in
  let script2 = text_turn "Done." in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ script1; script2 ] in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config =
    Pera_agent.Agent_harness.
      {
        cwd = tmpdir;
        model = faux_model;
        session_path;
        stream_fn;
        max_tokens = 1024;
        exec_env;
      }
  in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      Pera_agent.Agent_harness.send h "Run bash echo.";
      let entries = parse_session_file session_path in
      (* Expected: session_info + user + asst(tool_use) + tool_result + asst(end_turn) + leaf *)
      if List.length entries <> 6 then
        Fail (Printf.sprintf "expected 6 entries, got %d" (List.length entries))
      else
        let types = List.map (get_string "type") entries in
        let expected =
          [ "session_info"; "message"; "message"; "message"; "message"; "leaf" ]
        in
        if not (List.equal String.equal types expected) then
          Fail (Printf.sprintf "types mismatch: [%s]" (String.concat "; " types))
        else
          (* Verify a tool_result message exists (role = 'tool_result') *)
          let has_tool_result =
            List.exists
              (fun e ->
                let t = get_string "type" e in
                if String.equal t "message" then
                  let msg_json = Yojson.Safe.Util.member "message" e in
                  let role = get_string_opt "role" msg_json in
                  match role with
                  | Some r -> String.equal r "tool_result"
                  | None -> false
                else false)
              entries
          in
          if not has_tool_result then
            Fail "no tool_result message entry found"
          else
            match check_content_chain entries with
            | Some msg -> Fail ("content chain broken: " ^ msg)
            | None ->
                match assert_leaves_childless entries with
                | Some _ -> Fail "a leaf has a child entry"
                | None -> Pass

let scenario_subscriber_events ~tmpdir ~env ~sw =
  let session_path = Filename.concat tmpdir "subscriber.jsonl" in
  let stream_fn = Faux_provider.stream_fn_of_scripts [ text_turn "Hello sub!" ] in
  let exec_env = Pera_env.Local_env.create ~env ~cwd:tmpdir in
  let config =
    Pera_agent.Agent_harness.
      {
        cwd = tmpdir;
        model = faux_model;
        session_path;
        stream_fn;
        max_tokens = 1024;
        exec_env;
      }
  in
  match Pera_agent.Agent_harness.create ~config ~env ~sw with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok h ->
      let collected = ref [] in
      let _unsub =
        Pera_agent.Agent_harness.subscribe h (fun event ->
            collected := !collected @ [ event ])
      in
      Pera_agent.Agent_harness.send h "Subscribe test.";
      let events = !collected in
      let has_agent_start =
        List.exists (function Agent_types.AE_agent_start -> true | _ -> false) events
      in
      let has_turn_start =
        List.exists (function Agent_types.AE_turn_start -> true | _ -> false) events
      in
      let has_agent_end =
        List.exists (function Agent_types.AE_agent_end _ -> true | _ -> false) events
      in
      if not has_agent_start then Fail "missing AE_agent_start"
      else if not has_turn_start then Fail "missing AE_turn_start"
      else if not has_agent_end then Fail "missing AE_agent_end"
      else Pass

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  let exit_code =
    Eio_main.run @@ fun env ->
    let tmpdir = make_temp_dir env in
    let result =
      try
        Eio.Switch.run @@ fun sw ->
        let scenarios =
          [
            ("text_only", scenario_text_only ~tmpdir ~env ~sw);
            ("tool_use", scenario_tool_use ~tmpdir ~env ~sw);
            ("subscriber_events", scenario_subscriber_events ~tmpdir ~env ~sw);
          ]
        in
        List.iter (fun (name, v) -> print_verdict ~scenario:name v) scenarios;
        Printf.printf "\n";
        let passed =
          List.length
            (List.filter (fun (_, v) -> match v with Pass -> true | Fail _ -> false) scenarios)
        in
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
