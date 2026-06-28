open Containers
open Sexplib.Conv

type decimal = Decimal.t

let decimal_of_sexp s = Decimal.of_string (Sexplib.Conv.string_of_sexp s)
let sexp_of_decimal d = Sexplib.Conv.sexp_of_string (Decimal.to_string d)
let pp_decimal fmt d = Format.pp_print_string fmt (Decimal.to_string d)
let equal_decimal a b = Decimal.equal a b

type thinking_spec = {
  budget_medium : int; [@sexp.default 8_000]
  budget_high : int; [@sexp.default 32_000]
}
[@@deriving sexp, show, eq]

type compat_config = {
  reasoning_field : string option; [@sexp.option]
  max_tokens_field : string option; [@sexp.option]
  require_tool_result_name : bool option; [@sexp.option]
  enable_thinking_field : string option; [@sexp.option]
}
[@@deriving sexp, show, eq]

type model_cost = {
  input_per_mtok : decimal;
  output_per_mtok : decimal;
  cache_read_per_mtok : decimal option; [@sexp.option]
  cache_write_per_mtok : decimal option; [@sexp.option]
}
[@@deriving sexp, show, eq]

type model_spec = {
  name : string;
  context_window : int;
  max_tokens : int;
  thinking : thinking_spec option; [@sexp.option]
  cost : model_cost option; [@sexp.option]
}
[@@deriving sexp, show, eq]

type provider_spec = {
  name : string;
  protocol : string;
  api_key_env : string list; [@sexp.default []]
  api : string option; [@sexp.option]
  base_url_env : string option; [@sexp.option]
  compat : compat_config option; [@sexp.option]
  models : model_spec list; [@sexp.default []]
}
[@@deriving sexp, show, eq]

type models_file = { providers : provider_spec list [@sexp.default []] }
[@@deriving sexp, show, eq]
