open Containers
open Pera_harness
open Yojson.Safe.Util

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let get_str json key = member key json |> to_string

let has_key json key =
  match json with
  | `Assoc fields -> Option.is_some (List.assoc_opt ~eq:String.equal key fields)
  | _ -> false

let fake_model =
  Pera_types.Types.
    { id = "test-model"; api = "anthropic"; context_window = 200_000 }

let fake_user_message =
  Pera_connector.Connector.UserMessage
    Pera_types.Types.{ role = "user"; content = [ UText "hello" ] }

(* Read all JSONL lines from a file and parse each as JSON *)
let read_jsonl_lines env path =
  let content = Eio.Path.load Eio.Path.(env#fs / path) in
  String.split_on_char '\n' content
  |> List.filter (fun s -> not (String.is_empty s))
  |> List.map Yojson.Safe.from_string

(* ── Tests ───────────────────────────────────────────────────────────────── *)

let test_write_session_info_creates_file_with_valid_jsonl env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  let () = Result.get_exn (Session_writer.write_session_info t) in
  let lines = read_jsonl_lines env path in
  Alcotest.(check int) "one line" 1 (List.length lines);
  let first = List.get_at_idx 0 lines |> Option.get_exn_or "first line" in
  Alcotest.(check string)
    "type is session_info" "session_info" (get_str first "type")

let test_write_message_appends_line_with_parent_id env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  Result.get_exn (Session_writer.write_session_info t);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  let lines = read_jsonl_lines env path in
  Alcotest.(check int) "two lines" 2 (List.length lines);
  let first = List.get_at_idx 0 lines |> Option.get_exn_or "first line" in
  let second = List.get_at_idx 1 lines |> Option.get_exn_or "second line" in
  let first_id = get_str first "id" in
  let second_parent_id = get_str second "parent_id" in
  Alcotest.(check string)
    "message parent_id = session_info id" first_id second_parent_id

let test_write_leaf_sets_parent_to_last_message env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  Result.get_exn (Session_writer.write_session_info t);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  Result.get_exn (Session_writer.write_leaf t);
  let lines = read_jsonl_lines env path in
  let msg_line = List.get_at_idx 1 lines |> Option.get_exn_or "message line" in
  let leaf_line = List.get_at_idx 2 lines |> Option.get_exn_or "leaf line" in
  let msg_id = get_str msg_line "id" in
  let leaf_parent_id = get_str leaf_line "parent_id" in
  Alcotest.(check string) "leaf parent_id = message id" msg_id leaf_parent_id

let test_leaf_is_childless_and_does_not_advance_tip env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  Result.get_exn (Session_writer.write_session_info t);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  Result.get_exn (Session_writer.write_leaf t);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  let lines = read_jsonl_lines env path in
  Alcotest.(check int) "four lines" 4 (List.length lines);
  let m1 = List.get_at_idx 1 lines |> Option.get_exn_or "m1" in
  let leaf = List.get_at_idx 2 lines |> Option.get_exn_or "leaf" in
  let m2 = List.get_at_idx 3 lines |> Option.get_exn_or "m2" in
  let m1_id = get_str m1 "id" in
  let leaf_id = get_str leaf "id" in
  let m2_parent_id = get_str m2 "parent_id" in
  (* m2's parent must be m1, not the leaf *)
  Alcotest.(check string) "m2 parent_id = m1 id (not leaf)" m1_id m2_parent_id;
  (* No entry has the leaf id as parent_id *)
  let leaf_is_parent =
    List.exists
      (fun line ->
        has_key line "parent_id"
        && String.equal (get_str line "parent_id") leaf_id)
      lines
  in
  Alcotest.(check bool) "no entry has leaf as parent" false leaf_is_parent

let test_parent_chain_forms_linked_list env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  Result.get_exn (Session_writer.write_message t fake_user_message);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  let lines = read_jsonl_lines env path in
  Alcotest.(check int) "three lines" 3 (List.length lines);
  let e0 = List.get_at_idx 0 lines |> Option.get_exn_or "e0" in
  let e1 = List.get_at_idx 1 lines |> Option.get_exn_or "e1" in
  let e2 = List.get_at_idx 2 lines |> Option.get_exn_or "e2" in
  let id0 = get_str e0 "id" in
  let id1 = get_str e1 "id" in
  Alcotest.(check string) "e1 parent = e0" id0 (get_str e1 "parent_id");
  Alcotest.(check string) "e2 parent = e1" id1 (get_str e2 "parent_id")

let test_create_makes_parent_directories env () =
  let base_dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat base_dir "a/b/c/session.jsonl" in
  let result =
    Session_writer.create ~path ~env ~model:fake_model ~cwd:base_dir
  in
  Alcotest.(check bool) "create succeeds" true (Result.is_ok result);
  let dir_path = Filename.concat base_dir "a/b/c" in
  let exists =
    match Eio.Path.kind ~follow:true Eio.Path.(env#fs / dir_path) with
    | `Directory -> true
    | _ -> false
    | exception _ -> false
  in
  Alcotest.(check bool) "a/b/c directory exists" true exists

let test_session_id_is_uuid env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  let sid = Session_writer.session_id t in
  (* A standard UUID is 36 characters: 8-4-4-4-12 hex groups with dashes *)
  Alcotest.(check int) "session_id length is 36" 36 (String.length sid);
  let is_uuid_char c =
    Char.((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c = '-')
  in
  let all_uuid_chars = String.for_all is_uuid_char sid in
  Alcotest.(check bool)
    "session_id contains only hex and dashes" true all_uuid_chars;
  (* Check the dash positions: positions 8, 13, 18, 23 *)
  let sid_bytes = Bytes.of_string sid in
  let dash_at n =
    n < Bytes.length sid_bytes && Char.equal (Bytes.get sid_bytes n) '-'
  in
  let dashes_ok = dash_at 8 && dash_at 13 && dash_at 18 && dash_at 23 in
  Alcotest.(check bool) "dashes at correct positions" true dashes_ok

let test_multiple_appends_accumulate_lines env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  Result.get_exn (Session_writer.write_session_info t);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  Result.get_exn (Session_writer.write_leaf t);
  Result.get_exn
    (Session_writer.write_model_change t
       Pera_types.Types.
         { id = "new-model"; api = "anthropic"; context_window = 200_000 });
  let lines = read_jsonl_lines env path in
  Alcotest.(check int) "four lines" 4 (List.length lines);
  List.iteri
    (fun i line ->
      let valid = match line with `Assoc _ -> true | _ -> false in
      Alcotest.(check bool)
        (Printf.sprintf "line %d is valid JSON object" i)
        true valid)
    lines;
  let session_info_line =
    List.get_at_idx 0 lines |> Option.get_exn_or "session_info line"
  in
  Alcotest.(check int)
    "session_info model.context_window" 200_000
    (member "model" session_info_line |> member "context_window" |> to_int);
  let model_change_line =
    List.get_at_idx 3 lines |> Option.get_exn_or "model_change line"
  in
  Alcotest.(check string)
    "model_change type" "model_change"
    (get_str model_change_line "type");
  Alcotest.(check string)
    "model_change model.id" "new-model"
    (get_str (member "model" model_change_line) "id");
  Alcotest.(check int)
    "model_change model.context_window" 200_000
    (member "model" model_change_line |> member "context_window" |> to_int)

let test_write_compaction_emits_compaction_entry env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  Result.get_exn (Session_writer.write_session_info t);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  let fk = Pera_harness.Entry_id.generate () in
  Result.get_exn
    (Session_writer.write_compaction t ~summary:"S" ~first_kept_entry_id:fk);
  let lines = read_jsonl_lines env path in
  Alcotest.(check int) "three lines" 3 (List.length lines);
  let msg_line = List.get_at_idx 1 lines |> Option.get_exn_or "msg" in
  let comp_line = List.get_at_idx 2 lines |> Option.get_exn_or "compaction" in
  Alcotest.(check string)
    "type is compaction" "compaction" (get_str comp_line "type");
  Alcotest.(check string) "summary" "S" (get_str comp_line "summary");
  Alcotest.(check string)
    "first_kept_entry_id matches"
    (Pera_harness.Entry_id.to_string fk)
    (get_str comp_line "first_kept_entry_id");
  Alcotest.(check string)
    "parent_id = msg id" (get_str msg_line "id")
    (get_str comp_line "parent_id")

let test_write_compaction_advances_tip env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  Result.get_exn (Session_writer.write_session_info t);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  let fk = Pera_harness.Entry_id.generate () in
  Result.get_exn
    (Session_writer.write_compaction t ~summary:"S" ~first_kept_entry_id:fk);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  let lines = read_jsonl_lines env path in
  Alcotest.(check int) "four lines" 4 (List.length lines);
  let comp_line = List.get_at_idx 2 lines |> Option.get_exn_or "compaction" in
  let synth_line = List.get_at_idx 3 lines |> Option.get_exn_or "synth" in
  Alcotest.(check string)
    "synth parent = compaction id" (get_str comp_line "id")
    (get_str synth_line "parent_id")

let test_compaction_then_synthetic_then_leaf_chain env () =
  let dir = Harness_test_util.make_temp_dir env in
  let path = Filename.concat dir "session.jsonl" in
  let t =
    Result.get_exn (Session_writer.create ~path ~env ~model:fake_model ~cwd:dir)
  in
  Result.get_exn (Session_writer.write_session_info t);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  let second_user_message =
    Pera_connector.Connector.UserMessage
      Pera_types.Types.{ role = "user"; content = [ UText "ack" ] }
  in
  Result.get_exn (Session_writer.write_message t second_user_message);
  let fk = Pera_harness.Entry_id.generate () in
  Result.get_exn
    (Session_writer.write_compaction t ~summary:"S" ~first_kept_entry_id:fk);
  Result.get_exn (Session_writer.write_message t fake_user_message);
  Result.get_exn (Session_writer.write_leaf t);
  let lines = read_jsonl_lines env path in
  Alcotest.(check int) "six lines" 6 (List.length lines);
  let session_info = List.get_at_idx 0 lines |> Option.get_exn_or "si" in
  let m1 = List.get_at_idx 1 lines |> Option.get_exn_or "m1" in
  let m2 = List.get_at_idx 2 lines |> Option.get_exn_or "m2" in
  let comp = List.get_at_idx 3 lines |> Option.get_exn_or "comp" in
  let synth = List.get_at_idx 4 lines |> Option.get_exn_or "synth" in
  let leaf = List.get_at_idx 5 lines |> Option.get_exn_or "leaf" in
  Alcotest.(check string)
    "m1 parent = si"
    (get_str session_info "id")
    (get_str m1 "parent_id");
  Alcotest.(check string)
    "m2 parent = m1" (get_str m1 "id") (get_str m2 "parent_id");
  Alcotest.(check string)
    "comp parent = m2" (get_str m2 "id") (get_str comp "parent_id");
  Alcotest.(check string)
    "synth parent = comp" (get_str comp "id")
    (get_str synth "parent_id");
  Alcotest.(check string)
    "leaf parent = synth" (get_str synth "id") (get_str leaf "parent_id");
  let leaf_id = get_str leaf "id" in
  let leaf_is_parent =
    List.exists
      (fun line ->
        has_key line "parent_id"
        && String.equal (get_str line "parent_id") leaf_id)
      lines
  in
  Alcotest.(check bool) "leaf is childless" false leaf_is_parent

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  Eio_main.run (fun env ->
      Alcotest.run "session_writer"
        [
          ( "session_info",
            [
              Alcotest.test_case "creates file with valid jsonl" `Quick
                (test_write_session_info_creates_file_with_valid_jsonl env);
            ] );
          ( "message",
            [
              Alcotest.test_case "appends line with parent_id" `Quick
                (test_write_message_appends_line_with_parent_id env);
            ] );
          ( "leaf",
            [
              Alcotest.test_case "sets parent to last message" `Quick
                (test_write_leaf_sets_parent_to_last_message env);
              Alcotest.test_case "is childless and does not advance tip" `Quick
                (test_leaf_is_childless_and_does_not_advance_tip env);
            ] );
          ( "chain",
            [
              Alcotest.test_case "parent chain forms linked list" `Quick
                (test_parent_chain_forms_linked_list env);
            ] );
          ( "create",
            [
              Alcotest.test_case "makes parent directories" `Quick
                (test_create_makes_parent_directories env);
            ] );
          ( "session_id",
            [
              Alcotest.test_case "is a valid UUID" `Quick
                (test_session_id_is_uuid env);
            ] );
          ( "accumulate",
            [
              Alcotest.test_case "multiple appends accumulate lines" `Quick
                (test_multiple_appends_accumulate_lines env);
            ] );
          ( "compaction",
            [
              Alcotest.test_case "emits compaction entry" `Quick
                (test_write_compaction_emits_compaction_entry env);
              Alcotest.test_case "advances tip" `Quick
                (test_write_compaction_advances_tip env);
              Alcotest.test_case "compaction then synthetic then leaf chain"
                `Quick
                (test_compaction_then_synthetic_then_leaf_chain env);
            ] );
        ])
