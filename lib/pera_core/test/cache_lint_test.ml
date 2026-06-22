open Containers

(** Capture all log messages emitted during [f]. The previous reporter and level
    are restored afterwards. *)
let collect_logs f =
  let logs = ref [] in
  let buf = Buffer.create 256 in
  let ppf = Format.formatter_of_buffer buf in
  let old_reporter = Logs.reporter () in
  let old_level = Logs.level () in
  let report _src level ~over k msgf =
    let k _ =
      let msg = Buffer.contents buf in
      Buffer.reset buf;
      logs := (level, msg) :: !logs;
      over ();
      k ()
    in
    msgf (fun ?header:_ ?tags:_ fmt ->
        Format.kfprintf k ppf ("@[" ^^ fmt ^^ "@]@."))
  in
  Logs.set_reporter { Logs.report };
  Logs.set_level (Some Logs.Debug);
  Fun.protect f ~finally:(fun () ->
      Logs.set_reporter old_reporter;
      Logs.set_level old_level);
  List.rev !logs

let warning_count logs =
  List.count
    (fun (level, _) -> match level with Logs.Warning -> true | _ -> false)
    logs

let find_warning logs =
  List.find_opt
    (fun (level, _) -> match level with Logs.Warning -> true | _ -> false)
    logs

let test_iso_timestamp_triggers_warning () =
  let logs =
    collect_logs (fun () ->
        Pera_core.Cache_lint.warn_if_dynamic ~field:"test field"
          "Today is 2026-06-21T12:34Z")
  in
  Alcotest.(check int) "one warning" 1 (warning_count logs);
  match find_warning logs with
  | None -> Alcotest.fail "expected a warning"
  | Some (_, msg) ->
      Alcotest.(check bool)
        "mentions ISO 8601 timestamp" true
        (String.mem ~sub:"ISO 8601 timestamp" msg)

let test_date_triggers_warning () =
  let logs =
    collect_logs (fun () ->
        Pera_core.Cache_lint.warn_if_dynamic ~field:"test field"
          "Built on 2026-06-21")
  in
  Alcotest.(check int) "one warning" 1 (warning_count logs);
  match find_warning logs with
  | None -> Alcotest.fail "expected a warning"
  | Some (_, msg) ->
      Alcotest.(check bool)
        "mentions RFC 3339 date" true
        (String.mem ~sub:"RFC 3339 date" msg)

let test_uuid_triggers_warning () =
  let uuid = "550e8400-e29b-41d4-a716-446655440000" in
  let logs =
    collect_logs (fun () ->
        Pera_core.Cache_lint.warn_if_dynamic ~field:"test field"
          ("Session " ^ uuid))
  in
  Alcotest.(check int) "one warning" 1 (warning_count logs);
  match find_warning logs with
  | None -> Alcotest.fail "expected a warning"
  | Some (_, msg) ->
      Alcotest.(check bool)
        "mentions UUID v4" true
        (String.mem ~sub:"UUID v4" msg)

let test_long_digit_run_triggers_warning () =
  let logs =
    collect_logs (fun () ->
        Pera_core.Cache_lint.warn_if_dynamic ~field:"test field"
          "Timestamp 1718960400")
  in
  Alcotest.(check int) "one warning" 1 (warning_count logs);
  match find_warning logs with
  | None -> Alcotest.fail "expected a warning"
  | Some (_, msg) ->
      Alcotest.(check bool)
        "mentions long digit run" true
        (String.mem ~sub:"long digit run" msg)

let test_quiet_suppresses_warning () =
  let logs =
    collect_logs (fun () ->
        Pera_core.Cache_lint.warn_if_dynamic ~quiet:true ~field:"test field"
          "Today is 2026-06-21T12:34Z")
  in
  Alcotest.(check int) "no warnings" 0 (warning_count logs)

let test_clean_input_produces_no_warning () =
  let logs =
    collect_logs (fun () ->
        Pera_core.Cache_lint.warn_if_dynamic ~field:"test field"
          "This is a static description")
  in
  Alcotest.(check int) "no warnings" 0 (warning_count logs)

let make_dummy_tool description =
  let schema = Pera_provider.Json_schema.string () in
  Pera_core.Agent_types.Tool.create ~name:"dummy" ~description ~schema
    ~parallel_safe:true ~execute:(fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
      Ok (Pera_core.Agent_types.Tool_text "ok"))

let test_tool_create_with_clean_description () =
  let logs =
    collect_logs (fun () ->
        let _tool = make_dummy_tool "A static tool description" in
        ())
  in
  Alcotest.(check int) "no warnings" 0 (warning_count logs)

let test_tool_create_with_timestamp_description () =
  let logs =
    collect_logs (fun () ->
        let _tool = make_dummy_tool "Updated at 2026-06-21T12:34" in
        ())
  in
  Alcotest.(check int) "one warning" 1 (warning_count logs);
  match find_warning logs with
  | None -> Alcotest.fail "expected a warning"
  | Some (_, msg) ->
      Alcotest.(check bool)
        "mentions ISO 8601 timestamp" true
        (String.mem ~sub:"ISO 8601 timestamp" msg)

let () =
  Alcotest.run "cache_lint"
    [
      ( "patterns",
        [
          Alcotest.test_case "ISO 8601 timestamp triggers warning" `Quick
            test_iso_timestamp_triggers_warning;
          Alcotest.test_case "RFC 3339 date triggers warning" `Quick
            test_date_triggers_warning;
          Alcotest.test_case "UUID v4 triggers warning" `Quick
            test_uuid_triggers_warning;
          Alcotest.test_case "long digit run triggers warning" `Quick
            test_long_digit_run_triggers_warning;
        ] );
      ( "quiet",
        [
          Alcotest.test_case "quiet suppresses warning" `Quick
            test_quiet_suppresses_warning;
        ] );
      ( "clean_input",
        [
          Alcotest.test_case "clean input produces no warning" `Quick
            test_clean_input_produces_no_warning;
        ] );
      ( "tool_create",
        [
          Alcotest.test_case
            "tool create with clean description produces no warning" `Quick
            test_tool_create_with_clean_description;
          Alcotest.test_case
            "tool create with timestamped description produces warning" `Quick
            test_tool_create_with_timestamp_description;
        ] );
    ]
