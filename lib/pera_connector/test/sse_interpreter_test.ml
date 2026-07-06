open Containers
open Pera_types

(** Feed a list of [framed_event] values through the interpreter, collecting all
    emitted [assistant_message_event] values in order. *)
let run_interpreter events =
  let state = ref Pera_connector.Anthropic_interpreter.initial_state in
  let all_events = ref [] in
  List.iter
    (fun framed ->
      let new_state, emitted =
        Pera_connector.Anthropic_interpreter.feed !state framed
      in
      state := new_state;
      all_events := !all_events @ emitted)
    events;
  !all_events

(** Construct a [framed_event] from an event type name and a JSON value. *)
let make_framed event_type json =
  {
    Pera_connector.Sse_parser.event_type;
    data = Yojson.Safe.to_string json;
    id = None;
  }

(** Construct an unknown framed event with arbitrary string data. *)
let make_framed_raw event_type data =
  { Pera_connector.Sse_parser.event_type; data; id = None }

(* ── Alcotest testable for assistant_message_event ── *)

let pp_stop_reason fmt = function
  | Types.EndTurn -> Format.pp_print_string fmt "EndTurn"
  | Types.ToolUse -> Format.pp_print_string fmt "ToolUse"
  | Types.MaxTokens -> Format.pp_print_string fmt "MaxTokens"
  | Types.StopSequence -> Format.pp_print_string fmt "StopSequence"
  | Types.Error _ -> Format.pp_print_string fmt "Error"
  | Types.Aborted -> Format.pp_print_string fmt "Aborted"

let pp_assistant_content fmt = function
  | Types.AText s -> Format.fprintf fmt "AText(%S)" s
  | Types.AThinking { text; _ } -> Format.fprintf fmt "AThinking(%S)" text
  | Types.AToolCall { id; name; arguments } ->
      Format.fprintf fmt "AToolCall(id=%s,name=%s,args=%s)" id name
        (Yojson.Safe.to_string arguments)

let pp_assistant_message fmt (m : Types.assistant_message) =
  Format.fprintf fmt "{content=[%a]; stop_reason=%a}"
    (Format.pp_print_list pp_assistant_content)
    m.content pp_stop_reason m.stop_reason

let pp_ame fmt = function
  | Types.AME_text_start { partial } ->
      Format.fprintf fmt "AME_text_start(partial=%a)" pp_assistant_message
        partial
  | Types.AME_text_delta { text; partial } ->
      Format.fprintf fmt "AME_text_delta(text=%S,partial=%a)" text
        pp_assistant_message partial
  | Types.AME_thinking_start { partial } ->
      Format.fprintf fmt "AME_thinking_start(partial=%a)" pp_assistant_message
        partial
  | Types.AME_thinking_delta { text; partial } ->
      Format.fprintf fmt "AME_thinking_delta(text=%S,partial=%a)" text
        pp_assistant_message partial
  | Types.AME_tool_call_start { index; id; name; partial } ->
      Format.fprintf fmt
        "AME_tool_call_start(index=%d,id=%s,name=%s,partial=%a)" index id name
        pp_assistant_message partial
  | Types.AME_tool_call_delta { index; arguments_fragment; partial } ->
      Format.fprintf fmt "AME_tool_call_delta(index=%d,fragment=%S,partial=%a)"
        index arguments_fragment pp_assistant_message partial
  | Types.AME_tool_call_end { index; partial } ->
      Format.fprintf fmt "AME_tool_call_end(index=%d,partial=%a)" index
        pp_assistant_message partial
  | Types.AME_done { message } ->
      Format.fprintf fmt "AME_done(message=%a)" pp_assistant_message message
  | Types.AME_error { message; partial } ->
      Format.fprintf fmt "AME_error(message=%S,partial=%a)" message
        pp_assistant_message partial

let ame_tag = function
  | Types.AME_text_start _ -> "AME_text_start"
  | Types.AME_text_delta _ -> "AME_text_delta"
  | Types.AME_thinking_start _ -> "AME_thinking_start"
  | Types.AME_thinking_delta _ -> "AME_thinking_delta"
  | Types.AME_tool_call_start _ -> "AME_tool_call_start"
  | Types.AME_tool_call_delta _ -> "AME_tool_call_delta"
  | Types.AME_tool_call_end _ -> "AME_tool_call_end"
  | Types.AME_done _ -> "AME_done"
  | Types.AME_error _ -> "AME_error"

let equal_ame a b =
  (* Compare full event structure via pretty-printing, which includes all fields. *)
  String.equal (Format.asprintf "%a" pp_ame a) (Format.asprintf "%a" pp_ame b)

let ame_testable = Alcotest.testable pp_ame equal_ame

(* ── Standard Anthropic SSE event builders ── *)

let message_start_event ?(input_tokens = 12) ?(output_tokens = 0) () =
  make_framed "message_start"
    (`Assoc
       [
         ("type", `String "message_start");
         ( "message",
           `Assoc
             [
               ("id", `String "msg_test");
               ( "usage",
                 `Assoc
                   [
                     ("input_tokens", `Int input_tokens);
                     ("output_tokens", `Int output_tokens);
                     ("cache_read_input_tokens", `Int 0);
                     ("cache_creation_input_tokens", `Int 0);
                   ] );
             ] );
       ])

let content_block_start_text_event ?(index = 0) () =
  make_framed "content_block_start"
    (`Assoc
       [
         ("type", `String "content_block_start");
         ("index", `Int index);
         ( "content_block",
           `Assoc [ ("type", `String "text"); ("text", `String "") ] );
       ])

let content_block_start_tool_event ?(index = 0) ~id ~name () =
  make_framed "content_block_start"
    (`Assoc
       [
         ("type", `String "content_block_start");
         ("index", `Int index);
         ( "content_block",
           `Assoc
             [
               ("type", `String "tool_use");
               ("id", `String id);
               ("name", `String name);
               ("input", `Assoc []);
             ] );
       ])

let content_block_delta_text_event ?(index = 0) text =
  make_framed "content_block_delta"
    (`Assoc
       [
         ("type", `String "content_block_delta");
         ("index", `Int index);
         ( "delta",
           `Assoc [ ("type", `String "text_delta"); ("text", `String text) ] );
       ])

let content_block_delta_json_event ?(index = 0) partial_json =
  make_framed "content_block_delta"
    (`Assoc
       [
         ("type", `String "content_block_delta");
         ("index", `Int index);
         ( "delta",
           `Assoc
             [
               ("type", `String "input_json_delta");
               ("partial_json", `String partial_json);
             ] );
       ])

let content_block_stop_event ?(index = 0) () =
  make_framed "content_block_stop"
    (`Assoc [ ("type", `String "content_block_stop"); ("index", `Int index) ])

let content_block_start_thinking_event ?(index = 0) () =
  make_framed "content_block_start"
    (`Assoc
       [
         ("type", `String "content_block_start");
         ("index", `Int index);
         ( "content_block",
           `Assoc [ ("type", `String "thinking"); ("thinking", `String "") ] );
       ])

let content_block_delta_thinking_event ?(index = 0) text =
  make_framed "content_block_delta"
    (`Assoc
       [
         ("type", `String "content_block_delta");
         ("index", `Int index);
         ( "delta",
           `Assoc
             [ ("type", `String "thinking_delta"); ("thinking", `String text) ]
         );
       ])

(** An Anthropic [signature_delta] event carrying a fragment of the thinking
    block's cryptographic signature. *)
let content_block_delta_signature_event ?(index = 0) signature =
  make_framed "content_block_delta"
    (`Assoc
       [
         ("type", `String "content_block_delta");
         ("index", `Int index);
         ( "delta",
           `Assoc
             [
               ("type", `String "signature_delta");
               ("signature", `String signature);
             ] );
       ])

let message_delta_event ?(input_tokens = 12) ?(output_tokens = 5)
    ?(stop_reason = "end_turn") () =
  make_framed "message_delta"
    (`Assoc
       [
         ("type", `String "message_delta");
         ("delta", `Assoc [ ("stop_reason", `String stop_reason) ]);
         ( "usage",
           `Assoc
             [
               ("input_tokens", `Int input_tokens);
               ("output_tokens", `Int output_tokens);
               ("cache_read_input_tokens", `Int 0);
               ("cache_creation_input_tokens", `Int 0);
             ] );
       ])

let message_stop_event () =
  make_framed "message_stop" (`Assoc [ ("type", `String "message_stop") ])

(** Build a partial snapshot for constructing expected events in tests. *)
let make_partial ?(content = []) ?(stop_reason = Types.EndTurn)
    ?(input_tokens = 12) ?(output_tokens = 0) () =
  {
    Types.content;
    stop_reason;
    provenance =
      {
        Types.protocol = "anthropic";
        provider = "Anthropic";
        model = "";
        error_message = None;
      };
    usage =
      {
        Types.input_tokens;
        output_tokens;
        cache_read_tokens = 0;
        cache_write_tokens = 0;
        cost_usd = None;
      };
  }

(* ── Test 1: text stream produces correct event sequence ── *)

let test_text_stream_produces_correct_event_sequence () =
  (* Arrange: minimal text-only Anthropic SSE stream *)
  let framed_events =
    [
      message_start_event ();
      content_block_start_text_event ();
      content_block_delta_text_event "hello";
      content_block_stop_event ();
      message_delta_event ();
      message_stop_event ();
    ]
  in
  (* Act *)
  let events = run_interpreter framed_events in
  (* Assert: event sequence using ame_testable for full structural comparison *)
  let expected =
    [
      Types.AME_text_start
        { partial = make_partial ~content:[ Types.AText "" ] () };
      Types.AME_text_delta
        {
          text = "hello";
          partial = make_partial ~content:[ Types.AText "hello" ] ();
        };
      Types.AME_done
        {
          message =
            make_partial ~content:[ Types.AText "hello" ] ~output_tokens:5 ();
        };
    ]
  in
  Alcotest.(check (list ame_testable)) "event sequence" expected events

(* ── Test 2: tool call stream produces correct events ── *)

let test_tool_call_stream_produces_correct_events () =
  (* Arrange: a tool_use block with two json delta fragments *)
  let framed_events =
    [
      message_start_event ();
      content_block_start_tool_event ~id:"toolu_01" ~name:"my_tool" ();
      content_block_delta_json_event {|{"key"|};
      content_block_delta_json_event {|:"value"}|};
      content_block_stop_event ();
      message_delta_event ~stop_reason:"tool_use" ();
      message_stop_event ();
    ]
  in
  (* Act *)
  let events = run_interpreter framed_events in
  (* Assert: event tag sequence *)
  let event_tags = List.map ame_tag events in
  Alcotest.(check (list string))
    "event sequence"
    [
      "AME_tool_call_start";
      "AME_tool_call_delta";
      "AME_tool_call_delta";
      "AME_tool_call_end";
      "AME_done";
    ]
    event_tags;
  (* Assert: AME_done message contains a tool call with correct arguments *)
  let done_event =
    List.find_opt (function Types.AME_done _ -> true | _ -> false) events
    |> Option.get_exn_or "expected AME_done"
  in
  match done_event with
  | Types.AME_done { message } -> (
      Alcotest.(check int) "content list length" 1 (List.length message.content);
      match List.nth_opt message.content 0 with
      | Some (Types.AToolCall tc) ->
          Alcotest.(check string) "tool name" "my_tool" tc.name;
          Alcotest.(check string) "tool id" "toolu_01" tc.id;
          let args_str = Yojson.Safe.to_string tc.arguments in
          Alcotest.(check string) "arguments" {|{"key":"value"}|} args_str
      | _ -> Alcotest.fail "expected AToolCall in content")
  | _ -> Alcotest.fail "unreachable"

(* ── Test 3: malformed tool JSON is repaired ── *)

let test_malformed_tool_json_is_repaired () =
  (* Port of Pi 'repairs malformed SSE JSON and malformed streamed tool JSON'.
     The delta contains a raw \H escape and a literal tab character. *)
  let malformed_delta =
    (* Reproduces the exact string from the Pi test:
       {"path":"A\H","text":"col1<TAB>col2"}
       where \H is an invalid escape and <TAB> is a literal 0x09 byte. *)
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"A\\\\H\\\",\\\"text\\\":\\\"col1\\tcol2\\\"}\"}}"
  in
  let framed_events =
    [
      message_start_event ();
      content_block_start_tool_event ~id:"toolu_test" ~name:"edit" ();
      make_framed_raw "content_block_delta" malformed_delta;
      content_block_stop_event ();
      message_delta_event ~stop_reason:"tool_use" ();
      message_stop_event ();
    ]
  in
  let events = run_interpreter framed_events in
  (* No AME_error should be emitted — repair should succeed *)
  let has_error =
    List.exists (function Types.AME_error _ -> true | _ -> false) events
  in
  Alcotest.(check bool) "no AME_error" false has_error;
  (* The AME_done message should contain a tool call with repaired arguments *)
  let done_event =
    List.find_opt (function Types.AME_done _ -> true | _ -> false) events
    |> Option.get_exn_or "expected AME_done"
  in
  match done_event with
  | Types.AME_done { message } -> (
      match List.nth_opt message.content 0 with
      | Some (Types.AToolCall tc) -> (
          let path_val =
            match tc.arguments with
            | `Assoc fields ->
                List.assoc_opt ~eq:String.equal "path" fields
                |> Option.get_exn_or "expected 'path' in arguments"
            | _ -> Alcotest.fail "expected assoc arguments"
          in
          let text_val =
            match tc.arguments with
            | `Assoc fields ->
                List.assoc_opt ~eq:String.equal "text" fields
                |> Option.get_exn_or "expected 'text' in arguments"
            | _ -> Alcotest.fail "expected assoc arguments"
          in
          (match path_val with
          | `String s -> Alcotest.(check string) "path value" "A\\H" s
          | _ -> Alcotest.fail "expected string 'path'");
          match text_val with
          | `String s -> Alcotest.(check string) "text value" "col1\tcol2" s
          | _ -> Alcotest.fail "expected string 'text'")
      | _ -> Alcotest.fail "expected AToolCall in content")
  | _ -> Alcotest.fail "unreachable"

(* ── Test 4: unknown events after message_stop are ignored ── *)

let test_unknown_events_after_message_stop_are_ignored () =
  (* Arrange: minimal text stream followed by unknown event types *)
  let framed_events =
    [
      message_start_event ();
      content_block_start_text_event ();
      content_block_delta_text_event "Hello";
      content_block_stop_event ();
      message_delta_event ();
      message_stop_event ();
      make_framed_raw "done" "[DONE]";
      make_framed_raw "proxy.stats" "not json";
    ]
  in
  let events = run_interpreter framed_events in
  (* No AME_error should be emitted *)
  let has_error =
    List.exists (function Types.AME_error _ -> true | _ -> false) events
  in
  Alcotest.(check bool) "no AME_error from unknown events" false has_error;
  (* Last event should be AME_done *)
  let last_event =
    List.last_opt events |> Option.get_exn_or "expected at least one event"
  in
  Alcotest.(check string)
    "last event is AME_done" "AME_done" (ame_tag last_event);
  (* The final message content is correct *)
  match last_event with
  | Types.AME_done { message } -> (
      match List.nth_opt message.content 0 with
      | Some (Types.AText t) -> Alcotest.(check string) "message text" "Hello" t
      | _ -> Alcotest.fail "expected AText in content")
  | _ -> Alcotest.fail "unreachable"

(* ── Test 5: partial snapshot is immutable ── *)

let test_partial_snapshot_is_immutable () =
  (* Arrange: feed two text deltas and collect the AME_text_delta events *)
  let framed_events =
    [
      message_start_event ();
      content_block_start_text_event ();
      content_block_delta_text_event "foo";
      content_block_delta_text_event "bar";
      content_block_stop_event ();
      message_delta_event ();
      message_stop_event ();
    ]
  in
  let events = run_interpreter framed_events in
  let text_deltas =
    List.filter_map
      (function
        | Types.AME_text_delta { partial; text } -> Some (partial, text)
        | _ -> None)
      events
  in
  Alcotest.(check int) "two text deltas" 2 (List.length text_deltas);
  let first_partial, first_text = List.nth text_deltas 0 in
  let second_partial, second_text = List.nth text_deltas 1 in
  Alcotest.(check string) "first delta text" "foo" first_text;
  Alcotest.(check string) "second delta text" "bar" second_text;
  (* The first partial should have content reflecting only "foo",
     the second partial should have "foobar".
     They must be structurally distinct (immutability invariant). *)
  let first_content_str =
    List.map (function Types.AText s -> s | _ -> "") first_partial.content
    |> String.concat ""
  in
  let second_content_str =
    List.map (function Types.AText s -> s | _ -> "") second_partial.content
    |> String.concat ""
  in
  Alcotest.(check string) "first partial content" "foo" first_content_str;
  Alcotest.(check string) "second partial content" "foobar" second_content_str;
  (* Verify they are distinct values *)
  let are_different = not (String.equal first_content_str second_content_str) in
  Alcotest.(check bool) "partials are distinct" true are_different

(* ── Test: thinking stream captures signature_delta ── *)

(** Anthropic streams the thinking-block signature as a series of
    [signature_delta] events. The interpreter must accumulate them and expose
    the full signature on the [AThinking] block, so the request builder can
    replay it on later turns (Anthropic rejects a thinking block without its
    signature with HTTP 400). *)
let test_thinking_stream_captures_signature () =
  let framed_events =
    [
      message_start_event ();
      content_block_start_thinking_event ();
      content_block_delta_thinking_event "reasoning...";
      content_block_delta_signature_event "sig-fragment-1";
      content_block_delta_signature_event "sig-fragment-2";
      content_block_stop_event ();
      message_delta_event ();
      message_stop_event ();
    ]
  in
  let events = run_interpreter framed_events in
  let done_event =
    match
      List.find_opt (function Types.AME_done _ -> true | _ -> false) events
    with
    | Some (Types.AME_done { message }) -> message
    | _ -> Alcotest.fail "expected an AME_done event"
  in
  match done_event.content with
  | [ Types.AThinking { text; signature } ] ->
      Alcotest.(check string) "thinking text accumulated" "reasoning..." text;
      Alcotest.(check (option string))
        "signature accumulated from both fragments"
        (Some "sig-fragment-1sig-fragment-2") signature
  | _ -> Alcotest.fail "expected a single AThinking block in the final message"

(* ── Test runner ── *)

let () =
  Alcotest.run "Anthropic_interpreter"
    [
      ( "text_stream",
        [
          Alcotest.test_case "produces_correct_event_sequence" `Quick
            test_text_stream_produces_correct_event_sequence;
        ] );
      ( "tool_call_stream",
        [
          Alcotest.test_case "produces_correct_events" `Quick
            test_tool_call_stream_produces_correct_events;
        ] );
      ( "json_repair",
        [
          Alcotest.test_case "malformed_tool_json_is_repaired" `Quick
            test_malformed_tool_json_is_repaired;
        ] );
      ( "unknown_events",
        [
          Alcotest.test_case "after_message_stop_are_ignored" `Quick
            test_unknown_events_after_message_stop_are_ignored;
        ] );
      ( "immutability",
        [
          Alcotest.test_case "partial_snapshot_is_immutable" `Quick
            test_partial_snapshot_is_immutable;
        ] );
      ( "thinking_stream",
        [
          Alcotest.test_case "captures_signature_delta" `Quick
            test_thinking_stream_captures_signature;
        ] );
    ]
