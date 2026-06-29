(** CLI argument parsing via Cmdliner. *)

type parsed_args = {
  model : string option;
  api_key : string option;
  api_key_file : string option;
  api_key_command : string option;  (** Space-separated argv string. *)
  effort : Pera_config.effort option;
  max_tokens : int option;
  cache_policy : Pera_config.cache_policy option;
  cache_ttl : Pera_config.cache_ttl option;
  session : string option;
  session_dir : string option;
  cwd : string option;
  system : string option;
  system_file : string option;
  no_compact : bool;
  compact_threshold : int option;
  compact_tail : int option;
  show_thinking : bool;
  quiet : bool;
  json : bool;
}

val effort_conv : Pera_config.effort Cmdliner.Arg.conv
(** Cmdliner converter for effort values ([low|medium|high]). *)

val cache_policy_conv : Pera_config.cache_policy Cmdliner.Arg.conv
(** Cmdliner converter for cache policy values. *)

val cache_ttl_conv : Pera_config.cache_ttl Cmdliner.Arg.conv
(** Cmdliner converter for cache TTL values. *)

val parse : argv:string array -> parsed_args
(** Parse [argv] via Cmdliner. Exits non-zero on bad args. [--system] and
    [--system-file] are mutually exclusive. Multiple API key flags are mutually
    exclusive. *)

val to_partial_config : parsed_args -> Pera_config.config
(** Convert parsed CLI args to a partial [Pera_config.config] for merging. API
    key flags are not placed into the config here — they are handled separately
    by [Config_resolver]. *)
