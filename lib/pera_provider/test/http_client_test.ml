open Containers
open Pera_provider

(** Drive [Http_client.post_stream] against an address that cannot be connected
    to (port 1 on localhost is unroutable in practice) and assert that the
    result is [Error] with a non-empty [error_to_string]. *)
let test_error_to_string_is_total_and_nonempty () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let result =
    match Http_client.create ~env ~sw "http://127.0.0.1:1/" with
    | Error e -> Error e
    | Ok client ->
        Http_client.post_stream ~client ~headers:[] ~body:"{}"
          ~on_chunk:(fun _ -> ())
          "/"
  in
  match result with
  | Ok () -> Alcotest.fail "expected an Error for an unroutable address"
  | Error e ->
      let msg = Http_client.error_to_string e in
      Alcotest.(check bool)
        "error_to_string returns a non-empty string" true
        (not (String.is_empty msg))

(** [Http_client.create] against an invalid URL returns [Error] with a non-empty
    [error_to_string]. *)
let test_create_error_gives_nonempty_message () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let result = Http_client.create ~env ~sw "http://127.0.0.1:1/" in
  match result with
  | Ok _ -> (
      (* create may succeed (connection is lazy in some Piaf versions);
         in that case drive post_stream to force the failure *)
      let client = Result.get_exn result in
      let post_result =
        Http_client.post_stream ~client ~headers:[] ~body:"{}"
          ~on_chunk:(fun _ -> ())
          "/"
      in
      match post_result with
      | Ok () ->
          Alcotest.fail
            "expected an Error from post_stream against an unroutable address"
      | Error e ->
          let msg = Http_client.error_to_string e in
          Alcotest.(check bool)
            "error_to_string returns a non-empty string" true
            (not (String.is_empty msg)))
  | Error e ->
      let msg = Http_client.error_to_string e in
      Alcotest.(check bool)
        "error_to_string returns a non-empty string" true
        (not (String.is_empty msg))

let () =
  Alcotest.run "Http_client"
    [
      ( "error_to_string",
        [
          Alcotest.test_case "total and non-empty for transport failure" `Quick
            test_error_to_string_is_total_and_nonempty;
          Alcotest.test_case "create error gives non-empty message" `Quick
            test_create_error_gives_nonempty_message;
        ] );
    ]
