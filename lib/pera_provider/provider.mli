(** Provider interface for streaming LLM completions.

    This module defines the public seam between the rest of the system and
    concrete LLM provider implementations. Each provider satisfies the module
    type {!S}.

    Shared types used by all providers are defined here alongside the module
    type. *)

open Pera_types

type tool_schema = {
  name : string;  (** Tool name as presented to the model. *)
  description : string;  (** Short description of what the tool does. *)
  schema : Json_schema.t;  (** JSON schema for the tool's arguments. *)
}
(** A tool schema describes one tool that the model may call. *)

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

type simple_stream_options = {
  max_tokens : int;
      (** Maximum number of tokens to generate. Provider-imposed minimum is 1.
      *)
  temperature : float option;
      (** Sampling temperature; [None] uses the provider default. *)
}
(** Options for a simple (non-agentic) streaming completion. *)

(** The module type that every concrete provider must satisfy. *)
module type S = sig
  val name : string
  (** Human-readable provider name used in provenance records. *)

  val stream_simple :
    env:Eio_unix.Stdenv.base ->
    model:Types.model ->
    context:context ->
    options:simple_stream_options ->
    sw:Eio.Switch.t ->
    (Types.assistant_message_event, Types.assistant_message) Event_stream.t
  (** [stream_simple ~env ~model ~context ~options ~sw] initiates a streaming
      completion request and returns an {!Event_stream.t} that emits
      {!Types.assistant_message_event} values as they arrive.

      [env] is the Eio environment — required for making network connections.

      The returned stream:
      - Emits zero or more [AME_*] events as content arrives.
      - Is closed with [Ok final_message] on [AME_done].
      - Is closed with [Error msg] on [AME_error] or a transport failure.

      The request runs in a fibre attached to [sw]. Cancelling [sw] aborts the
      request and closes the stream with an error.

      Never raises on expected failures (network errors, API errors). *)
end
