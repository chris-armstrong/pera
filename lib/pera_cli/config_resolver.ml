open Containers

type resolved_config = {
  model : Pera_types.Types.model;
  provider_spec : Models_config.provider_spec;
  api_key_source : Pera_config.api_key_source option;
  max_tokens : int;
  thinking_budget_tokens : int option;
  cache_policy : Pera_config.cache_policy;
  cache_ttl : Pera_config.cache_ttl;
  session_dir : string;
  session_override : string option;
  cwd : string;
  system_prompt : string option;
  system_file : string option;
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
  home : string;
}

let built_in_defaults : Pera_config.config =
  {
    providers = [];
    default_model = None;
    effort = Some Pera_config.Low;
    max_tokens = None;
    cache =
      Some
        {
          policy = Some Pera_config.No_cache;
          ttl = Some Pera_config.Five_minutes;
        };
    session = None;
    compaction =
      Some { enabled = Some true; threshold = Some 70; tail = Some 4 };
    output =
      Some
        { plain = Some false; show_thinking = Some false; quiet = Some false };
    commands = [];
    tools = [];
    mcp_servers = [];
  }

let empty_config : Pera_config.config =
  {
    providers = [];
    default_model = None;
    effort = None;
    max_tokens = None;
    cache = None;
    session = None;
    compaction = None;
    output = None;
    commands = [];
    tools = [];
    mcp_servers = [];
  }

let resolve_api_key_source ~parsed_args ~merged ~provider_spec ~getenv_opt =
  let from_cli =
    match
      ( parsed_args.Cli_args.api_key,
        parsed_args.Cli_args.api_key_file,
        parsed_args.Cli_args.api_key_command )
    with
    | Some k, None, None -> Some (Pera_config.Key k)
    | None, Some f, None -> Some (Pera_config.File f)
    | None, None, Some cmd ->
        Some
          (Pera_config.Command
             (String.split_on_char ' ' cmd
             |> List.filter (fun s -> not (String.is_empty s))))
    | None, None, None -> None
    | _ -> None
  in
  match from_cli with
  | Some src -> Some src
  | None -> (
      match Env_reader.read_api_key_override ~getenv_opt with
      | Ok (AK_key k) -> Some (Pera_config.Key k)
      | Ok (AK_file f) -> Some (Pera_config.File f)
      | Ok (AK_command argv) -> Some (Pera_config.Command argv)
      | Ok AK_none | Error _ -> (
          let provider_name = provider_spec.Models_config.name in
          let provider_auth =
            List.find_opt
              (fun (p : Pera_config.provider_auth) ->
                String.equal p.name provider_name)
              merged.Pera_config.providers
          in
          match
            Option.flat_map
              (fun (p : Pera_config.provider_auth) -> p.api_key)
              provider_auth
          with
          | Some src -> Some src
          | None -> (
              match
                List.find_map
                  (fun env_var ->
                     match getenv_opt env_var with
                     | Some k -> Some (Pera_config.Key k)
                     | None -> None)
                  provider_spec.Models_config.api_key_env
              with
              | Some key -> Some key
              | None -> None)))

let resolve_compaction ~merged ~model_spec =
  match merged.Pera_config.compaction with
  | None -> None
  | Some cc -> (
      match cc.Pera_config.enabled with
      | Some false -> None
      | _ ->
          let threshold = Option.get_or ~default:70 cc.Pera_config.threshold in
          let tail = Option.get_or ~default:4 cc.Pera_config.tail in
          let trigger_tokens =
            model_spec.Models_config.context_window * threshold / 100
          in
          Some Pera_agent.Agent_harness.{ trigger_tokens; tail_size = tail })

let resolve_output ~merged =
  Option.get_or
    ~default:Pera_config.{ plain = None; show_thinking = None; quiet = None }
    merged.Pera_config.output

let resolve_system_prompt ~parsed_args =
  match parsed_args.Cli_args.system with
  | Some s -> (Some s, None)
  | None -> (None, parsed_args.Cli_args.system_file)

let resolve inputs =
  let open Result.Syntax in
  let* env_partial =
    Env_reader.read_partial_config ~getenv_opt:inputs.getenv_opt
  in
  let merged =
    List.fold_left
      (fun base overlay -> Config_loader.merge ~base ~overlay)
      built_in_defaults
      [
        Option.get_or ~default:empty_config inputs.user_config;
        Option.get_or ~default:empty_config inputs.project_config;
        env_partial;
        Cli_args.to_partial_config inputs.parsed_args;
      ]
  in
  let* model_name =
    match merged.Pera_config.default_model with
    | Some m -> Ok m
    | None ->
        Error
          "[pera] no model specified — use --model PROVIDER/MODEL or set \
           default_model in config"
  in
  let* provider_spec, model_spec =
    Models_loader.resolve_model inputs.models_file model_name
  in
  let effort =
    Option.get_or ~default:Pera_config.Low merged.Pera_config.effort
  in
  let* thinking_budget_tokens = Effort_resolver.resolve ~effort ~model_spec in
  let max_tokens =
    Option.get_or ~default:model_spec.Models_config.max_tokens
      merged.Pera_config.max_tokens
  in
  let cache_policy =
    Option.flat_map (fun c -> c.Pera_config.policy) merged.Pera_config.cache
    |> Option.get_or ~default:Pera_config.No_cache
  in
  let cache_ttl =
    Option.flat_map (fun c -> c.Pera_config.ttl) merged.Pera_config.cache
    |> Option.get_or ~default:Pera_config.Five_minutes
  in
  let session_dir =
    match merged.Pera_config.session with
    | Some { dir = Some d } -> d
    | _ -> Session_path.default_session_dir inputs.home
  in
  let cwd =
    match inputs.parsed_args.Cli_args.cwd with
    | Some d -> d
    | None -> (
        match inputs.getenv_opt "PERA_CWD" with
        | Some d -> d
        | None -> Sys.getcwd ())
  in
  let system_prompt, system_file =
    resolve_system_prompt ~parsed_args:inputs.parsed_args
  in
  let compaction = resolve_compaction ~merged ~model_spec in
  let output = resolve_output ~merged in
  let api_key_source =
    resolve_api_key_source ~parsed_args:inputs.parsed_args ~merged
      ~provider_spec ~getenv_opt:inputs.getenv_opt
  in
  let model =
    Pera_types.Types.
      {
        id = model_spec.Models_config.name;
        protocol = provider_spec.Models_config.protocol;
        context_window = model_spec.Models_config.context_window;
      }
  in
  Ok
    {
      model;
      provider_spec;
      api_key_source;
      max_tokens;
      thinking_budget_tokens;
      cache_policy;
      cache_ttl;
      session_dir;
      session_override = inputs.parsed_args.Cli_args.session;
      cwd;
      system_prompt;
      system_file;
      compaction;
      output;
      tools = merged.Pera_config.tools;
      commands = merged.Pera_config.commands;
      mcp_servers = merged.Pera_config.mcp_servers;
      json_output = inputs.parsed_args.Cli_args.json;
      verbose = inputs.parsed_args.Cli_args.verbose;
    }
