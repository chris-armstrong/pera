(** Anthropic connector implementation.

    Satisfies {!Connector.S}. Sends requests to
    [https://api.anthropic.com/v1/messages] using the Anthropic streaming
    Messages API (SSE).

    The API key must be provided via the [~api_key] argument to {!create}. A
    convenience wrapper {!create_from_env} reads the key from the
    [ANTHROPIC_API_KEY] environment variable and returns [Error] if absent. *)

type t

val name : string

val create : api_key:string -> env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> t
(** [create ~api_key ~env ~sw] initialises an Anthropic connector with the given
    API key. *)

val create_from_env :
  env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> (t, string) result
(** [create_from_env ~env ~sw] reads [ANTHROPIC_API_KEY] from the environment
    and calls {!create}. Returns [Error] if the variable is not set. *)

val stream_simple :
  t ->
  model:Pera_types.Types.model ->
  context:Connector.context ->
  options:Connector.simple_stream_options ->
  sw:Eio.Switch.t ->
  ( Pera_types.Types.assistant_message_event,
    Pera_types.Types.assistant_message )
  Event_stream.t
