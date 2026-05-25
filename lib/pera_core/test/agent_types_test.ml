open Containers [@@warning "-33"]
open Pera_core.Agent_types

let yojson_testable = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

(** Test that Tool_text output converts to a tool_result_content with content =
    `String "ok" and the correct tool_call_id and is_error flag. *)
let test_tool_output_text_converts_to_tool_result_content () =
  let result =
    tool_output_to_result_content ~tool_call_id:"tc1" ~is_error:false
      (Tool_text "ok")
  in
  Alcotest.(check string)
    "tool_call_id" "tc1" result.Pera_types.Types.tool_call_id;
  Alcotest.(check bool) "is_error" false result.Pera_types.Types.is_error;
  Alcotest.(check yojson_testable)
    "content is `String ok" (`String "ok") result.Pera_types.Types.content

(** Test that Tool_json output preserves the JSON value in the result content.
*)
let test_tool_output_json_converts_preserving_value () =
  let json = `Assoc [ ("x", `Int 1) ] in
  let result =
    tool_output_to_result_content ~tool_call_id:"tc2" ~is_error:false
      (Tool_json json)
  in
  Alcotest.(check string)
    "tool_call_id" "tc2" result.Pera_types.Types.tool_call_id;
  Alcotest.(check bool) "is_error" false result.Pera_types.Types.is_error;
  Alcotest.(check yojson_testable)
    "content equals supplied json" json result.Pera_types.Types.content

(** Test that the Alcotest testable for agent_event correctly distinguishes
    different variants and identifies equal variants as equal. *)
let test_agent_event_testable_distinguishes_variants () =
  Alcotest.(check bool)
    "different variants are unequal" false
    (agent_event_equal AE_turn_start AE_agent_start);
  Alcotest.(check bool)
    "same variant is equal" true
    (agent_event_equal AE_turn_start AE_turn_start)

let () =
  Alcotest.run "agent_types"
    [
      ( "tool_output_to_result_content",
        [
          Alcotest.test_case
            "Tool_text converts to tool_result_content with string content"
            `Quick test_tool_output_text_converts_to_tool_result_content;
          Alcotest.test_case "Tool_json converts preserving the JSON value"
            `Quick test_tool_output_json_converts_preserving_value;
        ] );
      ( "agent_event_testable",
        [
          Alcotest.test_case
            "testable distinguishes different variants and identifies equal \
             variants"
            `Quick test_agent_event_testable_distinguishes_variants;
        ] );
    ]
