(** S-expression types for [config.sexp]. *)

(** How the API key is sourced. *)
type api_key_source = Key of string | File of string | Command of string list
[@@deriving sexp, show, eq]

(** Effort level for extended thinking. *)
type effort = Low | Medium | High [@@deriving sexp, show, eq]

(** Cache policy for prompt caching. *)
type cache_policy = No_cache | Conversation | System_and_tools
[@@deriving sexp, show, eq]

(** Cache TTL. *)
type cache_ttl = Five_minutes | One_hour [@@deriving sexp, show, eq]

type model_auth = {
  name : string;  (** Unqualified model name within this provider. *)
  effort : effort option; [@sexp.option]
      (** Override the global or system-default effort for this model. *)
}
[@@deriving sexp, show, eq]
(** Per-model effort override within a provider_auth entry. *)

type provider_auth = {
  name : string;  (** Must match a [Models_config.provider_spec.name]. *)
  api_key : api_key_source option; [@sexp.option]
  api : string option; [@sexp.option]
      (** Override the provider's [api] (base URL) for this user/project. *)
  models : model_auth list; [@sexp.default []]
      (** Per-model effort overrides for this provider. *)
}
[@@deriving sexp, show, eq]
(** Auth and personal overrides for a named provider. User config: [api_key]
    accepted. Project config: [api_key] rejected (loud error); [api] allowed. *)

type cache_config = {
  policy : cache_policy option; [@sexp.option]
  ttl : cache_ttl option; [@sexp.option]
}
[@@deriving sexp, show, eq]
(** Cache configuration. *)

type session_config = { dir : string option [@sexp.option] }
[@@deriving sexp, show, eq]
(** Session configuration. *)

type compaction_config = {
  enabled : bool option; [@sexp.option]
  threshold : int option; [@sexp.option]
  tail : int option; [@sexp.option]
}
[@@deriving sexp, show, eq]
(** Compaction configuration. *)

type output_config = {
  plain : bool option; [@sexp.option]
  show_thinking : bool option; [@sexp.option]
  quiet : bool option; [@sexp.option]
}
[@@deriving sexp, show, eq]
(** Output configuration. *)

type command_def = {
  name : string;  (** Invoked as [/<name>]. *)
  description : string;  (** Shown in [/info] output. *)
  template : string;
      (** Injected as a user message. Supports [{args}], [{1}], [{2}], ... *)
}
[@@deriving sexp, show, eq]
(** A user-defined slash command. *)

(** Shell-backed tool argument type. *)
type shell_arg_type =
  | String of { description : string }
  | Int of {
      description : string;
      min : int option; [@sexp.option]
      max : int option; [@sexp.option]
    }
[@@deriving sexp, show, eq]

type shell_arg = { name : string; arg_type : shell_arg_type }
[@@deriving sexp, show, eq]
(** A shell argument definition. *)

type shell_tool_def = {
  name : string;
  description : string;
  command : string;  (** Template string; [{arg_name}] is substituted. *)
  parallel_safe : bool;
  args : shell_arg list; [@sexp.default []]
}
[@@deriving sexp, show, eq]
(** A config-defined shell-backed tool. *)

(** MCP server transport. *)
type mcp_transport =
  | Stdio of { command : string list }
  | Http of { url : string }
[@@deriving sexp, show, eq]

type mcp_server_def = { name : string; transport : mcp_transport }
[@@deriving sexp, show, eq]
(** An MCP server definition. *)

type config = {
  providers : provider_auth list; [@sexp.default []]
      (** Auth and overrides for named providers. *)
  default_model : string option; [@sexp.option]
      (** Fully-qualified model when [--model] is not given. *)
  effort : effort option; [@sexp.option]
      (** Global default effort. Per-model setting in providers takes
          precedence. *)
  max_tokens : int option; [@sexp.option]
      (** Override [model_spec.max_tokens] for this config tier. *)
  cache : cache_config option; [@sexp.option]
  session : session_config option; [@sexp.option]
  compaction : compaction_config option; [@sexp.option]
  output : output_config option; [@sexp.option]
  commands : command_def list; [@sexp.default []]
      (** User-defined slash commands. *)
  tools : shell_tool_def list; [@sexp.default []]
      (** Config-defined shell-backed tools. *)
  mcp_servers : mcp_server_def list; [@sexp.default []]
      (** MCP server definitions. *)
}
[@@deriving sexp, show, eq]
(** Top-level user/project config. *)
