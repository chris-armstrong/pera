open Containers

type parsed_args = {
  model : string option;
  api_key : string option;
  api_key_file : string option;
  api_key_command : string option;
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
  plain : bool;
  show_thinking : bool;
  quiet : bool;
  json : bool;
  verbose : bool;
}

let effort_conv =
  Cmdliner.Arg.conv
    ( (fun s ->
        match String.lowercase_ascii s with
        | "low" -> Ok Pera_config.Low
        | "medium" -> Ok Pera_config.Medium
        | "high" -> Ok Pera_config.High
        | _ ->
            Error
              (`Msg
                 (Printf.sprintf "unknown effort %S (expected: low|medium|high)"
                    s))),
      fun fmt e ->
        Format.pp_print_string fmt
          (match e with
          | Pera_config.Low -> "low"
          | Pera_config.Medium -> "medium"
          | Pera_config.High -> "high") )

let cache_policy_conv =
  Cmdliner.Arg.conv
    ( (fun s ->
        match String.lowercase_ascii s with
        | "no_cache" -> Ok Pera_config.No_cache
        | "conversation" -> Ok Pera_config.Conversation
        | "system_and_tools" -> Ok Pera_config.System_and_tools
        | _ ->
            Error
              (`Msg
                 (Printf.sprintf
                    "unknown cache policy %S (expected: \
                     no_cache|conversation|system_and_tools)"
                    s))),
      fun fmt p ->
        Format.pp_print_string fmt
          (match p with
          | Pera_config.No_cache -> "no_cache"
          | Pera_config.Conversation -> "conversation"
          | Pera_config.System_and_tools -> "system_and_tools") )

let cache_ttl_conv =
  Cmdliner.Arg.conv
    ( (fun s ->
        match String.lowercase_ascii s with
        | "five_minutes" -> Ok Pera_config.Five_minutes
        | "one_hour" -> Ok Pera_config.One_hour
        | _ ->
            Error
              (`Msg
                 (Printf.sprintf
                    "unknown cache TTL %S (expected: five_minutes|one_hour)" s))),
      fun fmt t ->
        Format.pp_print_string fmt
          (match t with
          | Pera_config.Five_minutes -> "five_minutes"
          | Pera_config.One_hour -> "one_hour") )

let parse ~argv =
  let open Cmdliner in
  let model =
    Arg.(
      value
      & opt (some string) None
      & info [ "model" ] ~docv:"PROVIDER/MODEL"
          ~doc:
            "Fully-qualified model identifier (e.g. \
             anthropic/claude-sonnet-4-6).")
  in
  let api_key =
    Arg.(
      value
      & opt (some string) None
      & info [ "api-key" ] ~docv:"KEY" ~doc:"API key string.")
  in
  let api_key_file =
    Arg.(
      value
      & opt (some string) None
      & info [ "api-key-file" ] ~docv:"PATH" ~doc:"File containing the API key.")
  in
  let api_key_command =
    Arg.(
      value
      & opt (some string) None
      & info [ "api-key-command" ] ~docv:"CMD"
          ~doc:"Command whose stdout is the API key.")
  in
  let effort =
    Arg.(
      value
      & opt (some effort_conv) None
      & info [ "effort" ] ~docv:"LEVEL"
          ~doc:"Thinking effort level: low|medium|high.")
  in
  let max_tokens =
    Arg.(
      value
      & opt (some int) None
      & info [ "max-tokens" ] ~docv:"N" ~doc:"Maximum output tokens.")
  in
  let cache_policy =
    Arg.(
      value
      & opt (some cache_policy_conv) None
      & info [ "cache-policy" ] ~docv:"POLICY"
          ~doc:"Cache policy: no_cache|conversation|system_and_tools.")
  in
  let cache_ttl =
    Arg.(
      value
      & opt (some cache_ttl_conv) None
      & info [ "cache-ttl" ] ~docv:"TTL"
          ~doc:"Cache TTL: five_minutes|one_hour.")
  in
  let session =
    Arg.(
      value
      & opt (some string) None
      & info [ "session" ] ~docv:"PATH" ~doc:"Explicit session file path.")
  in
  let session_dir =
    Arg.(
      value
      & opt (some string) None
      & info [ "session-dir" ] ~docv:"DIR" ~doc:"Session directory.")
  in
  let cwd =
    Arg.(
      value
      & opt (some string) None
      & info [ "cwd" ] ~docv:"DIR" ~doc:"Working directory for tools.")
  in
  let system =
    Arg.(
      value
      & opt (some string) None
      & info [ "system" ] ~docv:"PROMPT" ~doc:"Literal system prompt override.")
  in
  let system_file =
    Arg.(
      value
      & opt (some string) None
      & info [ "system-file" ] ~docv:"PATH" ~doc:"Load system prompt from file.")
  in
  let no_compact =
    Arg.(
      value & flag & info [ "no-compact" ] ~doc:"Disable autonomous compaction.")
  in
  let compact_threshold =
    Arg.(
      value
      & opt (some int) None
      & info [ "compact-threshold" ] ~docv:"PCT"
          ~doc:"Compaction threshold as percentage of context window.")
  in
  let compact_tail =
    Arg.(
      value
      & opt (some int) None
      & info [ "compact-tail" ] ~docv:"N"
          ~doc:"Number of trailing turns to keep verbatim after compaction.")
  in
  let plain =
    Arg.(value & flag & info [ "plain" ] ~doc:"Strip markdown from output.")
  in
  let show_thinking =
    Arg.(value & flag & info [ "show-thinking" ] ~doc:"Show thinking blocks.")
  in
  let quiet =
    Arg.(
      value & flag & info [ "quiet" ] ~doc:"Suppress tool events from output.")
  in
  let json =
    Arg.(
      value & flag & info [ "json" ] ~doc:"Emit newline-delimited JSON events.")
  in
  let verbose =
    Arg.(value & flag & info [ "verbose" ] ~doc:"Show verbose tool output.")
  in
  let build_args model api_key api_key_file api_key_command effort max_tokens
      cache_policy cache_ttl session session_dir cwd system system_file
      no_compact compact_threshold compact_tail plain show_thinking quiet json
      verbose =
    let () =
      let count =
        List.length
          (List.filter_map
             (fun x -> x)
             [ api_key; api_key_file; api_key_command ])
      in
      if count > 1 then begin
        Printf.eprintf
          "[pera] --api-key, --api-key-file, and --api-key-command are \
           mutually exclusive\n\
           %!";
        exit 1
      end
    in
    let () =
      match (system, system_file) with
      | Some _, Some _ ->
          Printf.eprintf
            "[pera] --system and --system-file are mutually exclusive\n%!";
          exit 1
      | _ -> ()
    in
    {
      model;
      api_key;
      api_key_file;
      api_key_command;
      effort;
      max_tokens;
      cache_policy;
      cache_ttl;
      session;
      session_dir;
      cwd;
      system;
      system_file;
      no_compact;
      compact_threshold;
      compact_tail;
      plain;
      show_thinking;
      quiet;
      json;
      verbose;
    }
  in
  let term =
    Cmdliner.Term.(
      const build_args $ model $ api_key $ api_key_file $ api_key_command
      $ effort $ max_tokens $ cache_policy $ cache_ttl $ session $ session_dir
      $ cwd $ system $ system_file $ no_compact $ compact_threshold
      $ compact_tail $ plain $ show_thinking $ quiet $ json $ verbose)
  in
  let info = Cmdliner.Cmd.info "pera" ~version:"dev" ~doc:"Pera coding agent" in
  let cmd = Cmdliner.Cmd.v info term in
  match Cmdliner.Cmd.eval_value ~argv cmd with
  | Ok (`Ok args) -> args
  | Ok `Help | Ok `Version ->
      (* Cmdliner has already printed; exit 0. *)
      exit 0
  | Error _ -> exit 1

let to_partial_config (a : parsed_args) =
  let cache =
    match (a.cache_policy, a.cache_ttl) with
    | None, None -> None
    | _ -> Some Pera_config.{ policy = a.cache_policy; ttl = a.cache_ttl }
  in
  let session =
    match a.session_dir with
    | None -> None
    | Some dir -> Some Pera_config.{ dir = Some dir }
  in
  let compaction =
    match (a.no_compact, a.compact_threshold, a.compact_tail) with
    | false, None, None -> None
    | _ ->
        Some
          Pera_config.
            {
              enabled = (if a.no_compact then Some false else None);
              threshold = a.compact_threshold;
              tail = a.compact_tail;
            }
  in
  let output =
    match (a.plain, a.show_thinking, a.quiet) with
    | false, false, false -> None
    | _ ->
        Some
          Pera_config.
            {
              plain = (if a.plain then Some true else None);
              show_thinking = (if a.show_thinking then Some true else None);
              quiet = (if a.quiet then Some true else None);
            }
  in
  Pera_config.
    {
      providers = [];
      default_model = a.model;
      effort = a.effort;
      max_tokens = a.max_tokens;
      cache;
      session;
      compaction;
      output;
      commands = [];
      tools = [];
      mcp_servers = [];
    }
