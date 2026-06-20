(** Core data model types for the Pera AI agent framework.

    These types form the vocabulary shared by the provider layer and the agent
    core. All types are immutable value types — no mutable state. *)

(** {1 Content variants} *)

(** Content variants for user messages. *)
type user_content =
  | UText of string  (** A plain-text content block. *)
  | UImage of { url : string; media_type : string }
      (** An image content block identified by URL and MIME media type. *)

val equal_user_content : user_content -> user_content -> bool
val pp_user_content : Format.formatter -> user_content -> unit
val show_user_content : user_content -> string

(** Content variants for assistant messages. *)
type assistant_content =
  | AText of string  (** A plain-text block produced by the model. *)
  | AThinking of { text : string; signature : string option }
      (** An extended thinking block; [signature] carries the provider token. *)
  | AToolCall of tool_call  (** A tool invocation requested by the model. *)

and tool_call = {
  id : string;
      (** Provider-assigned unique identifier for this call within the message.
      *)
  name : string;  (** Name of the tool being called. *)
  arguments : Yojson.Safe.t;
      (** Parsed JSON arguments as supplied by the model. *)
}
(** A single tool invocation in an assistant message. *)

val equal_assistant_content : assistant_content -> assistant_content -> bool
val pp_assistant_content : Format.formatter -> assistant_content -> unit
val show_assistant_content : assistant_content -> string
val equal_tool_call : tool_call -> tool_call -> bool
val pp_tool_call : Format.formatter -> tool_call -> unit
val show_tool_call : tool_call -> string

type tool_result_content = {
  tool_call_id : string;
      (** Matches the [id] field of the [tool_call] this result answers. *)
  content : Yojson.Safe.t;
      (** Tool output as a JSON value (text or structured data). *)
  is_error : bool;
      (** [true] when the tool execution failed (schema validation, runtime
          error, or explicit denial). *)
}
(** The content of a tool result message (sent back to the model after executing
    a tool call). *)

val equal_tool_result_content :
  tool_result_content -> tool_result_content -> bool

val pp_tool_result_content : Format.formatter -> tool_result_content -> unit
val show_tool_result_content : tool_result_content -> string

(** {1 Message types} *)

type user_message = {
  role : string;  (** Always ["user"] for user messages. *)
  content : user_content list;
      (** Ordered content blocks that make up this message. *)
}
(** A user message in the conversation history. *)

val equal_user_message : user_message -> user_message -> bool
val pp_user_message : Format.formatter -> user_message -> unit
val show_user_message : user_message -> string

(** Why the model stopped generating. *)
type stop_reason =
  | EndTurn  (** The model finished normally. *)
  | ToolUse  (** The model stopped to issue one or more tool calls. *)
  | MaxTokens  (** The generation was cut short by the token limit. *)
  | StopSequence  (** A configured stop sequence was encountered. *)
  | Error  (** The provider returned an error during generation. *)
  | Aborted  (** The in-progress stream was cancelled by the caller. *)

val equal_stop_reason : stop_reason -> stop_reason -> bool
val pp_stop_reason : Format.formatter -> stop_reason -> unit
val show_stop_reason : stop_reason -> string

type usage = {
  input_tokens : int;
  output_tokens : int;
  cache_read_tokens : int;
  cache_write_tokens : int;
  cost_usd : Decimal.t option;
      (** Estimated cost in US dollars; [None] if the provider does not report
          it. Serialised as a JSON string via [Decimal.to_string]. *)
}
(** Token usage and cost for a single LLM call. *)

val equal_usage : usage -> usage -> bool
val pp_usage : Format.formatter -> usage -> unit
val show_usage : usage -> string

type provenance = {
  api : string;
      (** Provider API identifier, e.g. ["anthropic"] or ["openai-completions"].
      *)
  provider : string;  (** Human-readable provider name. *)
  model : string;  (** Model identifier as given to the API. *)
  error_message : string option;
      (** Set when [stop_reason = Error]; carries the provider error text. *)
}
(** Identifies which provider and model produced a message. *)

val equal_provenance : provenance -> provenance -> bool
val pp_provenance : Format.formatter -> provenance -> unit
val show_provenance : provenance -> string

type assistant_message = {
  content : assistant_content list;
  stop_reason : stop_reason;
  provenance : provenance;
  usage : usage;
}
(** A complete assistant message, including all content blocks and metadata.
    This is both the terminal result of a stream and the snapshot type carried
    in each [assistant_message_event]. *)

val equal_assistant_message : assistant_message -> assistant_message -> bool
val pp_assistant_message : Format.formatter -> assistant_message -> unit
val show_assistant_message : assistant_message -> string

(** {1 Streaming events} *)

(** Fine-grained events emitted by the provider layer while streaming an
    assistant response. Every variant carries a [partial] field — an immutable
    snapshot of the [assistant_message] as it stands at the moment of emission.
    Consumers that only want the final message wait for [AME_done]; consumers
    rendering live UI read the [partial] field of each event.

    Invariant: [partial] in consecutive events reflects strictly increasing
    progress — no variant may carry a [partial] that is identical to the
    previous event's [partial] if content was produced. *)
type assistant_message_event =
  | AME_text_start of { partial : assistant_message }
      (** A new text content block has begun. *)
  | AME_text_delta of { text : string; partial : assistant_message }
      (** A fragment of text has arrived; [text] is the fragment. *)
  | AME_thinking_start of { partial : assistant_message }
      (** A new thinking content block has begun. *)
  | AME_thinking_delta of { text : string; partial : assistant_message }
      (** A fragment of thinking text; [text] is the fragment. *)
  | AME_tool_call_start of {
      index : int;
      id : string;
      name : string;
      partial : assistant_message;
    }
      (** A new tool-call block has begun; [index] is the block's position in
          the content list, [id] and [name] are the call's identifiers. *)
  | AME_tool_call_delta of {
      index : int;
      arguments_fragment : string;
      partial : assistant_message;
    }  (** A raw JSON fragment for the tool call at [index] has arrived. *)
  | AME_tool_call_end of { index : int; partial : assistant_message }
      (** The tool call at [index] is complete; arguments have been parsed. *)
  | AME_done of { message : assistant_message }
      (** The stream has ended successfully. [message] is the final, complete
          [assistant_message]. *)
  | AME_error of { message : string; partial : assistant_message }
      (** The stream ended with an error. [message] describes the failure;
          [partial] is the last available snapshot. *)

val equal_assistant_message_event :
  assistant_message_event -> assistant_message_event -> bool

val pp_assistant_message_event :
  Format.formatter -> assistant_message_event -> unit

val show_assistant_message_event : assistant_message_event -> string

(** {1 Error types} *)

(** Failure codes for filesystem operations. *)
type file_error_code =
  | NotFound
  | PermissionDenied
  | Timeout
  | Aborted
  | Unknown

val equal_file_error_code : file_error_code -> file_error_code -> bool
val pp_file_error_code : Format.formatter -> file_error_code -> unit
val show_file_error_code : file_error_code -> string

type file_error = { code : file_error_code; path : string; message : string }
(** A filesystem operation error. *)

val equal_file_error : file_error -> file_error -> bool
val pp_file_error : Format.formatter -> file_error -> unit
val show_file_error : file_error -> string

(** Failure codes for shell execution. *)
type execution_error_code = Timeout | Aborted | NonZeroExit | Unknown

val equal_execution_error_code :
  execution_error_code -> execution_error_code -> bool

val pp_execution_error_code : Format.formatter -> execution_error_code -> unit
val show_execution_error_code : execution_error_code -> string

type execution_error = { code : execution_error_code; message : string }
(** A shell execution error. *)

val equal_execution_error : execution_error -> execution_error -> bool
val pp_execution_error : Format.formatter -> execution_error -> unit
val show_execution_error : execution_error -> string

type tool_error = {
  message : string;
  is_user_error : bool;
      (** [true] when the error is attributable to invalid LLM-provided
          arguments; [false] when the tool itself failed for an internal reason.
      *)
}
(** An error returned by a tool execution (runtime failure or schema violation).
*)

val equal_tool_error : tool_error -> tool_error -> bool
val pp_tool_error : Format.formatter -> tool_error -> unit
val show_tool_error : tool_error -> string

(** {1 Model} *)

type model = {
  id : string;
      (** Model identifier as given to the API, e.g. ["claude-sonnet-4-5"]. *)
  api : string;
      (** API family, e.g. ["anthropic"] or ["openai-completions"]. *)
  context_window : int;
      (** Input context window in tokens for this model variant.

          This is per-instance metadata because the [id]+[api] pair does not
          uniquely determine the window: Claude 4.x families ship both 200K and
          1M variants with the same id prefix, and ["openai-completions"] is a
          protocol that covers everything from 4K local llamas to 256K
          DeepSeek/Qwen. Whoever constructs the record knows which variant they
          picked; they must record its window here. Consumed by
          {!Pera_core.Model_window} to compute the autonomous-compaction trigger
          threshold. *)
}
(** Identifies an LLM model and the API used to reach it. *)

val equal_model : model -> model -> bool
val pp_model : Format.formatter -> model -> unit
val show_model : model -> string
