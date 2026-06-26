(** S-expression types for [models.sexp]. *)

type thinking_spec = {
  budget_medium : int;  (** Default thinking budget for Medium effort. *)
  budget_high : int;  (** Default thinking budget for High effort. *)
}
[@@deriving sexp, show, eq]
(** Thinking budget configuration for a model.
    - [budget_medium]: token budget for Medium effort.
    - [budget_high]: token budget for High effort. *)

type compat_config = {
  reasoning_field : string option;
  max_tokens_field : string option;
  require_tool_result_name : bool option;
  enable_thinking_field : string option;
}
[@@deriving sexp, show, eq]
(** Compatibility configuration for provider-specific API fields. All fields are
    optional; [None] means the provider uses defaults. *)

type model_spec = {
  name : string;
  context_window : int;
  max_tokens : int;
  thinking : thinking_spec option;
}
[@@deriving sexp, show, eq]
(** Specification for a single model.
    - [name]: model identifier (e.g. "claude-sonnet-4-6").
    - [context_window]: maximum context window size in tokens.
    - [max_tokens]: maximum output tokens.
    - [thinking]: optional thinking budget spec. [None] means no thinking
      support. *)

type provider_spec = {
  name : string;
  api : string;
  api_key_env : string option;
  base_url : string option;
  base_url_env : string option;
  compat : compat_config option;
  models : model_spec list;
}
[@@deriving sexp, show, eq]
(** Specification for a provider.
    - [name]: provider name (e.g. "anthropic").
    - [api]: API type (e.g. "anthropic", "openai-completions").
    - [api_key_env]: environment variable name for the API key.
    - [base_url]: base URL override.
    - [base_url_env]: environment variable name for base URL override.
    - [compat]: optional compatibility config.
    - [models]: list of model specs. *)

type models_file = { providers : provider_spec list }
[@@deriving sexp, show, eq]
(** Top-level models file structure. *)
