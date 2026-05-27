(** Anthropic provider implementation.

    Satisfies {!Provider.S}. Sends requests to
    [https://api.anthropic.com/v1/messages] using the Anthropic streaming
    Messages API (SSE).

    The API key is read from the [ANTHROPIC_API_KEY] environment variable at
    {!create} time. If the variable is not set, {!create} raises [Failure].

    Piaf internals are hidden behind this interface. *)

include Provider.S
