open Containers

module Resolved_inputs = struct
  type t = Config_resolver.resolve_inputs
end

module type Env = sig
  type ctx = (module Pera_env.Execution_env.S)

  val create : env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> cwd:string -> ctx

  val tools :
    ctx -> (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool list

  val has_shell : bool
  val getenv_opt : string -> string option
  val home : unit -> string
  val secure_random : env:Eio_unix.Stdenv.base -> bytes -> unit
  val stdin_isatty : env:Eio_unix.Stdenv.base -> bool
end

module Make (Cli_env : Env) = struct
  let or_die = function
    | Ok x -> x
    | Error e ->
        Printf.eprintf "%s\n%!" e;
        exit 1

  let to_cache_policy = function
    | Pera_config.No_cache -> Pera_types.Types.No_cache
    | Pera_config.Conversation -> Pera_types.Types.Conversation
    | Pera_config.System_and_tools -> Pera_types.Types.SystemAndToolsOnly

  let to_cache_ttl = function
    | Pera_config.Five_minutes -> Pera_types.Types.Five_minutes
    | Pera_config.One_hour -> Pera_types.Types.One_hour

  let read_key_file ~env ~sw:_ path =
    let eio_path = Eio.Path.(Eio.Stdenv.fs env / path) in
    match Eio.Path.load eio_path with
    | content -> String.trim content
    | exception exn ->
        let msg = Printexc.to_string exn in
        Printf.eprintf "[pera] failed to read API key file %S: %s\n%!" path msg;
        exit 1

  let read_system_file ~env path =
    let eio_path = Eio.Path.(Eio.Stdenv.fs env / path) in
    match Eio.Path.load eio_path with
    | content -> String.trim content
    | exception exn ->
        let msg = Printexc.to_string exn in
        Printf.eprintf "[pera] failed to read system file %S: %s\n%!" path msg;
        exit 1

  let run_key_command ~env ~sw argv =
    let module E = (val Cli_env.create ~env ~sw ~cwd:(Sys.getcwd ())) in
    let cmd = String.concat " " (List.map Filename.quote argv) in
    Eio.Cancel.sub (fun cancel ->
        match
          E.Sh.exec ~command:cmd
            ?cwd:(None : string option)
            ?env:(None : (string * string) list option)
            ?timeout:(Some 30.0 : float option)
            ?on_stdout:(None : (string -> unit) option)
            ?on_stderr:(None : (string -> unit) option)
            ~sw ~cancel
        with
        | Ok result ->
            if Int.equal result.Pera_env.Execution_env.exit_code 0 then
              String.trim result.Pera_env.Execution_env.stdout
            else
              let msg = result.Pera_env.Execution_env.stderr in
              Printf.eprintf "[pera] API key command failed: %s\n%!" msg;
              exit 1
        | Error e ->
            Printf.eprintf "[pera] API key command error: %s\n%!"
              e.Pera_types.Types.message;
            exit 1)

  let materialise_api_key ~env ~sw = function
    | Pera_config.Key k -> k
    | Pera_config.File p -> read_key_file ~env ~sw p
    | Pera_config.Command argv -> run_key_command ~env ~sw argv

  let build_registry () =
    let open Pera_connector in
    let r = Connector_registry.empty in
    let r =
      Connector_registry.register r ~name:"anthropic"
        (module Anthropic_connector)
    in
    Connector_registry.register r ~name:"openai-completions"
      (module Openai_completions_connector)

  let build_stream_fn ~env ~sw ~api_key ~protocol =
    let registry = build_registry () in
    let api_keys = [ (protocol, api_key) ] in
    let adapter =
      Pera_core.Connector_adapter.create ~registry ~api_keys ~env ~sw
    in
    Pera_core.Connector_adapter.stream_fn adapter

  let run_interactive ~commands ~stdin_isatty ~send ~info_stats ~compact_fn ~env
      =
    let stdin_src = Eio.Stdenv.stdin env in
    let read_line () =
      match Eio.Buf_read.parse ~max_size:65536 Eio.Buf_read.line stdin_src with
      | Ok s -> s
      | Error _ -> raise End_of_file
    in
    let rec tty_loop () =
      match read_line () with
      | exception End_of_file -> ()
      | line -> (
          let trimmed = String.trim line in
          if String.is_empty trimmed then tty_loop ()
          else
            match Input_loop.parse_line ~commands trimmed with
            | Send text ->
                if not (String.is_empty text) then send text;
                tty_loop ()
            | Compact ->
                compact_fn ();
                tty_loop ()
            | Info ->
                print_endline (info_stats ());
                tty_loop ()
            | Quit -> ()
            | Error msg ->
                print_endline msg;
                tty_loop ())
    in
    let rec pipe_loop () =
      match read_line () with
      | exception End_of_file -> ()
      | text ->
          let trimmed = String.trim text in
          if not (String.is_empty trimmed) then send trimmed;
          pipe_loop ()
    in
    if Input_loop.is_tty ~stdin_isatty then tty_loop () else pipe_loop ()

  let run_with ?stream_fn inputs =
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let rc = Config_resolver.resolve inputs |> or_die in
            let api_key =
              match rc.Config_resolver.api_key_source with
              | None ->
                  Printf.eprintf "[pera] no API key configured\n%!";
                  exit 1
              | Some src -> materialise_api_key ~env ~sw src
            in
            let stream_fn =
              match stream_fn with
              | Some fn -> fn
              | None ->
                  build_stream_fn ~env ~sw ~api_key
                    ~protocol:
                      rc.Config_resolver.provider_spec.Models_config.protocol
            in
            let cwd =
              match rc.Config_resolver.cwd with "" -> Sys.getcwd () | d -> d
            in
            let ctx = Cli_env.create ~env ~sw ~cwd in
            let shell_tools =
              if Cli_env.has_shell then (
                match Shell_tool_builder.build_all rc.Config_resolver.tools with
                | Ok tools -> tools
                | Error (Shell_tool_builder.Unknown_placeholder name) ->
                    Printf.eprintf
                      "[pera] shell tool error: unknown placeholder {%s}\n%!"
                      name;
                    exit 1)
              else begin
                if not (List.is_empty rc.Config_resolver.tools) then
                  Printf.eprintf
                    "[pera] warning: shell tools defined but env has no shell\n\
                     %!";
                []
              end
            in
            if not (List.is_empty rc.Config_resolver.mcp_servers) then
              Printf.eprintf "[pera] MCP servers not yet supported\n%!";
            let system_prompt =
              match rc.Config_resolver.system_prompt with
              | Some s -> s
              | None -> (
                  match rc.Config_resolver.system_file with
                  | None -> Pera_agent.Agent_harness.default_system_prompt
                  | Some path -> read_system_file ~env path)
            in
            let session_path =
              Session_path.resolve
                ~session_override:rc.Config_resolver.session_override
                ~session_dir:rc.Config_resolver.session_dir
                ~secure_random:(Cli_env.secure_random ~env)
                ~clock:(Eio.Stdenv.clock env)
            in
            let harness_config : Pera_agent.Agent_harness.config =
              {
                cwd;
                model = rc.Config_resolver.model;
                session_path;
                stream_fn;
                max_tokens = rc.Config_resolver.max_tokens;
                exec_env = ctx;
                system_prompt;
                thinking_budget_tokens =
                  rc.Config_resolver.thinking_budget_tokens;
                cache_policy =
                  to_cache_policy rc.Config_resolver.cache_policy;
                cache_ttl = to_cache_ttl rc.Config_resolver.cache_ttl;
                extra_tools = shell_tools;
                compaction = rc.Config_resolver.compaction;
              }
            in
            let harness =
              match
                Pera_agent.Agent_harness.create ~config:harness_config ~env ~sw
              with
              | Ok h -> h
              | Error e ->
                  Printf.eprintf "[pera] session error: %s\n%!"
                    e.Pera_types.Types.message;
                  exit 1
            in
            let renderer =
              Event_renderer.create ~output:rc.Config_resolver.output
                ~json:rc.Config_resolver.json_output
            in
            let _unsub =
              Pera_agent.Agent_harness.subscribe harness (fun event ->
                  let lines = Event_renderer.render renderer event in
                  List.iter
                    (fun line ->
                      print_string line;
                      flush stdout)
                    lines)
            in
            run_interactive ~commands:rc.Config_resolver.commands
              ~stdin_isatty:(Cli_env.stdin_isatty ~env)
              ~send:(Pera_agent.Agent_harness.send harness)
              ~info_stats:(fun () -> Event_renderer.stats renderer)
              ~compact_fn:(fun () ->
                Printf.eprintf "[pera] /compact not yet wired\n%!")
              ~env))

  let run () =
    let parsed_args = Cli_args.parse ~argv:Sys.argv in
    let xdg = Xdg.create ~env:Cli_env.getenv_opt () in
    let models_file =
      let packaged_path =
        let bin_dir = Fpath.parent (Fpath.v Sys.executable_name) in
        let candidates =
          let from_env =
            match Cli_env.getenv_opt "PERA_DATA_DIR" with
            | Some dir -> [ Fpath.(v dir / "models.sexp") |> Fpath.to_string ]
            | None -> []
          in
          let from_bin =
            Fpath.(normalize (bin_dir / ".." / "share" / "pera-cli" / "models.sexp"))
            |> Fpath.to_string
          in
          let from_xdg =
            let dirs =
              match Cli_env.getenv_opt "XDG_DATA_DIRS" with
              | Some s -> String.split_on_char ':' s |> List.filter (fun s -> not (String.is_empty s))
              | None -> [ "/usr/local/share"; "/usr/share" ]
            in
            List.map (fun d ->
                Fpath.(v d / "pera" / "models.sexp") |> Fpath.to_string)
              dirs
          in
          from_env @ [ from_bin ] @ from_xdg
        in
        match List.find_opt Sys.file_exists candidates with
        | Some p -> p
        | None ->
            Printf.eprintf "[pera] could not locate packaged models.sexp\n%!";
            exit 1
      in
      let user_path =
        let p =
          Fpath.(v (Xdg.config_dir xdg) / "pera" / "models.sexp")
          |> Fpath.to_string
        in
        if Sys.file_exists p then Some p else None
      in
      Models_loader.load ~packaged_path ~user_path |> or_die
    in
    let user_config =
      let path =
        Fpath.(v (Xdg.config_dir xdg) / "pera" / "config.sexp")
        |> Fpath.to_string
      in
      match Config_loader.load_user_config ~path with
      | Ok c -> c
      | Error (Config_loader.Parse_error msg) ->
          Printf.eprintf "[pera] config error: %s\n%!" msg;
          exit 1
      | Error Config_loader.Api_key_in_project_config -> None
    in
    let project_config =
      let cwd =
        Option.get_or ~default:(Sys.getcwd ()) parsed_args.Cli_args.cwd
      in
      match Config_loader.find_project_config ~cwd with
      | Some path -> (
          match Config_loader.load_project_config ~path with
          | Ok c -> c
          | Error (Config_loader.Parse_error msg) ->
              Printf.eprintf "[pera] project config error: %s\n%!" msg;
              exit 1
          | Error Config_loader.Api_key_in_project_config ->
              Printf.eprintf
                "[pera] api_key is not allowed in project config (.pera)\n%!";
              exit 1)
      | None -> None
    in
    run_with
      {
        Config_resolver.parsed_args;
        models_file;
        user_config;
        project_config;
        getenv_opt = Cli_env.getenv_opt;
        home = Cli_env.home ();
      }
end

(* Re-export internal modules so they are accessible to tests and external
   consumers via [Pera_cli.Module_name]. *)
module Cli_args = Cli_args
module Config_loader = Config_loader
module Config_resolver = Config_resolver
module Effort_resolver = Effort_resolver
module Env_reader = Env_reader
module Event_renderer = Event_renderer
module Input_loop = Input_loop
module Models_config = Models_config
module Models_loader = Models_loader
module Pera_config = Pera_config
module Session_path = Session_path
module Shell_tool_builder = Shell_tool_builder
