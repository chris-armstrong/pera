(** Anthropic request body construction.

    This module owns the serialisation of a {!Provider.context} into the JSON
    request body expected by the Anthropic messages API. It is separated from
    {!Anthropic_provider} so that the serialisation logic can be unit-tested
    without standing up an HTTP connection. *)

open Pera_types

val build_request_body :
  model:Types.model ->
  context:Provider.context ->
  options:Provider.simple_stream_options ->
  Yojson.Safe.t
(** [build_request_body ~model ~context ~options] serialises the provider
    context and streaming options into the Anthropic messages-API JSON object.

    Consecutive {!Provider.ToolResultMessage} entries in [context.messages] are
    coalesced into a single ["user"]-role message carrying multiple
    [tool_result] content blocks, as required by the Anthropic API. *)

val messages_to_json : Provider.message list -> Yojson.Safe.t list
(** [messages_to_json messages] converts a message list to the Anthropic
    messages-array format, coalescing consecutive {!Provider.ToolResultMessage}
    values into single ["user"]-role messages with multiple [tool_result]
    blocks.

    Source order of tool-result blocks within each coalesced message is
    preserved. *)
