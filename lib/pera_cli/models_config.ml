open Containers
open Sexplib.Conv

type thinking_spec = {
  budget_medium : int;
  budget_high   : int;
} [@@deriving sexp, show, eq]

type compat_config = {
  reasoning_field          : string option [@sexp.option];
  max_tokens_field         : string option [@sexp.option];
  require_tool_result_name : bool   option [@sexp.option];
  enable_thinking_field    : string option [@sexp.option];
} [@@deriving sexp, show, eq]

type model_spec = {
  name           : string;
  context_window : int;
  max_tokens     : int;
  thinking       : thinking_spec option [@sexp.option];
} [@@deriving sexp, show, eq]

type provider_spec = {
  name         : string;
  api          : string;
  api_key_env  : string option [@sexp.option];
  base_url     : string option [@sexp.option];
  base_url_env : string option [@sexp.option];
  compat       : compat_config option [@sexp.option];
  models       : model_spec list [@sexp.default []];
} [@@deriving sexp, show, eq]

type models_file = {
  providers : provider_spec list [@sexp.default []];
} [@@deriving sexp, show, eq]
