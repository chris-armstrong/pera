open Containers
open Pera_types.Types

let test_assistant_message_event_carries_partial_snapshot () =
  (* Arrange *)
  let empty_usage =
    {
      input_tokens = 0;
      output_tokens = 0;
      cache_read_tokens = 0;
      cache_write_tokens = 0;
      cost_usd = None;
    }
  in
  let empty_provenance =
    {
      protocol = "anthropic";
      provider = "anthropic";
      model = "test";
      error_message = None;
    }
  in
  let partial =
    {
      content = [ AText "hello" ];
      stop_reason = EndTurn;
      provenance = empty_provenance;
      usage = empty_usage;
    }
  in
  let event = AME_text_delta { text = "hello"; partial } in
  (* Act + Assert *)
  match event with
  | AME_text_delta { text; partial = snap } -> (
      Alcotest.(check string) "text field" "hello" text;
      (match snap.stop_reason with
      | EndTurn -> ()
      | _ -> Alcotest.fail "expected stop_reason = EndTurn");
      match snap.content with
      | [ AText t ] -> Alcotest.(check string) "content text" "hello" t
      | _ -> Alcotest.fail "expected content = [AText 'hello']")
  | _ -> Alcotest.fail "expected AME_text_delta"

let test_tool_call_round_trips_arguments () =
  (* Arrange *)
  let args = `Assoc [ ("key", `String "value"); ("n", `Int 42) ] in
  let tc = { id = "tc_001"; name = "my_tool"; arguments = args } in
  (* Act + Assert *)
  match tc.arguments with
  | `Assoc pairs -> (
      let key_val =
        List.assoc_opt ~eq:String.equal "key" pairs
        |> Option.get_exn_or "expected 'key' in arguments"
      in
      (match key_val with
      | `String s -> Alcotest.(check string) "key value" "value" s
      | _ -> Alcotest.fail "expected string value for 'key'");
      let n_val =
        List.assoc_opt ~eq:String.equal "n" pairs
        |> Option.get_exn_or "expected 'n' in arguments"
      in
      match n_val with
      | `Int n -> Alcotest.(check int) "n value" 42 n
      | _ -> Alcotest.fail "expected int value for 'n'")
  | _ -> Alcotest.fail "expected Assoc"

let test_is_retryable_classifies_stop_errors () =
  Alcotest.(check bool) "Transport retryable" true (is_retryable Transport);
  Alcotest.(check bool)
    "HTTP 500 retryable" true
    (is_retryable (Http { status = 500 }));
  Alcotest.(check bool)
    "HTTP 429 retryable" true
    (is_retryable (Http { status = 429 }));
  Alcotest.(check bool)
    "HTTP 400 not retryable" false
    (is_retryable (Http { status = 400 }));
  Alcotest.(check bool)
    "HTTP 404 not retryable" false
    (is_retryable (Http { status = 404 }));
  Alcotest.(check bool)
    "Provider not retryable" false
    (is_retryable (Provider { message = "content_filter" }));
  Alcotest.(check bool)
    "Internal not retryable" false
    (is_retryable (Internal { message = "bug" }))

let () =
  Alcotest.run "pera_types"
    [
      ( "assistant_message_event",
        [
          Alcotest.test_case
            "AME_text_delta carries partial snapshot with stop_reason and text"
            `Quick test_assistant_message_event_carries_partial_snapshot;
        ] );
      ( "tool_call",
        [
          Alcotest.test_case "tool_call round-trips JSON object arguments"
            `Quick test_tool_call_round_trips_arguments;
        ] );
      ( "stop_error",
        [
          Alcotest.test_case
            "is_retryable classifies retryable and non-retryable errors" `Quick
            test_is_retryable_classifies_stop_errors;
        ] );
    ]
