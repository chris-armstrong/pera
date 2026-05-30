open Containers
open Pera_provider

(** Spin up a minimal in-process HTTP/1.1 server on a random loopback port,
    issue one [post_stream] call, and return the request-line path the server
    received. *)
let capture_request_path ~env ~sw ~base_url ~path =
  let net = Eio.Stdenv.net env in
  let server =
    Eio.Net.listen ~sw ~backlog:1 ~reuse_addr:true net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr server with
    | `Tcp (_, p) -> p
    | _ -> failwith "unexpected listening address type"
  in
  let received = ref "" in
  Eio.Fiber.fork ~sw (fun () ->
      let conn, _addr = Eio.Net.accept ~sw server in
      let reader = Eio.Buf_read.of_flow conn ~max_size:65536 in
      let request_line = Eio.Buf_read.line reader in
      (match String.split_on_char ' ' request_line with
      | _ :: p :: _ -> received := p
      | _ -> ());
      (* Drain headers so the client isn't blocked sending them. *)
      (try
         let rec drain () =
           match Eio.Buf_read.line reader with
           | "\r" | "" -> ()
           | _ -> drain ()
         in
         drain ()
       with _ -> ());
      Eio.Flow.copy_string "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n" conn);
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port base_url in
  (match Http_client.create ~env ~sw url with
  | Error e -> failwith (Http_client.error_to_string e)
  | Ok client ->
      ignore
        (Http_client.post_stream ~client ~headers:[] ~body:"{}"
           ~on_chunk:(fun _ -> ()) path));
  !received

(** [post_stream] prepends the path component of [base_url] to [path]. *)
let test_base_path_prepended () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let got = capture_request_path ~env ~sw ~base_url:"/zen/go" ~path:"/v1/chat/completions" in
  Alcotest.(check string)
    "path includes base prefix" "/zen/go/v1/chat/completions" got

(** [post_stream] with a [base_url] that has no path component passes [path]
    through unchanged. *)
let test_no_base_path () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let got = capture_request_path ~env ~sw ~base_url:"" ~path:"/v1/chat/completions" in
  Alcotest.(check string)
    "path unchanged when no base prefix" "/v1/chat/completions" got

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
      ( "base_path",
        [
          Alcotest.test_case "prepended when base_url has path prefix" `Quick
            test_base_path_prepended;
          Alcotest.test_case "unchanged when base_url has no path" `Quick
            test_no_base_path;
        ] );
      ( "error_to_string",
        [
          Alcotest.test_case "total and non-empty for transport failure" `Quick
            test_error_to_string_is_total_and_nonempty;
          Alcotest.test_case "create error gives non-empty message" `Quick
            test_create_error_gives_nonempty_message;
        ] );
    ]
