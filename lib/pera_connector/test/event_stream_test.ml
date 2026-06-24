open Containers
open Pera_connector
open Pera_types

let stop_error_testable : Types.stop_error Alcotest.testable =
  Alcotest.testable Types.pp_stop_error Types.equal_stop_error

let result_testable =
  Alcotest.(result string (pair string stop_error_testable))

(* Test 1: producer fibre pushes 3 events and closes; consumer collects via iter *)
let test_producer_consumer_fibre () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let stream = Event_stream.create ~capacity:32 in
  let collected = ref [] in
  Eio.Fiber.fork ~sw (fun () ->
      Event_stream.push stream "e1";
      Event_stream.push stream "e2";
      Event_stream.push stream "e3";
      Event_stream.close stream "final");
  let final_result =
    Event_stream.iter stream ~f:(fun e -> collected := e :: !collected)
  in
  let events = List.rev !collected in
  Alcotest.(check (list string))
    "all 3 events arrive" [ "e1"; "e2"; "e3" ] events;
  Alcotest.(check result_testable)
    "result is Ok final" (Ok "final") final_result

(* Test 2: producer calls close_error; consumer's iter returns Error *)
let test_close_error_propagates () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let stream : (string, string) Event_stream.t =
    Event_stream.create ~capacity:32
  in
  Eio.Fiber.fork ~sw (fun () ->
      Event_stream.push stream "e1";
      Event_stream.close_error stream "something went wrong"
        Types.Transport);
  let collected = ref [] in
  let final_result =
    Event_stream.iter stream ~f:(fun e -> collected := e :: !collected)
  in
  Alcotest.(check (list string))
    "one event before error" [ "e1" ] (List.rev !collected);
  Alcotest.(check result_testable)
    "result is Error"
    (Error ("something went wrong", Types.Transport))
    final_result

(* Test 3: backpressure — capacity 1 stream blocks producer on 2nd push until consumer takes 1st *)
let test_backpressure_bounded_capacity () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let stream : (int, unit) Event_stream.t = Event_stream.create ~capacity:1 in
  (* Track how many pushes the producer has completed *)
  let push_count = Atomic.make 0 in
  Eio.Fiber.fork ~sw (fun () ->
      Event_stream.push stream 1;
      Atomic.set push_count 1;
      (* This second push blocks until consumer takes the first event *)
      Event_stream.push stream 2;
      Atomic.set push_count 2;
      Event_stream.close stream ());
  (* Yield to let the producer run until it blocks on the 2nd push *)
  Eio.Fiber.yield ();
  (* Producer should have completed exactly 1 push — blocked on 2nd *)
  Alcotest.(check int)
    "producer blocked after 1st push" 1 (Atomic.get push_count);
  (* Now take the first event — this unblocks the producer *)
  let item1 = Event_stream.take stream in
  (match item1 with
  | `Event n -> Alcotest.(check int) "first event is 1" 1 n
  | `Done _ | `Error _ -> Alcotest.fail "expected Event, got Done/Error");
  (* Yield again to let the producer complete the 2nd push *)
  Eio.Fiber.yield ();
  Alcotest.(check int)
    "producer unblocked and pushed 2nd" 2 (Atomic.get push_count);
  (* Consume remaining events to let the switch finish *)
  let _item2 = Event_stream.take stream in
  let _done = Event_stream.take stream in
  ()

let () =
  Alcotest.run "Event_stream"
    [
      ( "producer_consumer",
        [
          Alcotest.test_case "producer fibre pushes 3 events and closes" `Quick
            test_producer_consumer_fibre;
        ] );
      ( "error_propagation",
        [
          Alcotest.test_case "close_error propagates to consumer iter" `Quick
            test_close_error_propagates;
        ] );
      ( "backpressure",
        [
          Alcotest.test_case
            "bounded capacity 1 blocks producer until consumer takes" `Quick
            test_backpressure_bounded_capacity;
        ] );
    ]
