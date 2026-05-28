open Containers
open Pera_types

(** Feed a list of [framed_event] values through the interpreter, collecting all
    emitted [assistant_message_event] values in order. *)
let feed_interpreter state framed =
  let new_state, emitted =
    Pera_provider.Openai_completions_interpreter.feed !state framed
  in
  state := new_state;
  emitted

let run_interpreter ~reasoning_field events =
  let state =
    ref
      (Pera_provider.Openai_completions_interpreter.initial_state
         ~reasoning_field)
  in
  let all_events = ref [] in
  let chunk_events = List.map (feed_interpreter state) events in
  all_events := List.flatten chunk_events;
  !all_events

(** Construct a [framed_event] from an event type name and a JSON value. *)
let make_framed event_type json =
  {
    Pera_provider.Sse_parser.event_type;
    data = Yojson.Safe.to_string json;
    id = None;
  }

(** Construct an unknown framed event with arbitrary string data. *)
let make_framed_raw event_type data =
  { Pera_provider.Sse_parser.event_type; data; id = None }

(* ── Event tag helper ── *)

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

(* ── Alcotest testable for assistant_message_event ── *)

let pp_stop_reason fmt = function
  | Types.EndTurn -> Format.pp_print_string fmt "EndTurn"
  | Types.ToolUse -> Format.pp_print_string fmt "ToolUse"
  | Types.MaxTokens -> Format.pp_print_string fmt "MaxTokens"
  | Types.StopSequence -> Format.pp_print_string fmt "StopSequence"
  | Types.Error -> Format.pp_print_string fmt "Error"
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

let equal_ame a b =
  (* Compare full event structure via pretty-printing, which includes all fields. *)
  String.equal (Format.asprintf "%a" pp_ame a) (Format.asprintf "%a" pp_ame b)

let ame_testable = Alcotest.testable pp_ame equal_ame

(* ── OpenAI chunk builders ── *)

let make_openai_chunk ?(delta = `Assoc []) ?finish_reason () =
  let finish_field =
    match finish_reason with
    | None -> []
    | Some "null" -> [ ("finish_reason", `Null) ]
    | Some r -> [ ("finish_reason", `String r) ]
  in
  let choice =
    `Assoc ([ ("index", `Int 0); ("delta", delta) ] @ finish_field)
  in
  make_framed ""
    (`Assoc [ ("id", `String "chatcmpl-test"); ("choices", `List [ choice ]) ])

let role_chunk () =
  make_openai_chunk ~delta:(`Assoc [ ("role", `String "assistant") ]) ()

let text_content_chunk text =
  make_openai_chunk ~delta:(`Assoc [ ("content", `String text) ]) ()

let null_content_chunk () =
  make_openai_chunk ~delta:(`Assoc [ ("content", `Null) ]) ()

let reasoning_chunk field text =
  make_openai_chunk ~delta:(`Assoc [ (field, `String text) ]) ()

let build_tool_call_item (index, id_opt, name_opt, args_opt) =
  let base = [ ("index", `Int index) ] in
  let with_id =
    match id_opt with Some id -> base @ [ ("id", `String id) ] | None -> base
  in
  let with_type = with_id @ [ ("type", `String "function") ] in
  let func_fields =
    (match name_opt with Some name -> [ ("name", `String name) ] | None -> [])
    @
    match args_opt with
    | Some args -> [ ("arguments", `String args) ]
    | None -> []
  in
  `Assoc (with_type @ [ ("function", `Assoc func_fields) ])

let tool_call_chunk items =
  let tool_call_items = List.map build_tool_call_item items in
  make_openai_chunk ~delta:(`Assoc [ ("tool_calls", `List tool_call_items) ]) ()

let finish_chunk reason =
  make_openai_chunk ~delta:(`Assoc []) ~finish_reason:reason ()

let null_finish_chunk () = finish_chunk "null"
let done_sentinel () = make_framed_raw "" "[DONE]"
let malformed_chunk () = make_framed_raw "" "not json {"

(** Build a partial snapshot for constructing expected events in tests. *)
let make_partial ?(content = []) ?(stop_reason = Types.EndTurn)
    ?(input_tokens = 0) ?(output_tokens = 0) () =
  {
    Types.content;
    stop_reason;
    provenance =
      {
        Types.api = "openai-completions";
        provider = "OpenAI";
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

(* ── Test 1: simple text stream ── *)

let test_simple_text_stream_produces_correct_events () =
  let framed_events =
    [
      role_chunk ();
      text_content_chunk "Hello";
      text_content_chunk " World";
      finish_chunk "stop";
    ]
  in
  let events =
    run_interpreter ~reasoning_field:"reasoning_content" framed_events
  in
  let expected =
    [
      Types.AME_text_start
        { partial = make_partial ~content:[ Types.AText "" ] () };
      Types.AME_text_delta
        {
          text = "Hello";
          partial = make_partial ~content:[ Types.AText "Hello" ] ();
        };
      Types.AME_text_delta
        {
          text = " World";
          partial = make_partial ~content:[ Types.AText "Hello World" ] ();
        };
      Types.AME_done
        { message = make_partial ~content:[ Types.AText "Hello World" ] () };
    ]
  in
  Alcotest.(check (list ame_testable)) "event sequence" expected events

(* ── Test 2: reasoning stream ── *)

let test_reasoning_stream_produces_correct_events () =
  let framed_events =
    [
      role_chunk ();
      reasoning_chunk "reasoning_content" "I need to think";
      text_content_chunk "Hello";
      finish_chunk "stop";
    ]
  in
  let events =
    run_interpreter ~reasoning_field:"reasoning_content" framed_events
  in
  let expected =
    [
      Types.AME_thinking_start
        {
          partial =
            make_partial
              ~content:[ Types.AThinking { text = ""; signature = None } ]
              ();
        };
      Types.AME_thinking_delta
        {
          text = "I need to think";
          partial =
            make_partial
              ~content:
                [
                  Types.AThinking { text = "I need to think"; signature = None };
                ]
              ();
        };
      Types.AME_text_start
        {
          partial =
            make_partial
              ~content:
                [
                  Types.AThinking { text = "I need to think"; signature = None };
                  Types.AText "";
                ]
              ();
        };
      Types.AME_text_delta
        {
          text = "Hello";
          partial =
            make_partial
              ~content:
                [
                  Types.AThinking { text = "I need to think"; signature = None };
                  Types.AText "Hello";
                ]
              ();
        };
      Types.AME_done
        {
          message =
            make_partial
              ~content:
                [
                  Types.AThinking { text = "I need to think"; signature = None };
                  Types.AText "Hello";
                ]
              ();
        };
    ]
  in
  Alcotest.(check (list ame_testable)) "event sequence" expected events

(* ── Test 3: reasoning field is configurable ── *)

let count_thinking_events events =
  List.count
    (function
      | Types.AME_thinking_start _ | Types.AME_thinking_delta _ -> true
      | _ -> false)
    events

let test_reasoning_field_is_configurable () =
  let zen_events =
    run_interpreter ~reasoning_field:"reasoning_content"
      [
        role_chunk ();
        reasoning_chunk "reasoning_content" "think";
        finish_chunk "stop";
      ]
  in
  let go_events =
    run_interpreter ~reasoning_field:"reasoning"
      [
        role_chunk (); reasoning_chunk "reasoning" "think"; finish_chunk "stop";
      ]
  in
  Alcotest.(check int) "zen fires thinking" 2 (count_thinking_events zen_events);
  Alcotest.(check int) "go fires thinking" 2 (count_thinking_events go_events);
  let zen_ignores_go_field =
    run_interpreter ~reasoning_field:"reasoning_content"
      [
        role_chunk (); reasoning_chunk "reasoning" "think"; finish_chunk "stop";
      ]
  in
  let go_ignores_zen_field =
    run_interpreter ~reasoning_field:"reasoning"
      [
        role_chunk ();
        reasoning_chunk "reasoning_content" "think";
        finish_chunk "stop";
      ]
  in
  Alcotest.(check int)
    "zen ignores reasoning field" 0
    (count_thinking_events zen_ignores_go_field);
  Alcotest.(check int)
    "go ignores reasoning_content field" 0
    (count_thinking_events go_ignores_zen_field)

(* ── Test 4: tool call stream ── *)

let test_tool_call_stream_produces_correct_events () =
  let framed_events =
    [
      role_chunk ();
      tool_call_chunk [ (0, Some "call_1", Some "echo", Some "{\"t") ];
      tool_call_chunk [ (0, None, None, Some "ext\":\"hi\"}") ];
      finish_chunk "tool_calls";
    ]
  in
  let events =
    run_interpreter ~reasoning_field:"reasoning_content" framed_events
  in
  let tags = List.map ame_tag events in
  Alcotest.(check (list string))
    "event tags"
    [
      "AME_tool_call_start";
      "AME_tool_call_delta";
      "AME_tool_call_delta";
      "AME_tool_call_end";
      "AME_done";
    ]
    tags;
  let done_event =
    List.find_opt (function Types.AME_done _ -> true | _ -> false) events
    |> Option.get_exn_or "expected AME_done"
  in
  match done_event with
  | Types.AME_done { message } -> (
      match List.nth_opt message.content 0 with
      | Some (Types.AToolCall tc) ->
          Alcotest.(check string) "tool name" "echo" tc.name;
          Alcotest.(check string) "tool id" "call_1" tc.id;
          let args_str = Yojson.Safe.to_string tc.arguments in
          Alcotest.(check string) "arguments" {|{"text":"hi"}|} args_str
      | _ -> Alcotest.fail "expected AToolCall in final message")
  | _ -> Alcotest.fail "unreachable"

(* ── Test 5: [DONE] sentinel ── *)

let test_done_sentinel_terminates_stream () =
  let events =
    run_interpreter ~reasoning_field:"reasoning_content"
      [ role_chunk (); text_content_chunk "done"; done_sentinel () ]
  in
  let tags = List.map ame_tag events in
  Alcotest.(check (list string))
    "event tags"
    [ "AME_text_start"; "AME_text_delta"; "AME_done" ]
    tags

(* ── Test 6: malformed JSON ── *)

let test_malformed_json_produces_error () =
  let events =
    run_interpreter ~reasoning_field:"reasoning_content" [ malformed_chunk () ]
  in
  match events with
  | [ Types.AME_error { message; _ } ] ->
      Alcotest.(check bool) "message non-empty" true (String.length message > 0)
  | _ -> Alcotest.fail "expected single AME_error"

(* ── Test 7: multiple tool calls ── *)

let test_multiple_tool_calls_in_one_response () =
  let framed_events =
    [
      role_chunk ();
      tool_call_chunk
        [
          (0, Some "c1", Some "echo", Some "{\"a");
          (1, Some "c2", Some "count", Some "{\"b");
        ];
      tool_call_chunk
        [ (0, None, None, Some "\":\"1\"}"); (1, None, None, Some "\":\"2\"}") ];
      finish_chunk "tool_calls";
    ]
  in
  let events =
    run_interpreter ~reasoning_field:"reasoning_content" framed_events
  in
  let tags = List.map ame_tag events in
  Alcotest.(check (list string))
    "event tags"
    [
      "AME_tool_call_start";
      "AME_tool_call_delta";
      "AME_tool_call_start";
      "AME_tool_call_delta";
      "AME_tool_call_delta";
      "AME_tool_call_delta";
      "AME_tool_call_end";
      "AME_tool_call_end";
      "AME_done";
    ]
    tags;
  let done_event =
    List.find_opt (function Types.AME_done _ -> true | _ -> false) events
    |> Option.get_exn_or "expected AME_done"
  in
  match done_event with
  | Types.AME_done { message } -> (
      Alcotest.(check int) "two tool calls" 2 (List.length message.content);
      (match List.nth_opt message.content 0 with
      | Some (Types.AToolCall tc) ->
          Alcotest.(check string) "first name" "echo" tc.name;
          Alcotest.(check string) "first id" "c1" tc.id
      | _ -> Alcotest.fail "expected first tool call");
      match List.nth_opt message.content 1 with
      | Some (Types.AToolCall tc) ->
          Alcotest.(check string) "second name" "count" tc.name;
          Alcotest.(check string) "second id" "c2" tc.id
      | _ -> Alcotest.fail "expected second tool call")
  | _ -> Alcotest.fail "unreachable"

(* ── Test 8: null finish_reason does not terminate ── *)

let test_explicit_null_finish_reason_does_not_terminate_stream () =
  let framed_events =
    [
      role_chunk ();
      text_content_chunk "Hello";
      null_finish_chunk ();
      text_content_chunk " World";
      finish_chunk "stop";
    ]
  in
  let events =
    run_interpreter ~reasoning_field:"reasoning_content" framed_events
  in
  let tags = List.map ame_tag events in
  Alcotest.(check (list string))
    "event tags"
    [ "AME_text_start"; "AME_text_delta"; "AME_text_delta"; "AME_done" ]
    tags;
  let done_event =
    List.find_opt (function Types.AME_done _ -> true | _ -> false) events
    |> Option.get_exn_or "expected AME_done"
  in
  match done_event with
  | Types.AME_done { message } -> (
      match List.nth_opt message.content 0 with
      | Some (Types.AText text) ->
          Alcotest.(check string) "final text" "Hello World" text
      | _ -> Alcotest.fail "expected AText in final message")
  | _ -> Alcotest.fail "unreachable"

(* ── Test 9: null content field is ignored ── *)

let test_explicit_null_content_field_is_ignored () =
  let framed_events =
    [
      role_chunk ();
      null_content_chunk ();
      text_content_chunk "Hello";
      finish_chunk "stop";
    ]
  in
  let events =
    run_interpreter ~reasoning_field:"reasoning_content" framed_events
  in
  let tags = List.map ame_tag events in
  Alcotest.(check (list string))
    "event tags"
    [ "AME_text_start"; "AME_text_delta"; "AME_done" ]
    tags

(* ── Test 10: partial snapshots are immutable ── *)

let test_partial_snapshots_are_immutable () =
  let framed_events =
    [
      role_chunk ();
      text_content_chunk "foo";
      text_content_chunk "bar";
      finish_chunk "stop";
    ]
  in
  let events =
    run_interpreter ~reasoning_field:"reasoning_content" framed_events
  in
  let start_event =
    List.find_opt
      (function Types.AME_text_start _ -> true | _ -> false)
      events
    |> Option.get_exn_or "expected AME_text_start"
  in
  match start_event with
  | Types.AME_text_start { partial } -> (
      let captured_text =
        match partial.content with
        | [ Types.AText s ] -> s
        | _ -> Alcotest.fail "expected single AText in start partial"
      in
      Alcotest.(check string) "captured snapshot unchanged" "" captured_text;
      let done_event =
        List.find_opt (function Types.AME_done _ -> true | _ -> false) events
        |> Option.get_exn_or "expected AME_done"
      in
      match done_event with
      | Types.AME_done { message } ->
          let final_text =
            match message.content with
            | [ Types.AText s ] -> s
            | _ -> Alcotest.fail "expected single AText in final message"
          in
          Alcotest.(check string) "stream progressed" "foobar" final_text
      | _ -> Alcotest.fail "unreachable")
  | _ -> Alcotest.fail "unreachable"

(* ── Test runner ── *)

let () =
  Alcotest.run "Openai_completions_interpreter"
    [
      ( "text_stream",
        [
          Alcotest.test_case "produces_correct_events" `Quick
            test_simple_text_stream_produces_correct_events;
        ] );
      ( "reasoning_stream",
        [
          Alcotest.test_case "produces_correct_events" `Quick
            test_reasoning_stream_produces_correct_events;
          Alcotest.test_case "reasoning_field_is_configurable" `Quick
            test_reasoning_field_is_configurable;
        ] );
      ( "tool_call_stream",
        [
          Alcotest.test_case "produces_correct_events" `Quick
            test_tool_call_stream_produces_correct_events;
          Alcotest.test_case "multiple_tool_calls" `Quick
            test_multiple_tool_calls_in_one_response;
        ] );
      ( "done_sentinel",
        [
          Alcotest.test_case "terminates_stream" `Quick
            test_done_sentinel_terminates_stream;
        ] );
      ( "error_handling",
        [
          Alcotest.test_case "malformed_json_produces_error" `Quick
            test_malformed_json_produces_error;
          Alcotest.test_case "null_finish_reason_ignored" `Quick
            test_explicit_null_finish_reason_does_not_terminate_stream;
          Alcotest.test_case "null_content_ignored" `Quick
            test_explicit_null_content_field_is_ignored;
        ] );
      ( "immutability",
        [
          Alcotest.test_case "partial_snapshots_are_immutable" `Quick
            test_partial_snapshots_are_immutable;
        ] );
    ]
