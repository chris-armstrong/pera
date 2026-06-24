(** Http_client — thin HTTP transport abstraction over cohttp-eio + TLS.

    Implementation details are hidden behind this interface. Callers depend only
    on the types declared here. *)

type t
(** An abstract HTTP client bound to a single base URL.

    Each {!post_stream} call opens a fresh connection under an internal switch,
    sends the request, streams the response body, then closes the connection.
    The [sw] parameter accepted by {!create} is retained for API symmetry but
    does not govern individual request lifetimes. *)

type error = { message : string; status : int option }
(** An HTTP transport error. [status] is [Some code] for non-2xx HTTP
    responses; [None] for transport-level failures (DNS, connect timeout,
    TLS, connection reset). *)

val error_to_string : error -> string
(** [error_to_string e] converts a transport error to a human-readable string.
    Always returns a non-empty string. Never raises. *)

val create :
  env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> string -> (t, error) result
(** [create ~env ~sw base_url] opens a persistent HTTP connection to [base_url]
    (e.g. ["https://api.anthropic.com"]). Returns [Ok t] on success or [Error e]
    if the URL is invalid or the initial connection fails.

    The returned client is valid for the lifetime of [sw]. Never raises on
    expected failure modes. *)

val post_stream :
  client:t ->
  headers:(string * string) list ->
  body:string ->
  on_chunk:(string -> unit) ->
  string ->
  (unit, error) result
(** [post_stream ~client ~headers ~body ~on_chunk path] issues a streaming HTTP
    POST to [path] (appended to the base URL stored in [client]) with the given
    [headers] and [body] string. Each chunk of the response body is delivered to
    [on_chunk] as it arrives. Returns [Ok ()] on a successful 2xx response with
    all chunks delivered, or [Error e] on any transport or HTTP error. Never
    raises on expected failure modes. *)
