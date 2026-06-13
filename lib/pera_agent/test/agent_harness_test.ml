open Containers
open Pera_core_test_util
open Yojson.Safe.Util

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let test_model =
  Pera_types.Types.{ id = "test-model"; api = "faux"; context_window = 200_000 }

let make_temp_dir = Harness_test_util.make_temp_dir

let make_text_turn_script text =
  let make_am content =
    Pera_types.Types.
      {
        content;
        stop_reason = EndTurn;
        provenance =
          {
            api = "faux";
            provider = "faux";
            model = "faux";
            error_message = None;
          };
        usage =
          {
            input_tokens = 0;
            output_tokens = 0;
            cache_read_tokens = 0;
            cache_write_tokens = 0;
            cost_usd = None;
          };
      }
  in
  let partial_msg = make_am [ Pera_types.Types.AText "" ] in
  let final_msg = make_am [ Pera_types.Types.AText text ] in
  Faux_provider.Turn
    Faux_provider.
      {
        events =
          [
            Pera_types.Types.AME_text_start { partial = partial_msg };
            Pera_types.Types.AME_text_delta { text; partial = final_msg };
          ];
        final = final_msg;
      }

(** Build a harness config using the Faux_provider with the given scripts. *)
let make_config ~env ~cwd ~session_path scripts =
  let exec_env = Pera_env.Local_env.create ~env ~cwd in
  let stream_fn = Faux_provider.stream_fn_of_scripts scripts in
  Pera_agent.Agent_harness.
    {
      cwd;
      model = test_model;
      session_path;
      stream_fn;
      max_tokens = 1024;
      exec_env;
    }

let read_jsonl_lines env path =
  let content = Eio.Path.load Eio.Path.(env#fs / path) in
  String.split_on_char '\n' content
  |> List.filter (fun s -> not (String.is_empty s))
  |> List.map Yojson.Safe.from_string

let get_str json key = member key json |> to_string

(* ── Tests ───────────────────────────────────────────────────────────────── *)

(** 1. After send, session file exists at configured path. *)
let test_send_creates_session_file env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path [ make_text_turn_script "hi" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  Pera_agent.Agent_harness.send t "hello";
  let exists =
    match Eio.Path.kind ~follow:true Eio.Path.(env#fs / session_path) with
    | `Regular_file -> true
    | _ -> false
    | exception _ -> false
  in
  Alcotest.(check bool) "session file exists" true exists

(** 2. First line of session file has type:'session_info'. *)
let test_session_file_contains_session_info_on_first_send env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path [ make_text_turn_script "hi" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  Pera_agent.Agent_harness.send t "hello";
  let lines = read_jsonl_lines env session_path in
  let first = List.get_at_idx 0 lines |> Option.get_exn_or "first line" in
  Alcotest.(check string)
    "first line type is session_info" "session_info" (get_str first "type")

(** 3. Second line has type:'message', role:'user', text matching input. *)
let test_session_file_contains_user_message env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path [ make_text_turn_script "reply" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  Pera_agent.Agent_harness.send t "user input text";
  let lines = read_jsonl_lines env session_path in
  let second = List.get_at_idx 1 lines |> Option.get_exn_or "second line" in
  Alcotest.(check string) "type is message" "message" (get_str second "type");
  let role = second |> member "message" |> member "role" |> to_string in
  Alcotest.(check string) "role is user" "user" role;
  let text =
    second |> member "message" |> member "content" |> to_list
    |> List.filter_map (fun block ->
        match member "type" block |> to_string_option with
        | Some "text" -> Some (member "text" block |> to_string)
        | _ -> None)
    |> List.head_opt
    |> Option.get_exn_or "text block"
  in
  Alcotest.(check string) "user text matches" "user input text" text

(** 4. An assistant message line is present. *)
let test_session_file_contains_assistant_message env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path
      [ make_text_turn_script "assistant reply" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  Pera_agent.Agent_harness.send t "hi";
  let lines = read_jsonl_lines env session_path in
  let has_assistant =
    List.exists
      (fun line ->
        match member "type" line |> to_string_option with
        | Some "message" ->
            let role =
              line |> member "message" |> member "role" |> to_string_option
            in
            Option.equal String.equal role (Some "assistant")
        | _ -> false)
      lines
  in
  Alcotest.(check bool) "assistant message present" true has_assistant

(** 5. Exactly one leaf per send; last line has type:'leaf'. *)
let test_session_file_ends_with_leaf env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path [ make_text_turn_script "done" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  Pera_agent.Agent_harness.send t "go";
  let lines = read_jsonl_lines env session_path in
  let leaf_count =
    List.count
      (fun line ->
        match member "type" line |> to_string_option with
        | Some "leaf" -> true
        | _ -> false)
      lines
  in
  Alcotest.(check int) "exactly one leaf" 1 leaf_count;
  let last = List.last_opt lines |> Option.get_exn_or "last line" in
  Alcotest.(check string) "last line is leaf" "leaf" (get_str last "type")

(** 6. One send: session_info ← user ← assistant ← leaf, linear parent chain. *)
let test_single_send_chain_is_linear env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path [ make_text_turn_script "ok" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  Pera_agent.Agent_harness.send t "test";
  let lines = read_jsonl_lines env session_path in
  (* Collect entries that have both id and parent_id (all except session_info) *)
  let advancing =
    List.filter
      (fun line ->
        match member "type" line |> to_string_option with
        | Some "session_info" | Some "leaf" -> false
        | _ -> true)
      lines
  in
  (* Verify the chain: each advancing entry's parent_id must equal the previous id *)
  let rec check_chain prev = function
    | [] -> true
    | entry :: rest ->
        let id = member "id" entry |> to_string_option in
        let actual_parent = member "parent_id" entry |> to_string_option in
        let parent_ok =
          match (prev, actual_parent) with
          | Some ep, Some ap -> String.equal ep ap
          | Some _, None -> false
          | None, _ -> true
        in
        parent_ok && check_chain id rest
  in
  let session_info_id =
    List.find_opt
      (fun line ->
        match member "type" line |> to_string_option with
        | Some "session_info" -> true
        | _ -> false)
      lines
    |> Option.flat_map (fun l -> member "id" l |> to_string_option)
  in
  let chain_ok = check_chain session_info_id advancing in
  Alcotest.(check bool) "linear parent chain" true chain_ok;
  (* Verify the leaf's parent_id points to the last advancing entry *)
  let leaf =
    List.find_opt
      (fun line ->
        match member "type" line |> to_string_option with
        | Some "leaf" -> true
        | _ -> false)
      lines
  in
  let last_advancing_id =
    List.last_opt advancing
    |> Option.flat_map (fun l -> member "id" l |> to_string_option)
  in
  let leaf_parent =
    Option.flat_map (fun l -> member "parent_id" l |> to_string_option) leaf
  in
  Alcotest.(check (option string))
    "leaf parent is last advancing entry" last_advancing_id leaf_parent

(** 7. Two sends: send-2 user parent_id = send-1 last content id (not leaf id).
    No entry references a leaf id as parent. *)
let test_leaf_is_childless_across_sends env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path
      [ make_text_turn_script "first"; make_text_turn_script "second" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  Pera_agent.Agent_harness.send t "send1";
  Pera_agent.Agent_harness.send t "send2";
  let lines = read_jsonl_lines env session_path in
  let leaf_ids =
    List.filter_map
      (fun line ->
        match member "type" line |> to_string_option with
        | Some "leaf" -> member "id" line |> to_string_option
        | _ -> None)
      lines
  in
  let leaf_is_parent =
    List.exists
      (fun line ->
        match member "parent_id" line |> to_string_option with
        | Some pid -> List.mem ~eq:String.equal pid leaf_ids
        | None -> false)
      lines
  in
  Alcotest.(check bool) "no entry has leaf as parent" false leaf_is_parent

(** 8. Two sends: the content-entry chain (excluding leaves) is gap-free. *)
let test_second_send_continues_content_chain env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path
      [ make_text_turn_script "a"; make_text_turn_script "b" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  Pera_agent.Agent_harness.send t "first";
  Pera_agent.Agent_harness.send t "second";
  let lines = read_jsonl_lines env session_path in
  (* Collect advancing (non-leaf) entries in order *)
  let advancing =
    List.filter
      (fun line ->
        match member "type" line |> to_string_option with
        | Some "leaf" -> false
        | _ -> true)
      lines
  in
  (* Build id -> line map *)
  let id_map =
    List.filter_map
      (fun line ->
        match member "id" line |> to_string_option with
        | Some id -> Some (id, line)
        | None -> None)
      advancing
  in
  (* Walk the chain from first entry; count reachable entries *)
  let first_id =
    List.head_opt advancing
    |> Option.flat_map (fun l -> member "id" l |> to_string_option)
  in
  let rec walk id acc =
    match id with
    | None -> acc
    | Some i -> (
        match List.assoc_opt ~eq:String.equal i id_map with
        | None -> acc
        | Some _entry ->
            (* Find next entry in advancing that has parent_id = i *)
            let next =
              List.find_opt
                (fun line ->
                  match member "parent_id" line |> to_string_option with
                  | Some pid -> String.equal pid i
                  | None -> false)
                advancing
            in
            walk
              (Option.flat_map
                 (fun l -> member "id" l |> to_string_option)
                 next)
              (acc + 1))
  in
  let reachable = walk first_id 0 in
  Alcotest.(check int)
    "all advancing entries reachable" (List.length advancing) reachable

(** 9. Subscriber receives at least AE_agent_start, AE_turn_start, AE_agent_end.
*)
let test_subscriber_receives_events env () =
  Faux_provider.reset_recorded ();
  Eio.Switch.run @@ fun sw ->
  let dir = make_temp_dir env in
  let session_path = Filename.concat dir "session.jsonl" in
  let config =
    make_config ~env ~cwd:dir ~session_path
      [ make_text_turn_script "event test" ]
  in
  let t = Result.get_exn (Pera_agent.Agent_harness.create ~config ~env ~sw) in
  let received = ref [] in
  let _unsub =
    Pera_agent.Agent_harness.subscribe t (fun event ->
        received := !received @ [ event ])
  in
  Pera_agent.Agent_harness.send t "go";
  let has_agent_start =
    List.exists
      (function Pera_core.Agent_types.AE_agent_start -> true | _ -> false)
      !received
  in
  let has_turn_start =
    List.exists
      (function Pera_core.Agent_types.AE_turn_start -> true | _ -> false)
      !received
  in
  let has_agent_end =
    List.exists
      (function Pera_core.Agent_types.AE_agent_end _ -> true | _ -> false)
      !received
  in
  Alcotest.(check bool) "received AE_agent_start" true has_agent_start;
  Alcotest.(check bool) "received AE_turn_start" true has_turn_start;
  Alcotest.(check bool) "received AE_agent_end" true has_agent_end

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  Eio_main.run (fun env ->
      Alcotest.run "agent_harness"
        [
          ( "file",
            [
              Alcotest.test_case "send creates session file" `Quick
                (test_send_creates_session_file env);
              Alcotest.test_case
                "session file contains session_info on first send" `Quick
                (test_session_file_contains_session_info_on_first_send env);
              Alcotest.test_case "session file contains user message" `Quick
                (test_session_file_contains_user_message env);
              Alcotest.test_case "session file contains assistant message"
                `Quick
                (test_session_file_contains_assistant_message env);
              Alcotest.test_case "session file ends with leaf" `Quick
                (test_session_file_ends_with_leaf env);
            ] );
          ( "chain",
            [
              Alcotest.test_case "single send chain is linear" `Quick
                (test_single_send_chain_is_linear env);
              Alcotest.test_case "leaf is childless across sends" `Quick
                (test_leaf_is_childless_across_sends env);
              Alcotest.test_case "second send continues content chain" `Quick
                (test_second_send_continues_content_chain env);
            ] );
          ( "subscribe",
            [
              Alcotest.test_case "subscriber receives events" `Quick
                (test_subscriber_receives_events env);
            ] );
        ])
