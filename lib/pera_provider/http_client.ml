open Containers

let src = Logs.Src.create "pera.http_client" ~doc:"Pera HTTP client"

module Log = (val Logs.src_log src : Logs.LOG)

let () = Mirage_crypto_rng_unix.use_default ()

(* Concrete connection type: a two-way flow that can be closed.
   Both plain TCP sockets and TLS connections coerce to this type. *)
type connection = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type t = {
  client : Cohttp_eio.Client.t;
  base_uri : Uri.t;
  base_path : string;
  conn : connection option ref;
}

type error = string

let error_to_string e = e

let make_tls_config () =
  match Ca_certs.authenticator () with
  | Error (`Msg m) -> Error (Printf.sprintf "CA cert load failed: %s" m)
  | Ok authenticator -> (
      match Tls.Config.client ~authenticator () with
      | Error (`Msg m) -> Error (Printf.sprintf "TLS config failed: %s" m)
      | Ok cfg -> Ok cfg)

let peer_name uri =
  Uri.host uri
  |> Option.flat_map (fun s ->
      match Domain_name.of_string s with
      | Error _ -> None
      | Ok d -> Domain_name.host d |> Result.to_opt)

let connect_timeout_s = 10.0

let open_conn ~sw ~clock net tls_config_opt uri : connection =
  let service =
    match Uri.port uri with
    | Some p -> Int.to_string p
    | None -> Option.value ~default:"http" (Uri.scheme uri)
  in
  let host = Uri.host_with_default ~default:"localhost" uri in
  let addr =
    match Eio.Net.getaddrinfo_stream ~service net host with
    | addr :: _ -> addr
    | [] -> failwith (Printf.sprintf "DNS lookup failed for %s" host)
  in
  let raw =
    Eio.Time.with_timeout_exn clock connect_timeout_s (fun () ->
        Eio.Net.connect ~sw net addr)
  in
  Log.debug (fun m -> m "opened TCP connection to %s" host);
  match tls_config_opt with
  | Some cfg ->
      (Tls_eio.client_of_flow cfg ?host:(peer_name uri) raw :> connection)
  | None -> (raw :> connection)

let make_persistent_client ~sw ~clock net tls_config_opt base_uri =
  let conn : connection option ref = ref None in
  let factory ~sw:_ _uri =
    match !conn with
    | Some c -> (c :> _ Eio.Flow.two_way)
    | None ->
        let c = open_conn ~sw ~clock net tls_config_opt base_uri in
        conn := Some c;
        (c :> _ Eio.Flow.two_way)
  in
  let client = Cohttp_eio.Client.make_generic factory in
  (client, conn)

let create ~env ~sw base_url =
  let base_uri = Uri.of_string base_url in
  let base_path = match Uri.path base_uri with "" | "/" -> "" | p -> p in
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let tls_result =
    match Uri.scheme base_uri with
    | Some "https" -> Result.map Option.some (make_tls_config ())
    | _ -> Ok None
  in
  match tls_result with
  | Error m -> Error m
  | Ok tls_config_opt ->
      let client, conn =
        make_persistent_client ~sw ~clock net tls_config_opt base_uri
      in
      Ok { client; base_uri; base_path; conn }

let invalidate t =
  (match !(t.conn) with
  | Some c -> ( try Eio.Flow.close c with _ -> ())
  | None -> ());
  t.conn := None

let check_response_status (resp : Cohttp.Response.t) =
  let code = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Log.debug (fun m -> m "HTTP response status: %d" code);
  if Cohttp.Code.is_success code then Ok ()
  else Error (Printf.sprintf "HTTP error %d" code)

let read_body_chunks body ~on_chunk =
  let reader = Eio.Buf_read.of_flow body ~max_size:max_int in
  try
    while true do
      Eio.Buf_read.ensure reader 1;
      let n = Eio.Buf_read.buffered_bytes reader in
      let chunk = Eio.Buf_read.take n reader in
      on_chunk chunk
    done
  with End_of_file -> ()

let do_request ~client ~headers ~body ~on_chunk path =
  let open Result.Syntax in
  let full_path = client.base_path ^ path in
  let uri = Uri.with_path client.base_uri full_path in
  let cohttp_headers = Cohttp.Header.of_list headers in
  let body_src = Cohttp_eio.Body.of_string body in
  Eio.Switch.run @@ fun sw ->
  let resp, resp_body =
    Cohttp_eio.Client.post ~headers:cohttp_headers ~body:body_src client.client
      ~sw uri
  in
  let* () = check_response_status resp in
  read_body_chunks resp_body ~on_chunk;
  Ok ()

let post_stream ~client ~headers ~body ~on_chunk path =
  match do_request ~client ~headers ~body ~on_chunk path with
  | r -> r
  | exception exn -> (
      Log.debug (fun m ->
          m "transport error (will reconnect): %s" (Printexc.to_string exn));
      invalidate client;
      match do_request ~client ~headers ~body ~on_chunk path with
      | r -> r
      | exception exn2 ->
          Error
            (Printf.sprintf "HTTP request failed: %s" (Printexc.to_string exn2))
      )
