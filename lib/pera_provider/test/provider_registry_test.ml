open Containers
open Pera_provider

(** {2 Test data} *)

(* A turn_script with known events we can verify against. *)
let make_script text =
  let final_message =
    Pera_types.Types.
      {
        content = [ AText text ];
        stop_reason = EndTurn;
        provenance =
          {
            api = "faux";
            provider = "Faux";
            model = "test";
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
  let events =
    [
      Pera_types.Types.AME_text_start { partial = final_message };
      Pera_types.Types.AME_text_delta { text; partial = final_message };
      Pera_types.Types.AME_done { message = final_message };
    ]
  in
  Pera_core_test_util.Faux_provider.Turn { events; final = final_message }

(** {2 Stream consumer helper} *)

(* Consume all events from a stream and return the result. *)
let rec collect_events stream acc =
  match Pera_provider.Event_stream.take stream with
  | `Event e -> collect_events stream (e :: acc)
  | `Done _ -> (List.rev acc, Ok ())
  | `Error msg -> (List.rev acc, Error msg)

(** {2 Provider stream helpers} *)

(* Assert stream completed successfully and return events, or fail the test. *)
let check_stream_result (events, result) =
  match result with
  | Ok () -> events
  | Error msg -> Alcotest.failf "Expected stream to succeed, got error: %s" msg

(* Run a provider module, collect all events, and return them. Fails the test
   on stream error. Named helper to keep nesting within 2 levels. *)
let run_provider_and_get_events provider_mod =
  let module P = (val provider_mod : Provider.S) in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let inst = P.create ~env ~sw in
  let context =
    Provider.{ system = ""; messages = []; tools = []; thinking = false }
  in
  let options = { Provider.max_tokens = 100; temperature = None } in
  let stream =
    P.stream_simple inst
      ~model:{ Pera_types.Types.id = "test"; api = "faux" }
      ~context ~options ~sw
  in
  let events, result = collect_events stream [] in
  check_stream_result (events, result)

(* Extract the text from an AME_text_delta event, if applicable. *)
let text_delta_contents = function
  | Pera_types.Types.AME_text_delta { text; _ } -> Some text
  | _ -> None

(** {2 Test cases} *)

let test_lookup_returns_none_for_empty_registry () =
  let registry = Provider_registry.empty in
  match Provider_registry.lookup registry ~api:"anthropic" with
  | None -> ()
  | Some _ -> Alcotest.fail "Expected lookup on empty registry to return None"

let test_register_then_lookup_returns_registered_provider () =
  let scripts = [ make_script "hello" ] in
  let provider_mod = Pera_core_test_util.Faux_provider.as_provider scripts in
  let registry =
    Provider_registry.register Provider_registry.empty ~name:"faux" provider_mod
  in
  match Provider_registry.lookup registry ~api:"faux" with
  | None -> Alcotest.fail "Expected to find registered provider"
  | Some found_mod ->
      let events = run_provider_and_get_events found_mod in
      (* Verify the stream produced text content, not just a stream close. *)
      let texts = List.filter_map text_delta_contents events in
      Alcotest.(check (list string))
        "text content matches script" [ "hello" ] texts

let test_lookup_unregistered_name_returns_none () =
  let scripts = [ make_script "hello" ] in
  let provider_mod = Pera_core_test_util.Faux_provider.as_provider scripts in
  let registry =
    Provider_registry.register Provider_registry.empty ~name:"faux" provider_mod
  in
  match Provider_registry.lookup registry ~api:"other" with
  | None -> ()
  | Some _ ->
      Alcotest.fail "Expected lookup for unregistered name to return None"

let test_register_is_pure_does_not_mutate () =
  let scripts = [ make_script "hello" ] in
  let provider_mod = Pera_core_test_util.Faux_provider.as_provider scripts in
  let original = Provider_registry.empty in
  let _new_registry =
    Provider_registry.register original ~name:"faux" provider_mod
  in
  (* original should be unchanged *)
  match Provider_registry.lookup original ~api:"faux" with
  | None -> ()
  | Some _ ->
      Alcotest.fail
        "Expected original registry to remain unchanged after register"

let test_double_register_keeps_first_wins () =
  let script1 = make_script "first" in
  let script2 = make_script "second" in
  let provider1 = Pera_core_test_util.Faux_provider.as_provider [ script1 ] in
  let provider2 = Pera_core_test_util.Faux_provider.as_provider [ script2 ] in
  let registry =
    Provider_registry.empty |> fun r ->
    Provider_registry.register r ~name:"faux" provider1 |> fun r ->
    Provider_registry.register r ~name:"faux" provider2
  in
  match Provider_registry.lookup registry ~api:"faux" with
  | None ->
      Alcotest.fail "Expected to find registered provider after double register"
  | Some found_mod ->
      let events = run_provider_and_get_events found_mod in
      let texts = List.filter_map text_delta_contents events in
      (* First-write-wins: the first registered provider (script1 with "first")
         must be retained, not the second ("second"). *)
      Alcotest.(check (list string)) "first provider wins" [ "first" ] texts

let test_to_list_exposes_full_registry_contents () =
  let provider1 =
    Pera_core_test_util.Faux_provider.as_provider [ make_script "one" ]
  in
  let provider2 =
    Pera_core_test_util.Faux_provider.as_provider [ make_script "two" ]
  in
  let registry =
    Provider_registry.empty |> fun r ->
    Provider_registry.register r ~name:"alpha" provider1 |> fun r ->
    Provider_registry.register r ~name:"beta" provider2
  in
  let entries = Provider_registry.to_list registry in
  Alcotest.(check int) "registry has 2 entries" 2 (List.length entries);
  let names = List.map fst entries in
  Alcotest.(check bool)
    "contains alpha" true
    (List.mem ~eq:String.equal "alpha" names);
  Alcotest.(check bool)
    "contains beta" true
    (List.mem ~eq:String.equal "beta" names)

let () =
  Alcotest.run "Provider_registry"
    [
      ( "lookup",
        [
          Alcotest.test_case "returns_none_for_empty_registry" `Quick
            test_lookup_returns_none_for_empty_registry;
          Alcotest.test_case "register_then_lookup_returns_registered_provider"
            `Quick test_register_then_lookup_returns_registered_provider;
          Alcotest.test_case "lookup_unregistered_name_returns_none" `Quick
            test_lookup_unregistered_name_returns_none;
        ] );
      ( "purity",
        [
          Alcotest.test_case "register_is_pure_does_not_mutate" `Quick
            test_register_is_pure_does_not_mutate;
        ] );
      ( "first_wins",
        [
          Alcotest.test_case "double_register_keeps_first_wins" `Quick
            test_double_register_keeps_first_wins;
        ] );
      ( "to_list",
        [
          Alcotest.test_case "exposes_full_registry_contents" `Quick
            test_to_list_exposes_full_registry_contents;
        ] );
    ]
