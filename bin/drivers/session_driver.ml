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

(* ── Types ────────────────────────────────────────────────────────────────── *)

type verdict = Pass | Fail of string

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

let make_temp_dir env =
  let tmpdir = Filename.get_temp_dir_name () in
  let pid = Unix.getpid () in
  let ts = Int64.of_float (Unix.gettimeofday ()) in
  let name = Printf.sprintf "pera_session_driver_%d_%Ld" pid ts in
  let path = Filename.concat tmpdir name in
  Eio.Path.(mkdirs ~exists_ok:false ~perm:0o700 (env#fs / path));
  path

let cleanup path =
  try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote path)))
  with _ -> ()

let print_verdict ~scenario = function
  | Pass -> Printf.printf "[session] %s ... PASS\n" scenario
  | Fail msg -> Printf.printf "[session] %s ... FAIL: %s\n" scenario msg

let parse_session_file path =
  let contents = Stdlib.In_channel.(with_open_text path input_all) in
  let lines = String.split_on_char '\n' contents in
  let nonempty = List.filter (fun s -> not (String.is_empty s)) lines in
  List.map Yojson.Safe.from_string nonempty

let get_field key json = Yojson.Safe.Util.(member key json)
let get_string key json = Yojson.Safe.Util.(member key json |> to_string)

let get_string_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Null | `String "" -> None
  | `String s -> Some s
  | _ -> None

(** Check that each non-leaf content entry's parent_id equals the previous
    content entry's id. Leaf entries are excluded from the chain. *)
let check_content_chain entries =
  let content = List.filter (fun e -> not (String.equal (get_string "type" e) "leaf")) entries in
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
                (Printf.sprintf "parent chain broken: entry '%s' parent_id='%s' expected '%s'"
                   (get_string "id" cur) pid prev_id))
  in
  check content

(** Assert no entry references a leaf id as its parent_id. *)
let assert_leaves_childless entries =
  let leaf_ids =
    List.filter_map
      (fun e ->
        if String.equal (get_string "type" e) "leaf" then
          Some (get_string "id" e)
        else None)
      entries
  in
  List.find_opt
    (fun e ->
      match get_string_opt "parent_id" e with
      | Some pid -> List.mem pid leaf_ids
      | None -> false)
    entries

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

(* ── Scenarios ────────────────────────────────────────────────────────────── *)

let scenario_header_then_leaf ~tmpdir ~env =
  let path = Filename.concat tmpdir "s1.jsonl" in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w -> (
      match
        let open Result.Syntax in
        let* () = Pera_harness.Session_writer.write_session_info w in
        Pera_harness.Session_writer.write_leaf w
      with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () ->
          let entries = parse_session_file path in
          if List.length entries <> 2 then
            Fail (Printf.sprintf "expected 2 entries, got %d" (List.length entries))
          else
            let si = List.nth entries 0 in
            let leaf = List.nth entries 1 in
            let si_type = get_string "type" si in
            let leaf_type = get_string "type" leaf in
            let si_id = get_string "id" si in
            let leaf_parent = get_string_opt "parent_id" leaf in
            if not (String.equal si_type "session_info") then
              Fail (Printf.sprintf "first entry type '%s', expected 'session_info'" si_type)
            else if not (String.equal leaf_type "leaf") then
              Fail (Printf.sprintf "second entry type '%s', expected 'leaf'" leaf_type)
            else
              match leaf_parent with
              | None -> Fail "leaf has no parent_id"
              | Some pid ->
                  if String.equal pid si_id then Pass
                  else
                    Fail (Printf.sprintf "leaf parent_id='%s' expected '%s'" pid si_id))

let scenario_user_assistant_turn ~tmpdir ~env =
  let path = Filename.concat tmpdir "s2.jsonl" in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w -> (
      match
        let open Result.Syntax in
        let* () = Pera_harness.Session_writer.write_session_info w in
        let* () = Pera_harness.Session_writer.write_message w (make_user_msg "hi") in
        let* () = Pera_harness.Session_writer.write_message w (make_assistant_msg "hello") in
        Pera_harness.Session_writer.write_leaf w
      with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () ->
          let entries = parse_session_file path in
          if List.length entries <> 4 then
            Fail (Printf.sprintf "expected 4 entries, got %d" (List.length entries))
          else
            let types = List.map (get_string "type") entries in
            let expected = [ "session_info"; "message"; "message"; "leaf" ] in
            if not (List.equal String.equal types expected) then
              Fail (Printf.sprintf "types mismatch: %s" (String.concat "," types))
            else
              match check_content_chain entries with
              | Some msg -> Fail ("content chain broken: " ^ msg)
              | None ->
                  match assert_leaves_childless entries with
                  | Some _ -> Fail "a leaf has a child entry"
                  | None -> Pass)

let scenario_tool_use_turn ~tmpdir ~env =
  let path = Filename.concat tmpdir "s3.jsonl" in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w -> (
      match
        let open Result.Syntax in
        let* () = Pera_harness.Session_writer.write_session_info w in
        let* () = Pera_harness.Session_writer.write_message w (make_user_msg "do task") in
        let* () = Pera_harness.Session_writer.write_message w (make_tool_call_msg "tc1" "bash") in
        let* () = Pera_harness.Session_writer.write_message w (make_tool_result_msg "tc1") in
        Pera_harness.Session_writer.write_leaf w
      with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () ->
          let entries = parse_session_file path in
          if List.length entries <> 5 then
            Fail (Printf.sprintf "expected 5 entries, got %d" (List.length entries))
          else
            let types = List.map (get_string "type") entries in
            let expected = [ "session_info"; "message"; "message"; "message"; "leaf" ] in
            if not (List.equal String.equal types expected) then
              Fail (Printf.sprintf "types mismatch: %s" (String.concat "," types))
            else
              match check_content_chain entries with
              | Some msg -> Fail ("content chain broken: " ^ msg)
              | None ->
                  match assert_leaves_childless entries with
                  | Some _ -> Fail "a leaf has a child entry"
                  | None -> Pass)

let scenario_two_turns ~tmpdir ~env =
  (* Proves write_leaf is non-advancing: UserMsg2.parent_id = AssistantMsg1.id,
     not Leaf1.id. *)
  let path = Filename.concat tmpdir "s4.jsonl" in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w -> (
      match
        let open Result.Syntax in
        let* () = Pera_harness.Session_writer.write_session_info w in
        let* () = Pera_harness.Session_writer.write_message w (make_user_msg "turn1") in
        let* () = Pera_harness.Session_writer.write_message w (make_assistant_msg "reply1") in
        let* () = Pera_harness.Session_writer.write_leaf w in
        let* () = Pera_harness.Session_writer.write_message w (make_user_msg "turn2") in
        let* () = Pera_harness.Session_writer.write_message w (make_assistant_msg "reply2") in
        Pera_harness.Session_writer.write_leaf w
      with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () ->
          let entries = parse_session_file path in
          if List.length entries <> 7 then
            Fail (Printf.sprintf "expected 7 entries, got %d" (List.length entries))
          else
            (* UserMsg2 (index 4) parent_id must equal AssistantMsg1 (index 2) id *)
            let asst1_id = get_string "id" (List.nth entries 2) in
            let user2_parent = get_string_opt "parent_id" (List.nth entries 4) in
            (match user2_parent with
            | None -> Fail "UserMsg2 has no parent_id"
            | Some pid when not (String.equal pid asst1_id) ->
                Fail
                  (Printf.sprintf
                     "UserMsg2 parent_id='%s', expected AssistantMsg1 id='%s'"
                     pid asst1_id)
            | Some _ ->
                match check_content_chain entries with
                | Some msg -> Fail ("content chain broken: " ^ msg)
                | None ->
                    match assert_leaves_childless entries with
                    | Some _ -> Fail "a leaf has a child entry"
                    | None -> Pass))

let scenario_model_change ~tmpdir ~env =
  let path = Filename.concat tmpdir "s5.jsonl" in
  let new_model : Types.model = { id = "new-model"; api = "test" } in
  match Pera_harness.Session_writer.create ~path ~env ~model:test_model ~cwd:tmpdir with
  | Error e -> Fail (Printf.sprintf "create failed: %s" e.Types.message)
  | Ok w -> (
      match
        let open Result.Syntax in
        let* () = Pera_harness.Session_writer.write_session_info w in
        let* () = Pera_harness.Session_writer.write_model_change w new_model in
        let* () = Pera_harness.Session_writer.write_message w (make_user_msg "hello") in
        let* () = Pera_harness.Session_writer.write_message w (make_assistant_msg "hi") in
        Pera_harness.Session_writer.write_leaf w
      with
      | Error e -> Fail (Printf.sprintf "write failed: %s" e.Types.message)
      | Ok () ->
          let entries = parse_session_file path in
          if List.length entries <> 5 then
            Fail (Printf.sprintf "expected 5 entries, got %d" (List.length entries))
          else
            let mc = List.nth entries 1 in
            let mc_type = get_string "type" mc in
            let mc_model_id =
              Yojson.Safe.Util.(get_field "model" mc |> member "id" |> to_string)
            in
            if not (String.equal mc_type "model_change") then
              Fail (Printf.sprintf "second entry type '%s', expected 'model_change'" mc_type)
            else if not (String.equal mc_model_id "new-model") then
              Fail (Printf.sprintf "model_change model.id='%s', expected 'new-model'" mc_model_id)
            else
              (* UserMessage (index 2) parent_id must equal ModelChange (index 1) id *)
              let mc_id = get_string "id" mc in
              let user_parent = get_string_opt "parent_id" (List.nth entries 2) in
              match user_parent with
              | None -> Fail "UserMessage has no parent_id"
              | Some pid when not (String.equal pid mc_id) ->
                  Fail
                    (Printf.sprintf "UserMessage parent_id='%s', expected ModelChange id='%s'"
                       pid mc_id)
              | Some _ ->
                  match check_content_chain entries with
                  | Some msg -> Fail ("content chain broken: " ^ msg)
                  | None ->
                      match assert_leaves_childless entries with
                      | Some _ -> Fail "a leaf has a child entry"
                      | None -> Pass)

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  let exit_code =
    Eio_main.run @@ fun env ->
    let tmpdir = make_temp_dir env in
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
        List.iter (fun (name, v) -> print_verdict ~scenario:name v) scenarios;
        Printf.printf "\n";
        let passed = List.length (List.filter (fun (_, v) -> match v with Pass -> true | Fail _ -> false) scenarios) in
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
