open Pera_types

type compat = {
  base_url : string;  (** Endpoint base URL. *)
  reasoning_field : string;
      (** JSON field name for reasoning content: ["reasoning_content"] (Zen,
          default) or ["reasoning"] (Go). *)
  max_tokens_field : string;
      (** JSON field name for the token limit: ["max_completion_tokens"] or
          ["max_tokens"]. *)
  require_tool_result_name : bool;
      (** When [true], tool-result messages must include a [name] field. *)
  enable_thinking_field : string option;
      (** If [Some field], send [field: true] when [context.thinking = true].
          [None] for providers that enable thinking via model selection (e.g.
          OpenAI o-series). *)
}
(** Per-endpoint compatibility configuration for the OpenAI chat-completions
    API.

    Different providers that expose the same wire format have minor differences
    in field names (e.g. [max_completion_tokens] vs [max_tokens]) and optional
    fields (e.g. whether tool-result messages require a [name]). *)

val opencode_zen_compat : compat
(** OpenCode Zen endpoint preset.

    - [base_url = "https://zen.opencode.ai"]
    - [reasoning_field = "reasoning_content"]
    - [max_tokens_field = "max_completion_tokens"]
    - [require_tool_result_name = false] *)

val opencode_go_compat : compat
(** OpenCode Go endpoint preset.

    - [base_url = "https://opencode.ai/zen/go"]
    - [reasoning_field = "reasoning"]
    - [max_tokens_field = "max_completion_tokens"]
    - [require_tool_result_name = false] *)

val default_compat : compat
(** Standard OpenAI API preset.

    - [base_url = "https://api.openai.com"]
    - [reasoning_field = "reasoning_content"]
    - [max_tokens_field = "max_completion_tokens"]
    - [require_tool_result_name = false] *)

val compat_of_string : string -> compat
(** Select a compatibility preset by name.

    - ["openai"] → {!default_compat}
    - ["zen"] → {!opencode_zen_compat}
    - ["go"] → {!opencode_go_compat} Unknown values fall back to
      {!default_compat}. *)

val messages_to_json :
  ?find_tool_name:(tool_call_id:string -> string option) ->
  compat:compat ->
  Provider.message list ->
  Yojson.Safe.t list
(** [messages_to_json ?find_tool_name ~compat messages] converts a message list
    to the OpenAI chat-completions messages-array format.

    [~find_tool_name] is used only when [compat.require_tool_result_name] is
    [true]. It resolves the tool name for a given [tool_call_id]. Callers who
    know [require_tool_result_name = false] can omit it. *)

val build_request_body :
  model:Types.model ->
  context:Provider.context ->
  options:Provider.simple_stream_options ->
  compat:compat ->
  Yojson.Safe.t
(** [build_request_body ~model ~context ~options ~compat] serialises the
    provider context and streaming options into the OpenAI chat-completions JSON
    request body.

    When [compat.require_tool_result_name] is [true], the function builds the
    tool-name lookup by scanning [context.messages] for [AssistantMessage]
    entries containing [AToolCall] blocks, then passes the lookup closure to
    {!messages_to_json}.

    A non-empty [context.system] is rendered as the first messages entry with
    role ["system"]. *)
