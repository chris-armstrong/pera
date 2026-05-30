open Containers

let bash_schema =
  Pera_provider.Json_schema.object_ ~required:[ "command" ]
    ~properties:
      [
        ( "command",
          Pera_provider.Json_schema.string
            ~description:
              "Bash command to execute in the current working directory."
            () );
        ( "timeout",
          Pera_provider.Json_schema.optional
            (Pera_provider.Json_schema.number ~description:"Timeout in seconds."
               ()) );
      ]
    ()

let bash (env : (module Pera_harness.Execution_env.S)) =
  let module E = (val env : Pera_harness.Execution_env.S) in
  let process_error ~error_msg buf =
    let partial = Buffer.contents buf in
    let msg =
      if String.is_empty partial then error_msg
      else partial ^ "\n\n" ^ error_msg
    in
    Error { Pera_types.Types.message = msg; is_user_error = false }
  in
  let process_ok_result raw result =
    if Int.equal result.Pera_harness.Execution_env.exit_code 0 then
      let truncated, _info = Truncate.truncate_tail raw in
      Ok (Pera_core.Agent_types.Tool_text truncated)
    else
      let msg =
        Printf.sprintf "Command exited with code %d:\n%s"
          result.Pera_harness.Execution_env.exit_code raw
      in
      Error { Pera_types.Types.message = msg; is_user_error = false }
  in
  {
    Pera_core.Agent_types.name = "bash";
    description =
      "Execute a bash command. Returns stdout and stderr combined. Output \
       truncated to last 2000 lines or 256 KB. Non-zero exit codes are \
       surfaced as errors.";
    schema = bash_schema;
    mode = `Sequential;
    execute =
      (fun ~ctx:() ~args ~sw ~cancel ->
        let open Result.Syntax in
        let* command = Tool_util.get_string "command" args in
        let timeout_opt = Tool_util.get_float_opt "timeout" args in
        let buf = Buffer.create 1024 in
        let on_stdout chunk = Buffer.add_string buf chunk in
        let on_stderr chunk = Buffer.add_string buf chunk in
        let exec_result =
          E.Sh.exec ~command
            ?cwd:(None : string option)
            ?env:(None : (string * string) list option)
            ?timeout:(timeout_opt : float option)
            ?on_stdout:(Some on_stdout : (string -> unit) option)
            ?on_stderr:(Some on_stderr : (string -> unit) option)
            ~sw ~cancel
        in
        match exec_result with
        | Error e -> process_error ~error_msg:e.Pera_types.Types.message buf
        | Ok result -> process_ok_result (Buffer.contents buf) result);
  }
