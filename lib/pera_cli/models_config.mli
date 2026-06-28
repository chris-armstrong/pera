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

type decimal = Decimal.t
(** Alias so [ppx_sexp_conv] resolves [decimal_of_sexp] / [sexp_of_decimal] by
    name from the ambient scope. *)

type model_cost = {
  input_per_mtok : decimal;  (** USD cost per million input tokens. *)
  output_per_mtok : decimal;  (** USD cost per million output tokens. *)
  cache_read_per_mtok : decimal option;
      (** USD cost per million cache-read tokens. [None] if the provider does
          not charge for cache reads. *)
  cache_write_per_mtok : decimal option;
      (** USD cost per million cache-write tokens. [None] if the provider does
          not charge for cache writes. *)
}
[@@deriving sexp, show, eq]
(** USD pricing for a model, per million tokens. Stored as [Decimal.t] via
    custom converters ([decimal_of_sexp] / [sexp_of_decimal]) that represent
    each value as a quoted string atom, e.g. [(input_per_mtok "3.00")]. Absent
    cost record = cost unknown/not applicable (e.g. local models). *)

type model_spec = {
  name : string;
  context_window : int;
  max_tokens : int;
  thinking : thinking_spec option;
  cost : model_cost option;
}
[@@deriving sexp, show, eq]
(** Specification for a single model.
    - [name]: model identifier (e.g. "claude-sonnet-4-6").
    - [context_window]: maximum context window size in tokens.
    - [max_tokens]: maximum output tokens.
    - [thinking]: optional thinking budget spec. [None] means no thinking
      support.
    - [cost]: optional USD pricing per million tokens. [None] means unknown or
      not applicable. *)

type provider_spec = {
  name : string;
  protocol : string;
  api_key_env : string list;
  api : string option;
  api_env : string option;
  compat : compat_config option;
  models : model_spec list;
}
[@@deriving sexp, show, eq]
(** Specification for a provider.
    - [name]: provider name (e.g. "anthropic").
    - [protocol]: connector type ("anthropic" | "openai-completions").
    - [api_key_env]: env var names to try in order for the API key.
    - [api]: base URL override. [None] = connector's built-in default.
    - [api_env]: env var whose value, if set at runtime, overrides [api].
    - [compat]: optional compatibility config.
    - [models]: list of model specs. *)

type models_file = { providers : provider_spec list }
[@@deriving sexp, show, eq]
(** Top-level models file structure. *)
