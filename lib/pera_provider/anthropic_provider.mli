(** Anthropic provider implementation.

    Satisfies {!Provider.S}. Sends requests to
    [https://api.anthropic.com/v1/messages] using the Anthropic streaming
    Messages API (SSE).

    The API key is read from the [ANTHROPIC_API_KEY] environment variable. If
    the variable is not set, {!stream_simple} closes the stream immediately with
    an error.

    Piaf internals are hidden behind this interface. *)

include Provider.S
