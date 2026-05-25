open Containers

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
    Error (Printf.sprintf "HTTP error %d: %s" status_code body_str)

let post_stream ~env ~sw ~headers ~body ~on_chunk url =
  let open Result.Syntax in
  let uri = Uri.of_string url in
  let piaf_body = Piaf.Body.of_string body in
  let* response =
    Piaf.Client.Oneshot.post ~headers ~body:piaf_body ~sw env uri
    |> Result.map_error (fun piaf_err ->
        Printf.sprintf "HTTP request failed: %s" (Piaf.Error.to_string piaf_err))
  in
  let* () = check_response_status response in
  Piaf.Body.fold_string ~init:() response.body ~f:(fun () chunk ->
      on_chunk chunk)
  |> Result.map_error (fun piaf_err ->
      Printf.sprintf "HTTP body read failed: %s" (Piaf.Error.to_string piaf_err))
