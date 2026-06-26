(** Pure config resolution layer.

    [resolve] merges all config tiers into a single [resolved_config]. It is a
    pure function: no filesystem I/O, no [Sys.getenv_opt] calls — all external
    data is injected via [resolve_inputs]. *)

type resolved_config = {
  model : Pera_types.Types.model;
  provider_spec : Models_config.provider_spec;
  api_key_source : Pera_config.api_key_source option;
      (** Concrete key source — [Key], [File], or [Command]. [None] means no key
          found; the caller errors on stream construction. *)
  max_tokens : int;
  thinking_budget_tokens : int option;
  cache_policy : Pera_config.cache_policy;
  cache_ttl : Pera_config.cache_ttl;
  session_dir : string;
      (** Directory for session files. The caller generates the final filename
          via [Session_path.resolve]. *)
  session_override : string option;
      (** Explicit session file path from [--session] / [PERA_SESSION]. *)
  cwd : string;
  system_prompt : string option;  (** [None] = use built-in default. *)
  compaction : Pera_agent.Agent_harness.compaction_config option;
  output : Pera_config.output_config;
  tools : Pera_config.shell_tool_def list;
  commands : Pera_config.command_def list;
  mcp_servers : Pera_config.mcp_server_def list;
  json_output : bool;
  verbose : bool;
}

type resolve_inputs = {
  parsed_args : Cli_args.parsed_args;
  models_file : Models_config.models_file;
  user_config : Pera_config.config option;
  project_config : Pera_config.config option;
  getenv_opt : string -> string option;
  home : string;  (** For default session dir computation. *)
}

val resolve : resolve_inputs -> (resolved_config, string) result
(** Pure. Merge config tiers in priority order (lowest first): built-in defaults
    → user config → project config → env vars → CLI flags. Validates the merged
    config and produces a [resolved_config]. *)
