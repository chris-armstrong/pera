(** Session driver — exercises Session_writer in isolation.

    Five scenarios covering the full entry-type vocabulary:
    1. header_then_leaf — SessionInfo + Leaf
    2. user_assistant_turn — SessionInfo + User + Assistant + Leaf
    3. tool_use_turn — SessionInfo + User + Assistant + ToolResult + Leaf
    4. two_turns — two full turns; proves write_leaf is non-advancing
    5. model_change — SessionInfo + ModelChange + User + Assistant + Leaf

    Exit code: 0 if all scenarios pass, 1 otherwise. *)

open Containers
open Pera_types
open Pera_provider
open Session_jsonl_helpers

(* ── Minimal message builders ─────────────────────────────────────────────── *)

let test_model : Types.model = { id = "test-model"; api = "test" }

let test_usage : Types.usage =
  {
    input_tokens = 0;
    output_tokens = 0;
    cache_read_tokens = 0;
    cache_write_tokens = 0;
    cost_usd = None;
  }

let test_provenance : Types.provenance =
  { api = "test"; provider = "test"; model = "test"; error_message = None }

let make_user_msg text =
  Provider.UserMessage { role = "user"; content = [ Types.UText text ] }

let make_assistant_msg text =
  Provider.AssistantMessage
    {
      content = [ Types.AText text ];
      stop_reason = Types.EndTurn;
      provenance = test_provenance;
      usage = test_usage;
    }

let make_tool_call_msg id name =
  Provider.AssistantMessage
    {
      content = [ Types.AToolCall { id; name; arguments = `Assoc [] } ];
      stop_reason = Types.ToolUse;
      provenance = test_provenance;
      usage = test_usage;
    }

let make_tool_result_msg tool_call_id =
  Provider.ToolResultMessage
    {
      tool_call_id;
      content = `String "result";
      is_error = false;
    }

(* ── Verify helpers ───────────────────────────────────────────────────────── *)

let check_types_match entries expected =
  let types = List.map (get_string "type") entries in
  if List.equal String.equal types expected then None
  else Some (Printf.sprintf "types mismatch: [%s]" (String.concat "; " types))

(** Check that UserMsg2 parents the AssistantMsg1 (not Leaf1), proving
    write_leaf is non-advancing. *)
let check_leaf_non_advancing ~asst1 ~u2 =
  let asst1_id = get_string "id" asst1 in
  match get_string_opt "parent_id" u2 with
  | None -> Error "UserMsg2 has no parent_id"
  | Some pid when not (String.equal pid asst1_id) ->
      Error
        (Printf.sprintf "UserMsg2 parent_id='%s', expected AssistantMsg1 id='%s'"
           pid asst1_id)
  | Some _ -> Ok ()

let check_model_change_fields ~mc ~user =
  let open Result.Syntax in
  let mc_type = get_string "type" mc in
  let* () =
    if String.equal mc_type "model_change" then Ok ()
    else Error (Printf.sprintf "entry type '%s', expected 'model_change'" mc_type)
  in
  let mc_model_id =
    Yojson.Safe.Util.(member "model" mc |> member "id" |> to_string)
  in
  let* () =
    if String.equal mc_model_id "new-model" then Ok ()
    else
      Error
        (Printf.sprintf "model_change model.id='%s', expected 'new-model'" mc_model_id)
  in
  let mc_id = get_string "id" mc in
  match get_string_opt "parent_id" user with
  | None -> Error "UserMessage has no parent_id"
  | Some pid when not (String.equal pid mc_id) ->
      Error
        (Printf.sprintf "UserMessage parent_id='%s', expected ModelChange id='%s'"
           pid mc_id)
  | Some _ -> Ok ()

let verify_header_then_leaf entries =
  match entries with
  | [ si; leaf ] ->
      let si_id = get_string "id" si in
      (match get_string_opt "parent_id" leaf with
      | None -> Fail "leaf has no parent_id"
      | Some pid when not (String.equal pid si_id) ->
          Fail (Printf.sprintf "leaf parent_id='%s', expected '%s'" pid si_id)
      | Some _ ->
          (match check_types_match entries [ "session_info"; "leaf" ] with
          | Some msg -> Fail msg
          | None -> verify_chain_and_leaves entries))
  | _ ->
      Fail (Printf.sprintf "expected 2 entries, got %d" (List.length entries))

let verify_user_assistant_turn entries =
  match entries with
  | [ _; _; _; _ ] ->
      (match check_types_match entries [ "session_info"; "message"; "message"; "leaf" ] with
      | Some msg -> Fail msg
      | None -> verify_chain_and_leaves entries)
  | _ ->
      Fail (Printf.sprintf "expected 4 entries, got %d" (List.length entries))

let verify_tool_use_turn entries =
  match entries with
  | [ _; _; _; _; _ ] ->
      (match
         check_types_match entries
           [ "session_info"; "message"; "message"; "message"; "leaf" ]
       with
      | Some msg -> Fail msg
      | None -> verify_chain_and_leaves entries)
  | _ ->
      Fail (Printf.sprintf "expected 5 entries, got %d" (List.length entries))

let verify_two_turns entries =
  match entries with
  | [ _si; _u1; asst1; _leaf1; u2; _asst2; _leaf2 ] ->
      let expected =
        [ "session_info"; "message"; "message"; "leaf"; "message"; "message"; "leaf" ]
      in
      (match check_types_match entries expected with
      | Some msg -> Fail msg
      | None ->
          (match check_leaf_non_advancing ~asst1 ~u2 with
          | Error msg -> Fail msg
          | Ok () -> verify_chain_and_leaves entries))
  | _ ->
      Fail (Printf.sprintf "expected 7 entries, got %d" (List.length entries))

let verify_model_change entries =
  match entries with
  | [ _si; mc; user; _asst; _leaf ] ->
      (match check_types_match entries
               [ "session_info"; "model_change"; "message"; "message"; "leaf" ]
       with
      | Some msg -> Fail msg
      | None ->
          (match check_model_change_fields ~mc ~user with
          | Error msg -> Fail msg
          | Ok () -> verify_chain_and_leaves entries))
  | _ ->
      Fail (Printf.sprintf "expected 5 entries, got %d" (List.length entries))

(* ── Scenarios ────────────────────────────────────────────────────────────── *)

let run_writes w writes =
  List.fold_left
    (fun acc write ->
      match acc with
      | Error _ as e -> e
      | Ok () -> write w)
    (Ok ()) writes

let scenario_header_then_leaf ~tmpdir ~env =
  let path = Filename.concat tmpdir "s1.jsonl" in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w ->
      (match
         run_writes w
           [ Pera_harness.Session_writer.write_session_info;
             Pera_harness.Session_writer.write_leaf ]
       with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () -> verify_header_then_leaf (parse_session_file path))

let scenario_user_assistant_turn ~tmpdir ~env =
  let path = Filename.concat tmpdir "s2.jsonl" in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w ->
      let writes =
        [ Pera_harness.Session_writer.write_session_info;
          (fun w -> Pera_harness.Session_writer.write_message w (make_user_msg "hi"));
          (fun w -> Pera_harness.Session_writer.write_message w (make_assistant_msg "hello"));
          Pera_harness.Session_writer.write_leaf ]
      in
      (match run_writes w writes with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () -> verify_user_assistant_turn (parse_session_file path))

let scenario_tool_use_turn ~tmpdir ~env =
  let path = Filename.concat tmpdir "s3.jsonl" in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w ->
      let writes =
        [ Pera_harness.Session_writer.write_session_info;
          (fun w -> Pera_harness.Session_writer.write_message w (make_user_msg "do task"));
          (fun w -> Pera_harness.Session_writer.write_message w (make_tool_call_msg "tc1" "bash"));
          (fun w -> Pera_harness.Session_writer.write_message w (make_tool_result_msg "tc1"));
          Pera_harness.Session_writer.write_leaf ]
      in
      (match run_writes w writes with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () -> verify_tool_use_turn (parse_session_file path))

let scenario_two_turns ~tmpdir ~env =
  let path = Filename.concat tmpdir "s4.jsonl" in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w ->
      let writes =
        [ Pera_harness.Session_writer.write_session_info;
          (fun w -> Pera_harness.Session_writer.write_message w (make_user_msg "turn1"));
          (fun w -> Pera_harness.Session_writer.write_message w (make_assistant_msg "reply1"));
          Pera_harness.Session_writer.write_leaf;
          (fun w -> Pera_harness.Session_writer.write_message w (make_user_msg "turn2"));
          (fun w -> Pera_harness.Session_writer.write_message w (make_assistant_msg "reply2"));
          Pera_harness.Session_writer.write_leaf ]
      in
      (match run_writes w writes with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () -> verify_two_turns (parse_session_file path))

let scenario_model_change ~tmpdir ~env =
  let path = Filename.concat tmpdir "s5.jsonl" in
  let new_model : Types.model = { id = "new-model"; api = "test" } in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w ->
      let writes =
        [ Pera_harness.Session_writer.write_session_info;
          (fun w -> Pera_harness.Session_writer.write_model_change w new_model);
          (fun w -> Pera_harness.Session_writer.write_message w (make_user_msg "hello"));
          (fun w -> Pera_harness.Session_writer.write_message w (make_assistant_msg "hi"));
          Pera_harness.Session_writer.write_leaf ]
      in
      (match run_writes w writes with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () -> verify_model_change (parse_session_file path))

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  let exit_code =
    Eio_main.run @@ fun env ->
    let tmpdir = make_temp_dir env ~prefix:"pera_session_driver" in
    let result =
      try
        let scenarios =
          [
            ("header_then_leaf", scenario_header_then_leaf ~tmpdir ~env);
            ("user_assistant_turn", scenario_user_assistant_turn ~tmpdir ~env);
            ("tool_use_turn", scenario_tool_use_turn ~tmpdir ~env);
            ("two_turns", scenario_two_turns ~tmpdir ~env);
            ("model_change", scenario_model_change ~tmpdir ~env);
          ]
        in
        List.iter (fun (name, v) -> print_verdict ~tag:"session" ~scenario:name v) scenarios;
        Printf.printf "\n";
        let passed = count_passed scenarios in
        let total = List.length scenarios in
        Printf.printf "%d/%d scenarios passed.\n" passed total;
        if passed = total then 0 else 1
      with e ->
        Printf.eprintf "session_driver crashed: %s\n%!" (Printexc.to_string e);
        1
    in
    cleanup tmpdir;
    result
  in
  exit exit_code
