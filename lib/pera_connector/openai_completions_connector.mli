(** OpenAI-completions connector implementation.

    Satisfies {!Connector.S}. Sends requests to the OpenAI chat-completions
    endpoint using the OpenAI streaming API (SSE).

    The API key must be provided via the [~api_key] argument to {!create}. A
    convenience wrapper {!create_from_env} reads the key from the
    [OPENAI_API_KEY] environment variable and returns [Error] if absent.

    The base URL is provided via the [~base_url] argument to {!create}. *)

type t

val name : string

val create :
  api_key:string ->
  base_url:string ->
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  t
(** [create ~api_key ~base_url ~env ~sw] initialises an OpenAI connector with
    the given API key and base URL. *)

val create_from_env :
  base_url:string ->
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  (t, string) result
(** [create_from_env ~base_url ~env ~sw] reads [OPENAI_API_KEY] from the
    environment and calls {!create}. Returns [Error] if the variable is not set.
*)

val stream_simple :
  t ->
  model:Pera_types.Types.model ->
  context:Connector.context ->
  options:Connector.simple_stream_options ->
  sw:Eio.Switch.t ->
  ( Pera_types.Types.assistant_message_event,
    Pera_types.Types.assistant_message )
  Event_stream.t
