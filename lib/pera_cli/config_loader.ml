open Containers

type load_error = Parse_error of string | Api_key_in_project_config

let load_user_config ~path =
  if not (Sys.file_exists path) then Ok None
  else
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      let sexp = Sexplib.Sexp.of_string content in
      let cfg = Pera_config.config_of_sexp sexp in
      Ok (Some cfg)
    with exn ->
      Error
        (Parse_error
           (Printf.sprintf "failed to parse %S: %s" path
              (Printexc.to_string exn)))

let find_project_config ~cwd =
  let rec walk dir =
    let candidate = Fpath.(dir / ".pera") |> Fpath.to_string in
    if Sys.file_exists candidate then Some candidate
    else
      let parent = Fpath.parent dir in
      if Fpath.equal parent dir then None else walk parent
  in
  walk (Fpath.v cwd)

let load_project_config ~path =
  if not (Sys.file_exists path) then Ok None
  else
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      let sexp = Sexplib.Sexp.of_string content in
      let cfg = Pera_config.config_of_sexp sexp in
      (* Reject any api_key field in provider entries *)
      let has_api_key =
        List.exists
          (fun (p : Pera_config.provider_auth) -> Option.is_some p.api_key)
          cfg.providers
      in
      if has_api_key then Error Api_key_in_project_config else Ok (Some cfg)
    with exn ->
      Error
        (Parse_error
           (Printf.sprintf "failed to parse %S: %s" path
              (Printexc.to_string exn)))

let merge ~base ~overlay =
  let open Pera_config in
  let pick opt_field base_field =
    match opt_field with Some _ -> opt_field | None -> base_field
  in
  let pick_list overlay_list base_list =
    if List.is_empty overlay_list then base_list else overlay_list
  in
  {
    default_model = pick overlay.default_model base.default_model;
    effort = pick overlay.effort base.effort;
    max_tokens = pick overlay.max_tokens base.max_tokens;
    cache = pick overlay.cache base.cache;
    session = pick overlay.session base.session;
    compaction = pick overlay.compaction base.compaction;
    output = pick overlay.output base.output;
    commands = pick_list overlay.commands base.commands;
    tools = pick_list overlay.tools base.tools;
    mcp_servers = pick_list overlay.mcp_servers base.mcp_servers;
    providers = pick_list overlay.providers base.providers;
  }
