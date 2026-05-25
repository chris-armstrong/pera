open Containers
open Pera_provider

(** Drive [Http_client.post_stream] against an address that cannot be connected
    to (port 1 on localhost is unroutable in practice) and assert that the
    result is [Error] with a non-empty [error_to_string]. *)
let test_error_to_string_is_total_and_nonempty () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let result =
    Http_client.post_stream ~env ~sw ~headers:[] ~body:"{}"
      ~on_chunk:(fun _ -> ())
      "http://127.0.0.1:1/"
  in
  match result with
  | Ok () ->
      Alcotest.fail
        "expected post_stream to return Error for an unroutable address"
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
        ] );
    ]
