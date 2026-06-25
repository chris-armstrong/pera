(** S-expression types for [config.sexp]. *)

(** Source of an API key. *)
type api_key_source =
  | Key     of string
  | File    of string
  | Command of string list
[@@deriving sexp, show, eq]

(** Effort level for extended thinking. *)
type effort =
  | Low
  | Medium
  | High
[@@deriving sexp, show, eq]

(** Cache policy for prompt caching. *)
type cache_policy =
  | No_cache
  | Conversation
  | System_and_tools
[@@deriving sexp, show, eq]

(** Cache TTL in seconds. *)
type cache_ttl = int
[@@deriving sexp, show, eq]

(** Authentication config for a model. *)
type model_auth = {
  api_key : api_key_source option;
} [@@deriving sexp, show, eq]

(** Authentication config for a provider. *)
type provider_auth = {
  api_key : api_key_source option;
} [@@deriving sexp, show, eq]

(** Cache configuration. *)
type cache_config = {
  policy : cache_policy option;
  ttl    : cache_ttl option;
} [@@deriving sexp, show, eq]

(** Session configuration. *)
type session_config = {
  dir : string option;
} [@@deriving sexp, show, eq]

(** Compaction configuration. *)
type compaction_config = {
  enabled   : bool option;
  threshold : int option;
  tail      : int option;
} [@@deriving sexp, show, eq]

(** Output configuration. *)
type output_config = {
  plain         : bool option;
  show_thinking : bool option;
  quiet         : bool option;
} [@@deriving sexp, show, eq]

(** A named command definition. *)
type command_def = {
  name    : string;
  command : string list;
} [@@deriving sexp, show, eq]

(** Type of shell argument. *)
type shell_arg_type =
  | Single
  | Rest
[@@deriving sexp, show, eq]

(** A shell argument definition. *)
type shell_arg = {
  name        : string;
  arg_type    : shell_arg_type;
  description : string option;
} [@@deriving sexp, show, eq]

(** A shell tool definition. *)
type shell_tool_def = {
  name        : string;
  description : string;
  command     : string;
  args        : shell_arg list;
} [@@deriving sexp, show, eq]

(** MCP transport type. *)
type mcp_transport =
  | Stdio of string list
  | Sse   of string
[@@deriving sexp, show, eq]

(** An MCP server definition. *)
type mcp_server_def = {
  name      : string;
  transport : mcp_transport;
} [@@deriving sexp, show, eq]

(** Top-level user/project config. *)
type config = {
  default_model  : string option;
  effort         : effort option;
  max_tokens     : int option;
  cache          : cache_config option;
  session        : session_config option;
  compaction     : compaction_config option;
  output         : output_config option;
  commands       : command_def list;
  tools          : shell_tool_def list;
  mcp_servers    : mcp_server_def list;
  providers      : provider_auth list;
} [@@deriving sexp, show, eq]
