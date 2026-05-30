open Containers

let src = Logs.Src.create "pera.http_client" ~doc:"Pera HTTP client"

module Log = (val Logs.src_log src : Logs.LOG)

type t = { piaf_client : Piaf.Client.t; base_path : string }
(** Wraps a persistent [Piaf.Client.t]. Lifetime tied to the switch used at
    creation time. *)

type error = string
(** The error type is a plain string internally; abstract in the .mli. *)

let error_to_string e = e

(** Check that the HTTP response status indicates success. Returns an error
    string with the status code and response body on failure. *)
let check_response_status (response : Piaf.Response.t) =
  if Piaf.Status.is_successful response.status then Ok ()
  else
    let status_code = Piaf.Status.to_code response.status in
    let body_str =
      Piaf.Body.to_string response.body
      |> Result.value ~default:"<unreadable body>"
    in
    Log.debug (fun m -> m "HTTP failure response body:\n%s" body_str);
    Error (Printf.sprintf "HTTP error %d: %s" status_code body_str)

let create ~env ~sw base_url =
  let uri = Uri.of_string base_url in
  let base_path =
    match Uri.path uri with
    | "" | "/" -> ""
    | p -> p
  in
  Piaf.Client.create ~sw env uri
  |> Result.map (fun piaf_client -> { piaf_client; base_path })
  |> Result.map_error (fun piaf_err ->
      Printf.sprintf "HTTP client creation failed: %s"
        (Piaf.Error.to_string piaf_err))

let post_stream ~client ~headers ~body ~on_chunk path =
  let open Result.Syntax in
  let piaf_body = Piaf.Body.of_string body in
  let full_path = client.base_path ^ path in
  let* response =
    Piaf.Client.post client.piaf_client ~headers ~body:piaf_body full_path
    |> Result.map_error (fun piaf_err ->
        Printf.sprintf "HTTP request failed: %s" (Piaf.Error.to_string piaf_err))
  in
  let status_code = Piaf.Status.to_code response.status in
  Log.debug (fun m -> m "HTTP response status: %d" status_code);
  let* () = check_response_status response in
  Piaf.Body.fold_string ~init:() response.body ~f:(fun () chunk ->
      on_chunk chunk)
  |> Result.map_error (fun piaf_err ->
      Printf.sprintf "HTTP body read failed: %s" (Piaf.Error.to_string piaf_err))
