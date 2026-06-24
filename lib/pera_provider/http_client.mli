(** Http_client — thin HTTP transport abstraction over cohttp-eio + TLS.

    Implementation details are hidden behind this interface. Callers depend only
    on the types declared here. *)

type t
(** An abstract HTTP client bound to a single base URL.

    Each {!post_stream} call opens a fresh connection under an internal switch,
    sends the request, streams the response body, then closes the connection.
    The [sw] parameter accepted by {!create} is retained for API symmetry but
    does not govern individual request lifetimes. *)

(** {2 Request outcomes} *)

type transport_kind =
  | Dns  (** DNS lookup returned no addresses for the host. *)
  | Connect
      (** TCP connect failed or timed out — the request never reached the
          server. *)
  | Tls  (** TLS handshake or certificate verification failed. *)
  | Network
      (** The connection broke mid-stream (connection reset, EPIPE, read
          error) after the request was sent. *)
  | Other  (** Unclassified transport failure. *)
(** A coarse classification of why a transport-level request failed. *)

type transport_error = {
  kind : transport_kind;
  message : string;  (** Human-readable detail; always non-empty. *)
}
(** A transport-level failure: the request never completed an HTTP exchange. *)

type http_error = {
  status : int;  (** The non-2xx HTTP status code returned by the server. *)
  message : string;
}
(** The server responded with a non-2xx HTTP status code. *)

type request_error =
  | Transport_error of transport_error
      (** The request failed before a usable HTTP response was received. *)
  | Http_error of http_error
      (** The server returned a non-2xx HTTP response. *)
(** Outcome of a failed request. The two arms distinguish transport failures
    (DNS, TLS, connect, network) from HTTP error responses, replacing the
    previous [status : int option] sentinel. *)

val request_error_to_string : request_error -> string
(** [request_error_to_string e] converts a {!request_error} to a human-readable
    string. Always returns a non-empty string. Never raises. *)

val create :
  env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> string
  -> (t, request_error) result
(** [create ~env ~sw base_url] opens a persistent HTTP connection to [base_url]
    (e.g. ["https://api.anthropic.com"]). Returns [Ok t] on success or
    [Error (Transport_error _)] if the URL is invalid or the initial connection
    fails (the error kind classifies DNS vs connect vs TLS).

    The returned client is valid for the lifetime of [sw]. Never raises on
    expected failure modes. *)

val post_stream :
  client:t ->
  headers:(string * string) list ->
  body:string ->
  on_chunk:(string -> unit) ->
  string ->
  (unit, request_error) result
(** [post_stream ~client ~headers ~body ~on_chunk path] issues a streaming HTTP
    POST to [path] (appended to the base URL stored in [client]) with the given
    [headers] and [body] string. Each chunk of the response body is delivered to
    [on_chunk] as it arrives. Returns [Ok ()] on a successful 2xx response with
    all chunks delivered, or [Error e] on any transport or HTTP error (see
    {!request_error}). Never raises on expected failure modes. *)