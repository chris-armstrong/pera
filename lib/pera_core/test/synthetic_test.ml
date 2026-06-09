open Containers [@@warning "-33"]
open Pera_core

(** Pure Alcotest tests for Agent_types synthetic messages and compaction events.
    No Eio — these are all pure computations. *)

(** {1 Helper values} *)

let make_user_provider_message text =
  Pera_provider.Provider.UserMessage
    Pera_types.Types.{ role = "user"; content = [ UText text ] }

let make_real_message text =
  Agent_types.Real (make_user_provider_message text)

(** {1 Test: synthetic_to_message uses compaction_framing} *)

let test_synthetic_to_message_uses_framing () =
  let s = Agent_types.Compaction_summary { summary = "S" } in
  let msg = Agent_types.synthetic_to_message s in
  match msg with
  | Pera_provider.Provider.UserMessage um ->
      (match um.Pera_types.Types.content with
       | [ Pera_types.Types.UText text ] ->
           let expected = Agent_types.compaction_framing ^ "S" in
           Alcotest.(check string) "text equals framing ^ summary" expected text
       | _ -> Alcotest.fail "expected single UText block")
  | _ -> Alcotest.fail "expected UserMessage"

(** {1 Test: to_provider_message Real passthrough} *)

let test_to_provider_message_real_passthrough () =
  let pm = make_user_provider_message "hello" in
  let am = Agent_types.Real pm in
  let result = Agent_types.to_provider_message am in
  Alcotest.(check bool) "Real passthrough is equal"
    true (Pera_provider.Provider.equal_message pm result)

(** {1 Test: to_provider_message Synthetic renders via synthetic_to_message} *)

let test_to_provider_message_synthetic_renders () =
  let s = Agent_types.Compaction_summary { summary = "compact" } in
  let am = Agent_types.Synthetic s in
  let result = Agent_types.to_provider_message am in
  let expected = Agent_types.synthetic_to_message s in
  Alcotest.(check bool) "Synthetic renders same as synthetic_to_message"
    true (Pera_provider.Provider.equal_message expected result)

(** {1 Test: agent_message_equal for Synthetic messages} *)

let test_agent_message_equal_synthetic () =
  let s1 = Agent_types.Compaction_summary { summary = "abc" } in
  let s2 = Agent_types.Compaction_summary { summary = "abc" } in
  let s3 = Agent_types.Compaction_summary { summary = "xyz" } in
  Alcotest.(check bool) "equal Compaction_summary values are equal"
    true (Agent_types.agent_message_equal (Agent_types.Synthetic s1) (Agent_types.Synthetic s2));
  Alcotest.(check bool) "different Compaction_summary values are not equal"
    false (Agent_types.agent_message_equal (Agent_types.Synthetic s1) (Agent_types.Synthetic s3))

(** {1 Test: agent_message_equal Real vs Synthetic is false} *)

let test_agent_message_equal_mixed_is_false () =
  let real = make_real_message "hello" in
  let synth = Agent_types.Synthetic (Agent_types.Compaction_summary { summary = "hello" }) in
  Alcotest.(check bool) "Real vs Synthetic is false"
    false (Agent_types.agent_message_equal real synth);
  Alcotest.(check bool) "Synthetic vs Real is false"
    false (Agent_types.agent_message_equal synth real)

(** {1 Test: equal_agent_event for compaction events} *)

let test_equal_agent_event_compaction () =
  let e1 = Agent_types.AE_compaction_end { summary = "a" } in
  let e2 = Agent_types.AE_compaction_end { summary = "a" } in
  let e3 = Agent_types.AE_compaction_end { summary = "b" } in
  let e_start = Agent_types.AE_compaction_start in
  Alcotest.(check bool) "AE_compaction_end{a} equals itself"
    true (Agent_types.equal_agent_event e1 e2);
  Alcotest.(check bool) "AE_compaction_end{a} differs from {b}"
    false (Agent_types.equal_agent_event e1 e3);
  Alcotest.(check bool) "AE_compaction_end differs from AE_compaction_start"
    false (Agent_types.equal_agent_event e1 e_start)

let test_equal_agent_event_compaction_error () =
  let e1 = Agent_types.AE_compaction_error { message = "oops" } in
  let e2 = Agent_types.AE_compaction_error { message = "oops" } in
  let e3 = Agent_types.AE_compaction_error { message = "other" } in
  Alcotest.(check bool) "AE_compaction_error equals itself"
    true (Agent_types.equal_agent_event e1 e2);
  Alcotest.(check bool) "AE_compaction_error differs on message"
    false (Agent_types.equal_agent_event e1 e3);
  Alcotest.(check bool) "AE_compaction_error differs from AE_compaction_start"
    false (Agent_types.equal_agent_event e1 Agent_types.AE_compaction_start)

(** {1 Runner} *)

let () =
  Alcotest.run "synthetic"
    [
      ( "synthetic_to_message",
        [
          Alcotest.test_case "uses compaction framing" `Quick
            test_synthetic_to_message_uses_framing;
        ] );
      ( "to_provider_message",
        [
          Alcotest.test_case "Real passthrough" `Quick
            test_to_provider_message_real_passthrough;
          Alcotest.test_case "Synthetic renders via synthetic_to_message" `Quick
            test_to_provider_message_synthetic_renders;
        ] );
      ( "agent_message_equal",
        [
          Alcotest.test_case "Synthetic equal/unequal pairs" `Quick
            test_agent_message_equal_synthetic;
          Alcotest.test_case "Real vs Synthetic is false" `Quick
            test_agent_message_equal_mixed_is_false;
        ] );
      ( "agent_event_equality",
        [
          Alcotest.test_case "compaction event equality" `Quick
            test_equal_agent_event_compaction;
          Alcotest.test_case "compaction_error equality" `Quick
            test_equal_agent_event_compaction_error;
        ] );
    ]
