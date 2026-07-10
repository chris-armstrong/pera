open Containers

let default_max_matches = 100

let rg_install_msg =
  "ripgrep (rg) is not installed. Please install it with your package manager:\n\
  \  - macOS: brew install ripgrep\n\
  \  - Ubuntu/Debian: sudo apt install ripgrep\n\
  \  - Fedora: sudo dnf install ripgrep\n\
  \  - Arch: sudo pacman -S ripgrep\n\
  \  - Nix/NixOS: nix-env -iA nixpkgs.ripgrep"

let grep_schema =
  Pera_connector.Json_schema.object_ ~required:[ "pattern" ]
    ~properties:
      [
        ( "pattern",
          Pera_connector.Json_schema.string
            ~description:"Search pattern (regular expression)." () );
        ( "path",
          Pera_connector.Json_schema.optional
            (Pera_connector.Json_schema.string
               ~description:
                 "File or directory to search (default: current directory)."
               ()) );
        ( "glob",
          Pera_connector.Json_schema.optional
            (Pera_connector.Json_schema.string
               ~description:"Filter files by glob pattern (e.g. '*.ml')." ()) );
      ]
    ()

(** Split [s] into lines, dropping a trailing empty string from a final newline
    if present. *)
let split_lines s =
  let lines = String.split_on_char '\n' s in
  match List.rev lines with "" :: rest -> List.rev rest | _ -> lines

(** Build the ripgrep shell command string. All user-provided arguments are
    shell-quoted via [Filename.quote]. When no explicit path is provided, the
    current directory (".") is used so ripgrep searches from the env's working
    directory. *)
let build_rg_command ~rg ~pattern ~path_opt ~glob_opt =
  let buf = Buffer.create 128 in
  let add_str s = Buffer.add_string buf s in
  let add_quoted s =
    add_str " ";
    add_str (Filename.quote s)
  in
  add_str rg;
  add_str " --no-heading --color never --with-filename --line-number";
  (match glob_opt with
  | Some g ->
      add_str " -g";
      add_quoted g
  | None -> ());
  add_quoted pattern;
  add_quoted (Option.value path_opt ~default:".");
  Buffer.contents buf

let handle_grep_output ~exit_code ~stdout_str ~stderr_str =
  match exit_code with
  | 0 ->
      let match_lines = split_lines stdout_str in
      let total = List.length match_lines in
      if total > default_max_matches then
        let capped = List.take default_max_matches match_lines in
        let joined = String.concat "\n" capped in
        let output =
          Printf.sprintf "%s\n[Match limit of %d reached]" joined
            default_max_matches
        in
        Ok (Pera_core.Agent_types.Tool_text output)
      else Ok (Pera_core.Agent_types.Tool_text stdout_str)
  | 1 -> Ok (Pera_core.Agent_types.Tool_text "No matches found.")
  | _ ->
      let msg = if String.is_empty stderr_str then stdout_str else stderr_str in
      Error { Pera_types.Types.message = msg; is_user_error = false }

let grep =
  Pera_core.Agent_types.Tool.create ~name:"grep"
    ~description:
      "Search for a regular expression pattern in files. Uses ripgrep (rg). \
       Results are in path:line:content format, up to 100 matches. No system \
       grep fallback; ripgrep must be installed."
    ~schema:grep_schema ~parallel_safe:true
    ~execute:(fun ~ctx ~args ~sw ~cancel ->
      let module E = (val ctx : Pera_env.Execution_env.S) in
      let open Result.Syntax in
      let* pattern = Tool_util.get_string "pattern" args in
      let path_opt = Tool_util.get_string_opt "path" args in
      let glob_opt = Tool_util.get_string_opt "glob" args in
      (* Resolve rg path *)
      let* rg =
        match E.Sh.find_executable ~name:"rg" with
        | Some p -> Ok p
        | None ->
            Error
              {
                Pera_types.Types.message = rg_install_msg;
                is_user_error = false;
              }
      in
      let cmd = build_rg_command ~rg ~pattern ~path_opt ~glob_opt in
      (* Resolve the env's current working directory so Sh.exec runs ripgrep
           in the correct directory (the env's cwd, not the parent process cwd). *)
      let* cwd =
        E.Fs.absolute_path "."
        |> Result.map_error Tool_util.file_error_to_tool_error
      in
      let stdout_buf = Buffer.create 1024 in
      let stderr_buf = Buffer.create 1024 in
      let on_stdout chunk = Buffer.add_string stdout_buf chunk in
      let on_stderr chunk = Buffer.add_string stderr_buf chunk in
      match
        E.Sh.exec ~command:cmd ~on_stdout ~on_stderr ~cwd
          ?env:(None : (string * string) list option)
          ?timeout:(None : float option)
          ~sw ~cancel
      with
      | Error e ->
          Error { Pera_types.Types.message = e.message; is_user_error = false }
      | Ok result ->
          let exit_code = result.Pera_env.Execution_env.exit_code in
          let stdout_str = Buffer.contents stdout_buf in
          let stderr_str = Buffer.contents stderr_buf in
          handle_grep_output ~exit_code ~stdout_str ~stderr_str)
