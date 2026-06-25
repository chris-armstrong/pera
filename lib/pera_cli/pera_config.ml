open Containers
open Sexplib.Conv

type api_key_source =
  | Key     of string
  | File    of string
  | Command of string list
[@@deriving sexp, show, eq]

type effort =
  | Low
  | Medium
  | High
[@@deriving sexp, show, eq]

type cache_policy =
  | No_cache
  | Conversation
  | System_and_tools
[@@deriving sexp, show, eq]

type cache_ttl = int
[@@deriving sexp, show, eq]

type model_auth = {
  api_key : api_key_source option [@sexp.option];
} [@@deriving sexp, show, eq]

type provider_auth = {
  api_key : api_key_source option [@sexp.option];
} [@@deriving sexp, show, eq]

type cache_config = {
  policy : cache_policy option [@sexp.option];
  ttl    : cache_ttl option [@sexp.option];
} [@@deriving sexp, show, eq]

type session_config = {
  dir : string option [@sexp.option];
} [@@deriving sexp, show, eq]

type compaction_config = {
  enabled   : bool option [@sexp.option];
  threshold : int option [@sexp.option];
  tail      : int option [@sexp.option];
} [@@deriving sexp, show, eq]

type output_config = {
  plain         : bool option [@sexp.option];
  show_thinking : bool option [@sexp.option];
  quiet         : bool option [@sexp.option];
} [@@deriving sexp, show, eq]

type command_def = {
  name    : string;
  command : string list;
} [@@deriving sexp, show, eq]

type shell_arg_type =
  | Single
  | Rest
[@@deriving sexp, show, eq]

type shell_arg = {
  name        : string;
  arg_type    : shell_arg_type;
  description : string option [@sexp.option];
} [@@deriving sexp, show, eq]

type shell_tool_def = {
  name        : string;
  description : string;
  command     : string;
  args        : shell_arg list [@sexp.default []];
} [@@deriving sexp, show, eq]

type mcp_transport =
  | Stdio of string list
  | Sse   of string
[@@deriving sexp, show, eq]

type mcp_server_def = {
  name      : string;
  transport : mcp_transport;
} [@@deriving sexp, show, eq]

type config = {
  default_model  : string option [@sexp.option];
  effort         : effort option [@sexp.option];
  max_tokens     : int option [@sexp.option];
  cache          : cache_config option [@sexp.option];
  session        : session_config option [@sexp.option];
  compaction     : compaction_config option [@sexp.option];
  output         : output_config option [@sexp.option];
  commands       : command_def list [@sexp.default []];
  tools          : shell_tool_def list [@sexp.default []];
  mcp_servers    : mcp_server_def list [@sexp.default []];
  providers      : provider_auth list [@sexp.default []];
} [@@deriving sexp, show, eq]
