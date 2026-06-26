open Containers
open Pera_connector.Sse_parser

(* ------------------------------------------------------------------ *)
(* Alcotest testable for framed_event                                  *)
(* ------------------------------------------------------------------ *)

let pp_framed_event ppf e =
  Fmt.pf ppf "{ event_type=%S; data=%S; id=%a }" e.event_type e.data
    (Fmt.option (fun ppf s -> Fmt.pf ppf "Some %S" s))
    e.id

let equal_framed_event a b =
  String.equal a.event_type b.event_type
  && String.equal a.data b.data
  && Option.equal String.equal a.id b.id

let framed_event_testable : framed_event Alcotest.testable =
  Alcotest.testable pp_framed_event equal_framed_event

(* ------------------------------------------------------------------ *)
(* Helper: feed a single chunk from initial_state                      *)
(* ------------------------------------------------------------------ *)

let feed_one chunk =
  let _state, events = feed initial_state chunk in
  events

(* ------------------------------------------------------------------ *)
(* Test 1: single complete event in one chunk                         *)
(* ------------------------------------------------------------------ *)

let test_single_event_in_one_chunk () =
  (* Arrange *)
  let chunk = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n" in
  (* Act *)
  let events = feed_one chunk in
  (* Assert *)
  Alcotest.(check int) "one event" 1 (List.length events);
  let event =
    List.head_opt events
    |> Option.get_exn_or "expected at least one framed_event"
  in
  Alcotest.(check string) "event_type" "message_start" event.event_type;
  Alcotest.(check string) "data" "{\"type\":\"message_start\"}" event.data;
  Alcotest.(check (option string)) "id is None" None event.id

(* ------------------------------------------------------------------ *)
(* Test 2: event split across two chunks                               *)
(* ------------------------------------------------------------------ *)

let test_event_split_across_two_chunks () =
  (* Arrange: split in the middle of the data field *)
  let chunk1 = "event: content_block_delta\ndata: {\"type\":\"text_del" in
  let chunk2 = "ta\"}\n\n" in
  (* Act *)
  let state1, events1 = feed initial_state chunk1 in
  let _state2, events2 = feed state1 chunk2 in
  (* Assert: first chunk produces no complete events *)
  Alcotest.(check int) "no events from chunk1" 0 (List.length events1);
  (* Second chunk completes the event *)
  Alcotest.(check int) "one event from chunk2" 1 (List.length events2);
  let event =
    List.head_opt events2
    |> Option.get_exn_or "expected one framed_event from chunk2"
  in
  Alcotest.(check string) "event_type" "content_block_delta" event.event_type;
  Alcotest.(check string) "data" "{\"type\":\"text_delta\"}" event.data

(* ------------------------------------------------------------------ *)
(* Test 3: multiple events in one chunk                                *)
(* ------------------------------------------------------------------ *)

let test_multiple_events_in_one_chunk () =
  (* Arrange: two complete events concatenated *)
  let chunk =
    "event: ping\ndata: {}\n\n"
    ^ "event: content_block_delta\ndata: {\"text\":\"hi\"}\n\n"
  in
  (* Act *)
  let events = feed_one chunk in
  (* Assert *)
  Alcotest.(check (list framed_event_testable))
    "two events"
    [
      { event_type = "ping"; data = "{}"; id = None };
      {
        event_type = "content_block_delta";
        data = "{\"text\":\"hi\"}";
        id = None;
      };
    ]
    events

(* ------------------------------------------------------------------ *)
(* Test 4: data-only event has empty event_type                        *)
(* ------------------------------------------------------------------ *)

let test_data_only_event_has_empty_event_type () =
  (* Arrange: SSE event with no event: field *)
  let chunk = "data: {\"type\":\"ping\"}\n\n" in
  (* Act *)
  let events = feed_one chunk in
  (* Assert *)
  Alcotest.(check int) "one event" 1 (List.length events);
  let event =
    List.head_opt events |> Option.get_exn_or "expected one framed_event"
  in
  Alcotest.(check string) "event_type is empty" "" event.event_type;
  Alcotest.(check string) "data" "{\"type\":\"ping\"}" event.data

(* ------------------------------------------------------------------ *)
(* Test 5: event with id field sets id to Some value                   *)
(* ------------------------------------------------------------------ *)

let test_event_with_id_field () =
  (* Arrange *)
  let chunk = "event: message\ndata: {}\nid: abc123\n\n" in
  (* Act *)
  let events = feed_one chunk in
  (* Assert *)
  Alcotest.(check int) "one event" 1 (List.length events);
  let event =
    List.head_opt events |> Option.get_exn_or "expected one framed_event"
  in
  Alcotest.(check (option string)) "id is Some abc123" (Some "abc123") event.id

(* ------------------------------------------------------------------ *)
(* Test 6: QCheck property — chunk split preserves events              *)
(* ------------------------------------------------------------------ *)

(** Collect all events from feeding chunks in order, starting from
    [initial_state]. *)
let collect_events chunks =
  let _final_state, all_events =
    List.fold_left
      (fun (st, acc) chunk ->
        let st', evts = feed st chunk in
        (st', acc @ evts))
      (initial_state, []) chunks
  in
  all_events

(** Generate a valid SSE byte sequence with one or more complete events, paired
    with a random split position within that sequence. *)
let gen_sse_with_split =
  let open QCheck2.Gen in
  (* Generate a simple alphabetic string for field values. *)
  let gen_value = string_size (1 -- 30) ~gen:(char_range 'a' 'z') in
  let gen_event =
    let+ event_type = gen_value and* data = gen_value in
    "event: " ^ event_type ^ "\ndata: " ^ data ^ "\n\n"
  in
  let gen_sequence =
    let+ events = list_size (1 -- 5) gen_event in
    String.concat "" events
  in
  let* sse_bytes = gen_sequence in
  let len = String.length sse_bytes in
  let+ split_pos = int_range 0 len in
  (sse_bytes, split_pos)

let test_qcheck_chunk_split_preserves_events =
  QCheck2.Test.make ~name:"chunk_split_preserves_events" ~count:1000
    gen_sse_with_split (fun (sse_bytes, split_pos) ->
      let whole_events = collect_events [ sse_bytes ] in
      let len = String.length sse_bytes in
      let chunk1 = String.sub sse_bytes 0 split_pos in
      let chunk2 = String.sub sse_bytes split_pos (len - split_pos) in
      let split_events = collect_events [ chunk1; chunk2 ] in
      List.equal equal_framed_event whole_events split_events)

(* ------------------------------------------------------------------ *)
(* Test runner                                                          *)
(* ------------------------------------------------------------------ *)

let unit_tests =
  [
    ( "sse_parser",
      [
        Alcotest.test_case "single_event_in_one_chunk" `Quick
          test_single_event_in_one_chunk;
        Alcotest.test_case "event_split_across_two_chunks" `Quick
          test_event_split_across_two_chunks;
        Alcotest.test_case "multiple_events_in_one_chunk" `Quick
          test_multiple_events_in_one_chunk;
        Alcotest.test_case "data_only_event_has_empty_event_type" `Quick
          test_data_only_event_has_empty_event_type;
        Alcotest.test_case "event_with_id_field" `Quick test_event_with_id_field;
      ] );
  ]

let qcheck_tests =
  [
    ( "sse_parser_qcheck",
      [
        QCheck_alcotest.to_alcotest ~speed_level:`Quick
          test_qcheck_chunk_split_preserves_events;
      ] );
  ]

let () = Alcotest.run "sse_parser" (unit_tests @ qcheck_tests)
