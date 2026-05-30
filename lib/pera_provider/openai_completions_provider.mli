(** OpenAI-completions provider implementation.

    Satisfies {!Provider.S}. Sends requests to the OpenAI chat-completions
    endpoint using the OpenAI streaming API (SSE).

    The API key is read from the [OPENAI_API_KEY] environment variable at
    {!create} time. If the variable is not set, {!create} raises [Failure].

    The base URL is read from [OPENAI_BASE_URL] (defaults to
    [Openai_completions_request.default_compat.base_url]).

    Piaf internals are hidden behind this interface. *)

include Provider.S
