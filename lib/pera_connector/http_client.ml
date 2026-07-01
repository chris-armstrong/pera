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

type transport_kind = Dns | Connect | Tls | Network | Other
type transport_error = { kind : transport_kind; message : string }

type http_error = {
  status : int;
  status_text : string;
  body : string;
  url : string;
  method_ : string;
}

type request_error =
  | Transport_error of transport_error
  | Http_error of http_error

let request_error_to_string = function
  | Transport_error te -> te.message
  | Http_error he ->
      Printf.sprintf "%s %s → HTTP %d %s\n%s" he.method_ he.url he.status
        he.status_text he.body

(** [contains_ci ~sub s] is [true] when [s] contains [sub], case-insensitively.
*)
let contains_ci ~sub s =
  let sub = String.lowercase_ascii sub in
  let s = String.lowercase_ascii s in
  String.mem ~sub s

(** Classify a raised exception into a {!transport_error}. The [message] field
    always carries [Printexc.to_string exn] so no detail is lost even when the
    [kind] falls back to [Other]. Classification is best-effort and prefers
    structured Eio/Tls exception types, falling back to message inspection. *)
let classify_transport exn =
  let message = Printexc.to_string exn in
  let kind =
    match exn with
    | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ -> Tls
    | Eio.Time.Timeout -> Connect
    | Failure m when contains_ci ~sub:"DNS lookup failed" m -> Dns
    | Eio.Exn.Io
        (Eio.Net.E (Eio.Net.Connection_failure Eio.Net.No_matching_addresses), _)
      ->
        Dns
    | Eio.Exn.Io (Eio.Net.E (Eio.Net.Connection_failure _), _) -> Connect
    | Eio.Exn.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> Network
    | Eio.Exn.Io (_, _) when contains_ci ~sub:"tls" message -> Tls
    | _ when contains_ci ~sub:"tls" message -> Tls
    | _ -> Other
  in
  { kind; message }

let transport_error ~kind fmt =
  Format.kasprintf (fun message -> { kind; message }) fmt

let make_tls_config () =
  match Ca_certs.authenticator () with
  | Error (`Msg m) ->
      Error (transport_error ~kind:Tls "CA cert load failed: %s" m)
  | Ok authenticator -> (
      match Tls.Config.client ~authenticator () with
      | Error (`Msg m) ->
          Error (transport_error ~kind:Tls "TLS config failed: %s" m)
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
  Log.info (fun m -> m "TCP connected to %s" host);
  match tls_config_opt with
  | Some cfg ->
      let tls =
        Eio.Time.with_timeout_exn clock connect_timeout_s (fun () ->
            Tls_eio.client_of_flow cfg ?host:(peer_name uri) raw)
      in
      (tls :> connection)
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
  | Error te -> Error (Transport_error te)
  | Ok tls_config_opt ->
      (* The connection is established lazily on the first request, so [create]
         only fails on TLS configuration errors; transport failures (DNS,
         connect, TLS handshake) surface from {!post_stream} as
         [Transport_error]. *)
      let client, conn =
        make_persistent_client ~sw ~clock net tls_config_opt base_uri
      in
      Ok { client; base_uri; base_path; conn }

let invalidate t =
  (match !(t.conn) with
  | Some c -> ( try Eio.Flow.close c with _ -> ())
  | None -> ());
  t.conn := None

let read_body flow =
  let reader = Eio.Buf_read.of_flow flow ~max_size:max_int in
  let buf = Buffer.create 1024 in
  let max_body = 4096 in
  (try
     while Buffer.length buf < max_body do
       Eio.Buf_read.ensure reader 1;
       let n = Eio.Buf_read.buffered_bytes reader in
       let to_take = min n (max_body - Buffer.length buf) in
       let chunk = Eio.Buf_read.take to_take reader in
       Buffer.add_string buf chunk
     done
   with End_of_file -> ());
  let body = Buffer.contents buf in
  if Buffer.length buf >= max_body then body ^ "\n... (truncated)" else body

let check_response_status ~resp ~body ~url ~method_ =
  let code = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Log.info (fun m -> m "HTTP response status: %d" code);
  if Cohttp.Code.is_success code then Ok ()
  else
    let status_text =
      Cohttp.Code.string_of_status (Cohttp.Response.status resp)
    in
    let error_body = read_body body in
    Error
      (Http_error
         { status = code; status_text; body = error_body; url; method_ })

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
  let uri_string = Uri.to_string uri in
  let* () =
    check_response_status ~resp ~body:resp_body ~url:uri_string ~method_:"POST"
  in
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
      | exception exn2 -> Error (Transport_error (classify_transport exn2)))
