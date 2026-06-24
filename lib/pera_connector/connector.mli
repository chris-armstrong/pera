(** Connector interface for streaming LLM completions.

    This module defines the public seam between the rest of the system and
    concrete LLM connector implementations. Each connector satisfies the module
    type {!S}.

    Shared types used by all connectors are defined here alongside the module
    type. *)

open Pera_types

type tool_schema = {
  name : string;  (** Tool name as presented to the model. *)
  description : string;  (** Short description of what the tool does. *)
  schema : Json_schema.t;  (** JSON schema for the tool's arguments. *)
}
(** A tool schema describes one tool that the model may call. *)

val equal_tool_schema : tool_schema -> tool_schema -> bool
val pp_tool_schema : Format.formatter -> tool_schema -> unit
val show_tool_schema : tool_schema -> string

(** A message in the conversation history. *)
type message =
  | UserMessage of Types.user_message
      (** A message authored by the user (or the harness on behalf of the user).
      *)
  | AssistantMessage of Types.assistant_message
      (** A previously completed assistant turn. *)
  | ToolResultMessage of Types.tool_result_content
      (** The result of a tool call, sent back to the model. Consecutive
          [ToolResultMessage] values in the message list are coalesced into a
          single provider request message where the provider requires it (e.g.
          Anthropic). *)

val equal_message : message -> message -> bool
val pp_message : Format.formatter -> message -> unit
val show_message : message -> string

type context = {
  system : string;
      (** System prompt. Empty string if no system prompt is needed. *)
  messages : message list;
      (** Conversation history, oldest first. Must not be empty. *)
  tools : tool_schema list;
      (** Tools the model is allowed to call. Empty list means no tool use. *)
  thinking : bool;
      (** [true] to enable extended thinking (where supported by the model). *)
}
(** The full context passed to a provider for a single completion request. *)

val equal_context : context -> context -> bool
val pp_context : Format.formatter -> context -> unit
val show_context : context -> string

type simple_stream_options = {
  max_tokens : int;
      (** Maximum number of tokens to generate. Connector-imposed minimum is 1.
      *)
  temperature : float option;
      (** Sampling temperature; [None] uses the provider default. *)
  cache_policy : Types.cache_policy;
      (** Where to place [cache_control] markers in Anthropic requests.
          Ignored by non-Anthropic providers. Default [No_cache]. *)
  cache_ttl : Types.cache_ttl;
      (** TTL applied to every cache breakpoint in the request.
          Default [Five_minutes]. *)
}
(** Options for a simple (non-agentic) streaming completion. *)

val equal_simple_stream_options :
  simple_stream_options -> simple_stream_options -> bool

val pp_simple_stream_options : Format.formatter -> simple_stream_options -> unit
val show_simple_stream_options : simple_stream_options -> string

(** The module type that every concrete connector must satisfy. *)
module type S = sig
  type t
  (** The provider instance type. Holds connection state (e.g. an HTTP client
      and API credentials). Lifetime is tied to the switch passed to {!create}.
  *)

  val name : string
  (** Human-readable provider name used in provenance records. *)

  val create : env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> t
  (** [create ~env ~sw] initialises a provider instance bound to [sw].
      Establishes any persistent connections needed for {!stream_simple} calls.
      The instance is valid for the lifetime of [sw]. *)

  val stream_simple :
    t ->
    model:Types.model ->
    context:context ->
    options:simple_stream_options ->
    sw:Eio.Switch.t ->
    (Types.assistant_message_event, Types.assistant_message) Event_stream.t
  (** [stream_simple provider ~model ~context ~options ~sw] initiates a
      streaming completion request using [provider] and returns an
      {!Event_stream.t} that emits {!Types.assistant_message_event} values as
      they arrive.

      The returned stream:
      - Emits zero or more [AME_*] events as content arrives.
      - Is closed with [Ok final_message] on [AME_done].
      - Is closed with [Error msg] on [AME_error] or a transport failure.

      The request runs in a fibre attached to [sw]. Cancelling [sw] aborts the
      request and closes the stream with an error.

      Never raises on expected failures (network errors, API errors). *)
end
