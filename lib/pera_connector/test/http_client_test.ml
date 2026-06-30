open Containers
open Pera_connector

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
           match Eio.Buf_read.line reader with "\r" | "" -> () | _ -> drain ()
         in
         drain ()
       with _ -> ());
      Eio.Flow.copy_string "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n" conn);
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port base_url in
  (match Http_client.create ~env ~sw url with
  | Error e -> failwith (Http_client.request_error_to_string e)
  | Ok client ->
      ignore
        (Http_client.post_stream ~client ~headers:[] ~body:"{}"
           ~on_chunk:(fun _ -> ())
           path));
  !received

(** [post_stream] prepends the path component of [base_url] to [path]. *)
let test_base_path_prepended () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let got =
    capture_request_path ~env ~sw ~base_url:"/zen/go"
      ~path:"/v1/chat/completions"
  in
  Alcotest.(check string)
    "path includes base prefix" "/zen/go/v1/chat/completions" got

(** [post_stream] with a [base_url] that has no path component passes [path]
    through unchanged. *)
let test_no_base_path () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let got =
    capture_request_path ~env ~sw ~base_url:"" ~path:"/v1/chat/completions"
  in
  Alcotest.(check string)
    "path unchanged when no base prefix" "/v1/chat/completions" got

(** A transport failure must be reported as [Transport_error] (not an
    [Http_error] inferred from a [None] status sentinel), with a non-empty
    message and a non-[Other] kind for the unroutable-port case. *)
let check_transport_error ?(expect_kind = None) label result =
  match result with
  | Ok () -> Alcotest.fail "expected an Error for an unroutable address"
  | Error (Http_client.Http_error _) ->
      Alcotest.fail
        (Printf.sprintf
           "%s: expected Transport_error, got Http_error" label)
  | Error (Http_client.Transport_error te) ->
      Alcotest.(check bool)
        (label ^ ": message non-empty") true
        (not (String.is_empty te.message));
      (match expect_kind with
       | Some k ->
           let actual = Http_client.request_error_to_string
             (Http_client.Transport_error te)
           in
           let expected = Http_client.request_error_to_string
             (Http_client.Transport_error { te with kind = k })
           in
           Alcotest.(check string) (label ^ ": kind") expected actual
       | None -> ())

(** Drive [Http_client.post_stream] against an address that cannot be connected
    to (port 1 on localhost is unroutable in practice) and assert that the
    result is a [Transport_error] with a non-empty message. *)
let test_transport_failure_is_transport_error () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let result =
    Eio.Time.with_timeout_exn clock 5.0 @@ fun () ->
    match Http_client.create ~env ~sw "http://127.0.0.1:1/" with
    | Error e -> Error e
    | Ok client ->
        Http_client.post_stream ~client ~headers:[] ~body:"{}"
          ~on_chunk:(fun _ -> ())
          "/"
  in
  (* Port 1 is unroutable: classify as [Connect] (connection refused). *)
  check_transport_error ~expect_kind:(Some Http_client.Connect)
    "post_stream unroutable" result

(** [Http_client.create] against an invalid URL returns a [Transport_error]
    with a non-empty message. *)
let test_create_error_gives_transport_error () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 5.0 @@ fun () ->
  let result = Http_client.create ~env ~sw "http://127.0.0.1:1/" in
  match result with
  | Ok client -> (
      (* create may succeed (connection is lazy); in that case drive post_stream
         to force the failure. *)
      let post_result =
        Http_client.post_stream ~client ~headers:[] ~body:"{}"
          ~on_chunk:(fun _ -> ())
          "/"
      in
      check_transport_error ~expect_kind:(Some Http_client.Connect)
        "post_stream unroutable" post_result)
  | Error e -> check_transport_error "create unroutable" (Error e)

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
      ( "transport_error",
        [
          Alcotest.test_case "post_stream unroutable -> Transport_error" `Quick
            test_transport_failure_is_transport_error;
          Alcotest.test_case "create unroutable -> Transport_error" `Quick
            test_create_error_gives_transport_error;
        ] );
    ]