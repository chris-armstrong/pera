open Containers

let log_src = Logs.Src.create "pera.cli" ~doc:"Pera CLI main loop"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* ── Config helpers ────────────────────────────────────────────────────── *)

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

(* Resolve inputs to a concrete config record; exits on failure. *)
let resolve_config inputs =
  Log.debug (fun f -> f "resolving configuration");
  Config_resolver.resolve inputs |> or_die

(* ── API key materialisation ───────────────────────────────────────────── *)

let read_key_file ~env ~sw:_ path =
  let eio_path = Eio.Path.(Eio.Stdenv.fs env / path) in
  match Eio.Path.load eio_path with
  | content -> String.trim content
  | exception exn ->
      let msg = Printexc.to_string exn in
      Printf.eprintf "[pera] failed to read API key file %S: %s\n%!" path msg;
      exit 1

let run_key_command ~env ~sw:_ argv =
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let run_once () =
    Eio.Switch.run (fun sub_sw ->
        let stdout_buf = Buffer.create 256 in
        let stderr_buf = Buffer.create 256 in
        let stdout_src, stdout_sink = Eio.Process.pipe ~sw:sub_sw proc_mgr in
        let stderr_src, stderr_sink = Eio.Process.pipe ~sw:sub_sw proc_mgr in
        let proc =
          Eio.Process.spawn ~sw:sub_sw proc_mgr ~stdout:stdout_sink
            ~stderr:stderr_sink argv
        in
        Eio.Resource.close stdout_sink;
        Eio.Resource.close stderr_sink;
        let exit_code = ref None in
        let read_all src buf =
          let tmp = Cstruct.create 4096 in
          let rec loop () =
            match Eio.Flow.single_read src tmp with
            | n when n > 0 ->
                Buffer.add_string buf (Cstruct.to_string (Cstruct.sub tmp 0 n));
                loop ()
            | _ -> ()
          in
          try loop () with End_of_file -> ()
        in
        Eio.Fiber.all
          [
            (fun () -> read_all stdout_src stdout_buf);
            (fun () -> read_all stderr_src stderr_buf);
            (fun () ->
              match Eio.Process.await proc with
              | `Exited code -> exit_code := Some code
              | `Signaled _ -> exit_code := Some 1);
          ];
        match !exit_code with
        | Some 0 -> String.trim (Buffer.contents stdout_buf)
        | Some _ ->
            Printf.eprintf "[pera] API key command failed: %s\n%!"
              (Buffer.contents stderr_buf);
            exit 1
        | None ->
            Printf.eprintf "[pera] API key command did not complete\n%!";
            exit 1)
  in
  try Eio.Time.with_timeout_exn clock 30.0 run_once
  with Eio.Time.Timeout ->
    Printf.eprintf "[pera] API key command timed out after 30s\n%!";
    exit 1

let materialise_api_key ~env ~sw = function
  | Pera_config.Key k -> k
  | Pera_config.File p -> read_key_file ~env ~sw p
  | Pera_config.Command argv -> run_key_command ~env ~sw argv

(* Materialise the API key from the resolved config; exits if not configured. *)
let get_api_key ~env ~sw rc =
  Log.debug (fun f -> f "materialising API key");
  match rc.Config_resolver.api_key_source with
  | None ->
      Printf.eprintf "[pera] no API key configured\n%!";
      exit 1
  | Some src -> materialise_api_key ~env ~sw src

(* ── Stream function construction ─────────────────────────────────────── *)

let build_registry () =
  let open Pera_connector in
  let r = Connector_registry.empty in
  let r =
    Connector_registry.register r ~name:"anthropic" (module Anthropic_connector)
  in
  Connector_registry.register r ~name:"openai-completions"
    (module Openai_completions_connector)

let build_stream_fn ~env ~sw ~api_key ~base_url ~protocol =
  let registry = build_registry () in
  let api_keys = [ (protocol, api_key) ] in
  let adapter =
    Pera_core.Connector_adapter.create ~registry ~api_keys ~base_url ~env ~sw
  in
  Pera_core.Connector_adapter.stream_fn adapter

(* ── System prompt resolution ─────────────────────────────────────────── *)

let read_system_file ~env path =
  let eio_path = Eio.Path.(Eio.Stdenv.fs env / path) in
  match Eio.Path.load eio_path with
  | content -> String.trim content
  | exception exn ->
      let msg = Printexc.to_string exn in
      Printf.eprintf "[pera] failed to read system file %S: %s\n%!" path msg;
      exit 1

(* Return the system prompt string, falling back to the default if not set. *)
let resolve_system_prompt ~env rc =
  match rc.Config_resolver.system_prompt with
  | Some s -> s
  | None -> (
      match rc.Config_resolver.system_file with
      | None -> Pera_agent.Agent_harness.default_system_prompt
      | Some path -> read_system_file ~env path)

(* ── Event rendering ──────────────────────────────────────────────────── *)

(* Wire an event-rendering subscriber to the harness.  The unsubscribe
   handle is discarded: the subscriber must live for the entire session.
   Logs each event at debug level so operators can trace flow without
   touching production output. *)
let subscribe_renderer harness renderer =
  let _unsub =
    Pera_agent.Agent_harness.subscribe harness (fun event ->
        Log.debug (fun f ->
            f "agent event: %s" (Pera_core.Agent_types.show_agent_event event));
        let lines = Event_renderer.render renderer event in
        List.iter
          (fun line ->
            print_string line;
            flush stdout)
          lines)
  in
  ()

(* ── Interactive input loop ───────────────────────────────────────────── *)

let stdin_line_limit = 1 lsl 20 (* 1 MiB — avoids hard paste limits *)

(* Read lines from [env]'s stdin and dispatch them to [send].

   A single persistent [Buf_read.t] is used across all iterations so that
   any bytes the OS delivers in one [read(2)] call (e.g. pasted lines) are
   buffered and not lost between calls.  Creating a fresh buffer via
   [Buf_read.parse_exn] each time discards buffered bytes after the first
   newline, which silently drops input and exits the loop prematurely. *)
let run_interactive ~commands ~stdin_isatty ~send ~info_stats ~compact_fn ~env =
  let stdin_src = Eio.Stdenv.stdin env in
  let buf_reader = Eio.Buf_read.of_flow ~max_size:stdin_line_limit stdin_src in
  let read_line () = Eio.Buf_read.line buf_reader in
  Log.debug (fun f -> f "run_interactive: isatty=%b" stdin_isatty);
  let rec tty_loop () =
    Log.debug (fun f -> f "tty_loop: waiting for input");
    print_string "> ";
    flush stdout;
    match read_line () with
    | exception End_of_file ->
        Log.debug (fun f -> f "tty_loop: EOF");
        ()
    | line -> (
        Log.debug (fun f -> f "tty_loop: line %S" line);
        match Input_loop.parse_line ~commands line with
        | Send text ->
            if not (String.is_empty text) then begin
              Log.debug (fun f -> f "send: dispatching %S" text);
              send text;
              Log.debug (fun f -> f "send: agent turn complete")
            end;
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

(* ── Module types ─────────────────────────────────────────────────────── *)

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
end

(* ── Functor — only Cli_env-dependent code lives here ────────────────── *)

module Make (Cli_env : Env) = struct
  (* Build the execution context and shell tools for this session.
     Both depend on [Cli_env] values, so they cannot be extracted to module
     level without threading the env functions as explicit parameters. *)
  let resolve_exec_env ~env ~sw rc =
    let cwd =
      match rc.Config_resolver.cwd with "" -> Sys.getcwd () | d -> d
    in
    Log.debug (fun f -> f "cwd: %s" cwd);
    let ctx = Cli_env.create ~env ~sw ~cwd in
    let shell_tools =
      if Cli_env.has_shell then (
        match Shell_tool_builder.build_all rc.Config_resolver.tools with
        | Ok tools -> tools
        | Error (Shell_tool_builder.Unknown_placeholder name) ->
            Printf.eprintf
              "[pera] shell tool error: unknown placeholder {%s}\n%!" name;
            exit 1)
      else begin
        if not (List.is_empty rc.Config_resolver.tools) then
          Printf.eprintf
            "[pera] warning: shell tools defined but env has no shell\n%!";
        []
      end
    in
    (cwd, ctx, shell_tools)

  (* Create the Agent_harness for this session; exits on failure. *)
  let create_harness ~env ~sw ~cwd ~rc ~ctx ~system_prompt ~shell_tools
      ~stream_fn =
    let session_path =
      Session_path.resolve ~session_override:rc.Config_resolver.session_override
        ~session_dir:rc.Config_resolver.session_dir
        ~secure_random:(Cli_env.secure_random ~env)
        ~clock:(Eio.Stdenv.clock env)
    in
    Log.debug (fun f ->
        f "creating harness: model=%s session=%s"
          rc.Config_resolver.model.Pera_types.Types.id session_path);
    let harness_config : Pera_agent.Agent_harness.config =
      {
        cwd;
        model = rc.Config_resolver.model;
        session_path;
        stream_fn;
        max_tokens = rc.Config_resolver.max_tokens;
        exec_env = ctx;
        system_prompt;
        thinking_budget_tokens = rc.Config_resolver.thinking_budget_tokens;
        cache_policy = to_cache_policy rc.Config_resolver.cache_policy;
        cache_ttl = to_cache_ttl rc.Config_resolver.cache_ttl;
        extra_tools = shell_tools;
        compaction = rc.Config_resolver.compaction;
      }
    in
    match Pera_agent.Agent_harness.create ~config:harness_config ~env ~sw with
    | Ok h -> h
    | Error e ->
        Printf.eprintf "[pera] session error: %s\n%!" e.Pera_types.Types.message;
        exit 1

(* Resolve the base URL for a provider. Priority:
   1. [api_env] env var from provider spec (if set)
   2. [api] field from provider spec *)
let resolve_base_url ~getenv_opt (spec : Models_config.provider_spec) =
  match spec.Models_config.api_env with
  | Some var -> (
      match getenv_opt var with
      | Some url -> Some url
      | None -> spec.Models_config.api)
  | None -> spec.Models_config.api

let run_with ?stream_fn inputs =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let rc = resolve_config inputs in
          let api_key = get_api_key ~env ~sw rc in
          let stream_fn =
            match stream_fn with
            | Some fn -> fn
            | None ->
                let base_url =
                  match
                    resolve_base_url
                      ~getenv_opt:inputs.Config_resolver.getenv_opt
                      rc.Config_resolver.provider_spec
                  with
                  | Some url -> url
                  | None ->
                      Printf.eprintf
                        "[pera] no API URL configured for provider %s\n%!"
                        rc.Config_resolver.provider_spec.Models_config.name;
                      exit 1
                in
                build_stream_fn ~env ~sw ~api_key ~base_url
                  ~protocol:
                    rc.Config_resolver.provider_spec.Models_config.protocol
          in
            let cwd, ctx, shell_tools = resolve_exec_env ~env ~sw rc in
            let system_prompt = resolve_system_prompt ~env rc in
            if not (List.is_empty rc.Config_resolver.mcp_servers) then
              Printf.eprintf "[pera] MCP servers not yet supported\n%!";
            let harness =
              create_harness ~env ~sw ~cwd ~rc ~ctx ~system_prompt ~shell_tools
                ~stream_fn
            in
            let renderer =
              Event_renderer.create ~output:rc.Config_resolver.output
                ~json:rc.Config_resolver.json_output
            in
            subscribe_renderer harness renderer;
            Log.debug (fun f -> f "starting session");
            (match
               ( inputs.Config_resolver.parsed_args.Cli_args.input,
                 inputs.Config_resolver.parsed_args.Cli_args.input_file )
            with
            | Some text, None ->
                Pera_agent.Agent_harness.send harness text
            | None, Some path -> (
                match
                  try Ok (Stdlib.In_channel.with_open_text path Stdlib.In_channel.input_all)
                  with Sys_error msg -> Error msg
                with
                | Ok text -> Pera_agent.Agent_harness.send harness text
                | Error msg ->
                    Printf.eprintf "[pera] cannot read %s: %s\n%!" path msg;
                    exit 1)
            | _ ->
                run_interactive ~commands:rc.Config_resolver.commands
                  ~stdin_isatty:(Unix.isatty Unix.stdin)
                  ~send:(Pera_agent.Agent_harness.send harness)
                  ~info_stats:(fun () -> Event_renderer.stats renderer)
                  ~compact_fn:(fun () ->
                    Printf.eprintf "[pera] /compact not yet wired\n%!")
                  ~env)))

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
            Fpath.(
              normalize (bin_dir / ".." / "share" / "pera" / "models.sexp"))
            |> Fpath.to_string
          in
          let from_xdg =
            let dirs =
              match Cli_env.getenv_opt "XDG_DATA_DIRS" with
              | Some s ->
                  String.split_on_char ':' s
                  |> List.filter (fun s -> not (String.is_empty s))
              | None -> [ "/usr/local/share"; "/usr/share" ]
            in
            List.map
              (fun d -> Fpath.(v d / "pera" / "models.sexp") |> Fpath.to_string)
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
    (if parsed_args.Cli_args.list_models then
       let max_name_len = ref 0 in
       let entries =
         List.concat_map
           (fun (p : Models_config.provider_spec) ->
              let env_vars = String.concat ", " p.Models_config.api_key_env in
              let env_str =
                if String.is_empty env_vars then "(none)" else env_vars
              in
              List.map
                (fun (m : Models_config.model_spec) ->
                   let full = p.Models_config.name ^ "/" ^ m.Models_config.name in
                   max_name_len := max !max_name_len (String.length full);
                   (full, env_str))
                p.Models_config.models)
           models_file.Models_config.providers
       in
       List.iter
         (fun (name, env) ->
            Printf.printf "%-*s  %s\n" !max_name_len name env)
         entries;
       exit 0);
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
