# Test Patterns Guidelines

## 1. TDD: Tests First, Run Them Red

Write the test before the implementation. Run `dune runtest` and confirm the
test fails before writing any production code. A test that was never red is
not a test.

```
write test → dune runtest (must fail) → write implementation → dune runtest (must pass)
```

---

## 2. Alcotest Assertions — Not Silent Option

### Bad: Silent failures
```ocaml
let test_parse () =
  let result = parse_event chunk in
  match result with
  | None -> ()  (* silent pass when it should fail! *)
  | Some event -> ...
```

### Good: Explicit Alcotest assertions
```ocaml
let test_parse () =
  let event =
    parse_event chunk
    |> Option.get_exn_or "expected parse_event to return Some"
  in
  Alcotest.(check string) "event type" "message_start" event.event_type
```

### Custom testables for domain types
```ocaml
let ame_testable =
  Alcotest.testable Pera_provider.Ame.pp Pera_provider.Ame.equal

let test_interpreter () =
  let events = run_interpreter sse_chunks in
  Alcotest.(check (list ame_testable)) "events match"
    [ AME_text_delta { text = "hello"; partial = ... } ]
    events
```

---

## 3. Validating Event Streams

Tests for SSE parsing and the agent loop validate sequences of events.
Compare the full sequence, not just the last element.

### Pattern: collect-then-compare
```ocaml
let collect_events stream =
  let buf = Buffer.create 8 in
  let rec loop () =
    match Event_stream.take stream with
    | `Event e -> Buffer.add e buf; loop ()
    | `Done _ -> Buffer.contents buf
    | `Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
  in
  loop ()

let test_text_stream () =
  let chunks = [ "data: {\"type\":\"text_delta\",\"text\":\"hi\"}\n\n" ] in
  let stream = Sse_parser.parse chunks in
  let events = collect_events stream in
  Alcotest.(check (list ame_testable)) "events"
    [ AME_text_delta { text = "hi"; ... } ] events
```

---

## 4. Scripted Faux_provider Scenarios

Tests for the agent loop and harness use `Faux_provider.script` to drive
deterministic event sequences. Name each scenario clearly.

```ocaml
let scenario_parallel_tool_calls () =
  let provider = Faux_provider.script
    ~events:[ AME_tool_call_start ...; AME_tool_call_start ... ]
    ~final:final_msg
  in
  let results = Loop_driver.run provider in
  (* verify: tool_execution_end events in completion order *)
  (* verify: tool_result list in source order *)
  ...
```

Each scenario should correspond to a named expected outcome in the spec.

---

## 5. Test Naming

Names should describe the scenario and expected outcome.

### Bad: vague
```ocaml
let test_parser () = ...
let test_loop () = ...
```

### Good: scenario + expectation
```ocaml
let test_sse_chunk_split_across_boundary_emits_single_event () = ...
let test_parallel_tool_results_appended_in_source_order () = ...
let test_cancellation_during_stream_emits_aborted_event () = ...
```

---

## 6. Arrange-Act-Assert Structure

```ocaml
let test_sse_incomplete_line_buffered () =
  (* Arrange *)
  let chunk1 = "data: {\"type\":\"message_sta" in
  let chunk2 = "rt\"}\n\n" in

  (* Act *)
  let events = Sse_parser.parse [ chunk1; chunk2 ] |> collect_events in

  (* Assert *)
  Alcotest.(check int) "one event" 1 (List.length events);
  Alcotest.(check string) "event type" "message_start"
    (List.nth events 0).event_type
```

---

## 7. Layer Driver Pattern

Drivers are not unit tests. They exercise a layer through its full public
interface with realistic inputs and print structured human-readable output.

```ocaml
(* bin/drivers/provider_driver.ml *)
let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let stream = Anthropic_provider.stream_simple ~model ~context ~sw in
  Event_stream.iter stream ~f:(fun event ->
    Printf.printf "event: %s\n" (Ame.to_string event));
  match Event_stream.result stream with
  | Ok msg -> Printf.printf "done: %s\n" (show_assistant_message msg); exit 0
  | Error e -> Printf.printf "error: %s\n" (show_error e); exit 1
```

A driver that is hard to write signals a leaky seam — fix the seam, not the driver.

---

## Anti-Pattern Checklist

Before submitting test code, verify:

- [ ] Test was written before implementation and run red first
- [ ] No silent `match ... | None -> ()` — use `Option.get_exn_or` or `Alcotest.fail`
- [ ] Event stream tests compare full sequences, not last element
- [ ] Custom `Alcotest.testable` defined for all domain types under test
- [ ] Test names describe scenario and expected outcome
- [ ] Tests follow Arrange-Act-Assert structure
- [ ] Drivers exercise the layer's public interface, not internals
