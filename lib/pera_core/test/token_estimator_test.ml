open Containers [@@warning "-33"]
open Pera_core

let test_estimate_text_is_ceil_div_3 () =
  Alcotest.(check int) "abcd -> 2" 2 (Token_estimator.estimate_text "abcd");
  Alcotest.(check int) "empty -> 0" 0 (Token_estimator.estimate_text "")

let test_estimate_message_includes_overhead () =
  let msg =
    Pera_connector.Connector.UserMessage
      Pera_types.Types.{ role = "user"; content = [ UText "x" ] }
  in
  let estimate = Token_estimator.estimate_message msg in
  if estimate < 4 then
    Alcotest.failf "expected estimate >= 4 (per_message_overhead), got %d"
      estimate

let test_estimate_messages_monotonic () =
  let msg1 =
    Pera_connector.Connector.UserMessage
      Pera_types.Types.{ role = "user"; content = [ UText "hello" ] }
  in
  let msg2 =
    Pera_connector.Connector.UserMessage
      Pera_types.Types.{ role = "user"; content = [ UText "world" ] }
  in
  let single = Token_estimator.estimate_messages [ msg1 ] in
  let both = Token_estimator.estimate_messages [ msg1; msg2 ] in
  if both <= single then
    Alcotest.failf
      "expected estimate_messages to increase when appending a message: %d <= \
       %d"
      both single

let test_estimate_counts_tool_call_arguments () =
  let make_tool_call_msg arguments =
    Pera_connector.Connector.AssistantMessage
      Pera_types.Types.
        {
          content = [ AToolCall { id = "call_1"; name = "bash"; arguments } ];
          stop_reason = ToolUse;
          provenance =
            {
              protocol = "anthropic";
              provider = "Anthropic";
              model = "claude";
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
  let empty_args = `Assoc [] in
  let long_args = `Assoc [ ("command", `String (String.make 300 'x')) ] in
  let empty_estimate =
    Token_estimator.estimate_message (make_tool_call_msg empty_args)
  in
  let long_estimate =
    Token_estimator.estimate_message (make_tool_call_msg long_args)
  in
  if long_estimate <= empty_estimate then
    Alcotest.failf "expected long args estimate (%d) > empty args estimate (%d)"
      long_estimate empty_estimate

let () =
  Alcotest.run "token_estimator"
    [
      ( "estimate_text",
        [
          Alcotest.test_case "ceil_div_3" `Quick
            test_estimate_text_is_ceil_div_3;
        ] );
      ( "estimate_message",
        [
          Alcotest.test_case "includes_overhead" `Quick
            test_estimate_message_includes_overhead;
          Alcotest.test_case "counts_tool_call_arguments" `Quick
            test_estimate_counts_tool_call_arguments;
        ] );
      ( "estimate_messages",
        [
          Alcotest.test_case "monotonic" `Quick test_estimate_messages_monotonic;
        ] );
    ]
