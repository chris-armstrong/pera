(** Http_client — thin HTTP transport abstraction over piaf.

    Piaf types are hidden behind this interface. Callers depend only on the
    types declared here. *)

type error
(** An opaque HTTP transport error. *)

val error_to_string : error -> string
(** [error_to_string e] converts a transport error to a human-readable string.
    Always returns a non-empty string. Never raises. *)

val post_stream :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  headers:(string * string) list ->
  body:string ->
  on_chunk:(string -> unit) ->
  string ->
  (unit, error) result
(** [post_stream ~env ~sw ~headers ~body ~on_chunk url] issues a streaming HTTP
    POST to [url] with the given [headers] and [body] string. Each chunk of the
    response body is delivered to [on_chunk] as it arrives. Returns [Ok ()] on a
    successful 2xx response with all chunks delivered, or [Error e] on any
    transport or HTTP error. Never raises on expected failure modes. *)
