open Containers [@@warning "-33"]

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

let make_tool ~description name =
  let schema = Pera_provider.Json_schema.string () in
  Pera_core.Agent_types.Tool.create ~name ~description ~schema
    ~parallel_safe:true ~execute:(fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
      Ok (Pera_core.Agent_types.Tool_text "ok"))

let stable_system = "You are a helpful assistant."

let test_stable_across_two_builds () =
  let tools = [ make_tool ~description:"Echo text back." "echo" ] in
  let a = Pera_harness.Cache_fingerprint.compute ~system:stable_system ~tools in
  let b = Pera_harness.Cache_fingerprint.compute ~system:stable_system ~tools in
  Alcotest.(check bool)
    "same tool set produces equal fingerprints" true
    (Pera_harness.Cache_fingerprint.equal a b)

let test_changes_when_description_changes () =
  let tools_a = [ make_tool ~description:"Echo text back." "echo" ] in
  let tools_b = [ make_tool ~description:"Echo text back!" "echo" ] in
  let a =
    Pera_harness.Cache_fingerprint.compute ~system:stable_system ~tools:tools_a
  in
  let b =
    Pera_harness.Cache_fingerprint.compute ~system:stable_system ~tools:tools_b
  in
  Alcotest.(check bool)
    "description change produces different fingerprint" false
    (Pera_harness.Cache_fingerprint.equal a b)

let test_warning_fires_when_fingerprint_changes_and_policy_conversation () =
  let previous =
    Pera_harness.Cache_fingerprint.compute ~system:"system A"
      ~tools:[ make_tool ~description:"Tool A" "tool" ]
  in
  let current =
    Pera_harness.Cache_fingerprint.compute ~system:"system B"
      ~tools:[ make_tool ~description:"Tool A" "tool" ]
  in
  let logs =
    collect_logs (fun () ->
        Pera_harness.Cache_fingerprint.check_and_warn ~previous ~current
          ~cache_policy:Pera_types.Types.Conversation)
  in
  Alcotest.(check int) "one warning" 1 (warning_count logs);
  match find_warning logs with
  | None -> Alcotest.fail "expected a warning"
  | Some (_, msg) ->
      Alcotest.(check bool)
        "mentions prefix invalidation" true
        (String.mem ~sub:"prefix changed since last turn" msg)

let test_no_warning_when_policy_none () =
  let previous =
    Pera_harness.Cache_fingerprint.compute ~system:"system A"
      ~tools:[ make_tool ~description:"Tool A" "tool" ]
  in
  let current =
    Pera_harness.Cache_fingerprint.compute ~system:"system B"
      ~tools:[ make_tool ~description:"Tool A" "tool" ]
  in
  let logs =
    collect_logs (fun () ->
        Pera_harness.Cache_fingerprint.check_and_warn ~previous ~current
          ~cache_policy:Pera_types.Types.No_cache)
  in
  Alcotest.(check int) "no warnings" 0 (warning_count logs)

let test_hint_tools_differ () =
  let previous =
    Pera_harness.Cache_fingerprint.compute ~system:stable_system
      ~tools:[ make_tool ~description:"Tool A" "tool" ]
  in
  let current =
    Pera_harness.Cache_fingerprint.compute ~system:stable_system
      ~tools:[ make_tool ~description:"Tool B" "tool" ]
  in
  let logs =
    collect_logs (fun () ->
        Pera_harness.Cache_fingerprint.check_and_warn ~previous ~current
          ~cache_policy:Pera_types.Types.SystemAndToolsOnly)
  in
  match find_warning logs with
  | None -> Alcotest.fail "expected a warning"
  | Some (_, msg) ->
      Alcotest.(check bool)
        "hint names tools" true
        (String.mem ~sub:"tools differ" msg)

let test_hint_system_differs () =
  let previous =
    Pera_harness.Cache_fingerprint.compute ~system:"system A"
      ~tools:[ make_tool ~description:"Tool A" "tool" ]
  in
  let current =
    Pera_harness.Cache_fingerprint.compute ~system:"system B"
      ~tools:[ make_tool ~description:"Tool A" "tool" ]
  in
  let logs =
    collect_logs (fun () ->
        Pera_harness.Cache_fingerprint.check_and_warn ~previous ~current
          ~cache_policy:Pera_types.Types.SystemAndToolsOnly)
  in
  match find_warning logs with
  | None -> Alcotest.fail "expected a warning"
  | Some (_, msg) ->
      Alcotest.(check bool)
        "hint names system prompt" true
        (String.mem ~sub:"system prompt differs" msg)

let make_tool_with_schema ~description name schema =
  Pera_core.Agent_types.Tool.create ~name ~description ~schema
    ~parallel_safe:true ~execute:(fun ~ctx:_ ~args:_ ~sw:_ ~cancel:_ ->
      Ok (Pera_core.Agent_types.Tool_text "ok"))

let test_stable_despite_schema_property_order () =
  let schema_a =
    Pera_provider.Json_schema.object_
      ~properties:
        [
          ("alpha", Pera_provider.Json_schema.string ());
          ("beta", Pera_provider.Json_schema.string ());
        ]
      ~required:[ "alpha"; "beta" ] ()
  in
  let schema_b =
    Pera_provider.Json_schema.object_
      ~properties:
        [
          ("beta", Pera_provider.Json_schema.string ());
          ("alpha", Pera_provider.Json_schema.string ());
        ]
      ~required:[ "beta"; "alpha" ] ()
  in
  let tools_a = [ make_tool_with_schema ~description:"Tool" "tool" schema_a ] in
  let tools_b = [ make_tool_with_schema ~description:"Tool" "tool" schema_b ] in
  let a =
    Pera_harness.Cache_fingerprint.compute ~system:stable_system ~tools:tools_a
  in
  let b =
    Pera_harness.Cache_fingerprint.compute ~system:stable_system ~tools:tools_b
  in
  Alcotest.(check bool)
    "property declaration order does not affect fingerprint" true
    (Pera_harness.Cache_fingerprint.equal a b)

let test_tool_order_changes_fingerprint () =
  let tool_a = make_tool ~description:"Tool A" "tool_a" in
  let tool_b = make_tool ~description:"Tool B" "tool_b" in
  let first =
    Pera_harness.Cache_fingerprint.compute ~system:stable_system
      ~tools:[ tool_a; tool_b ]
  in
  let second =
    Pera_harness.Cache_fingerprint.compute ~system:stable_system
      ~tools:[ tool_b; tool_a ]
  in
  Alcotest.(check bool)
    "re-ordering tools changes fingerprint" false
    (Pera_harness.Cache_fingerprint.equal first second)

let () =
  Alcotest.run "cache_fingerprint"
    [
      ( "stability",
        [
          Alcotest.test_case "same tool set yields equal fingerprints" `Quick
            test_stable_across_two_builds;
          Alcotest.test_case "description change yields different fingerprint"
            `Quick test_changes_when_description_changes;
          Alcotest.test_case "property order does not affect fingerprint" `Quick
            test_stable_despite_schema_property_order;
          Alcotest.test_case "tool order changes fingerprint" `Quick
            test_tool_order_changes_fingerprint;
        ] );
      ( "warnings",
        [
          Alcotest.test_case
            "warning fires when fingerprint changes and policy is Conversation"
            `Quick
            test_warning_fires_when_fingerprint_changes_and_policy_conversation;
          Alcotest.test_case "no warning when policy is No_cache" `Quick
            test_no_warning_when_policy_none;
          Alcotest.test_case "hint names tools differ" `Quick
            test_hint_tools_differ;
          Alcotest.test_case "hint names system prompt differs" `Quick
            test_hint_system_differs;
        ] );
    ]
