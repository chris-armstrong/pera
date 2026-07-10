open Containers

type build_error = Unknown_placeholder of string

let placeholder_re =
  Re.(compile (seq [ char '{'; group (rep1 (compl [ char '}' ])); char '}' ]))

let find_placeholders template =
  Re.all placeholder_re template |> List.map (fun g -> Re.Group.get g 1)

let validate template declared_names =
  let placeholders = find_placeholders template in
  List.find_opt
    (fun p -> not (List.exists (String.equal p) declared_names))
    placeholders
  |> Option.map (fun p -> Unknown_placeholder p)

let arg_schema (arg : Pera_config.shell_arg) =
  match arg.arg_type with
  | String { description } -> Pera_connector.Json_schema.string ~description ()
  | Int { description; min; max } ->
      Pera_connector.Json_schema.integer ~description ?minimum:min ?maximum:max
        ()

let build_schema (def : Pera_config.shell_tool_def) =
  let properties =
    List.map
      (fun (a : Pera_config.shell_arg) -> (a.name, arg_schema a))
      def.args
  in
  let required =
    List.map (fun (a : Pera_config.shell_arg) -> a.name) def.args
  in
  Pera_connector.Json_schema.object_ ~properties ~required ()

let extract_arg (arg : Pera_config.shell_arg) (args : Yojson.Safe.t) =
  match args with
  | `Assoc fields -> (
      match List.find_opt (fun (k, _) -> String.equal k arg.name) fields with
      | Some (_, v) -> (
          match arg.arg_type with
          | String _ -> (
              match v with
              | `String s -> Ok s
              | _ ->
                  Error (Printf.sprintf "expected string for arg %S" arg.name))
          | Int { min; max; _ } -> (
              let parse_int v_json =
                match v_json with
                | `Int i -> Ok i
                | `String s -> (
                    match Int.of_string s with
                    | Some i -> Ok i
                    | None ->
                        Error
                          (Printf.sprintf "expected integer for arg %S, got %S"
                             arg.name s))
                | _ ->
                    Error
                      (Printf.sprintf "expected integer for arg %S" arg.name)
              in
              match parse_int v with
              | Error _ as e -> e
              | Ok i ->
                  let range_ok =
                    Option.map_or ~default:true (fun lo -> i >= lo) min
                    && Option.map_or ~default:true (fun hi -> i <= hi) max
                  in
                  if range_ok then Ok (Int.to_string i)
                  else
                    Error
                      (Printf.sprintf "arg %S value %d out of range [%s, %s]"
                         arg.name i
                         (Option.map_or ~default:"-∞" Int.to_string min)
                         (Option.map_or ~default:"+∞" Int.to_string max))))
      | None -> Error (Printf.sprintf "missing required arg %S" arg.name))
  | _ -> Error "expected JSON object for tool args"

let substitute template arg_values =
  Re.replace placeholder_re template ~f:(fun g ->
      let name = Re.Group.get g 1 in
      match List.find_opt (fun (n, _) -> String.equal n name) arg_values with
      | Some (_, v) -> Filename.quote v
      | None -> "")

let build (def : Pera_config.shell_tool_def) =
  let declared_names =
    List.map (fun (a : Pera_config.shell_arg) -> a.name) def.args
  in
  match validate def.command declared_names with
  | Some err -> Error err
  | None ->
      let schema = build_schema def in
      let execute ~ctx ~args ~sw ~cancel =
        let module E = (val ctx : Pera_env.Execution_env.S) in
        let arg_values_result =
          let open Result.Syntax in
          let* arg_values =
            List.fold_left
              (fun acc a ->
                let* acc = acc in
                let* v = extract_arg a args in
                Ok ((a.Pera_config.name, v) :: acc))
              (Ok []) def.args
          in
          Ok (List.rev arg_values)
        in
        match arg_values_result with
        | Error msg ->
            Error { Pera_types.Types.message = msg; is_user_error = true }
        | Ok arg_values -> (
            let cmd = substitute def.command arg_values in
            let buf = Buffer.create 1024 in
            let on_stdout chunk = Buffer.add_string buf chunk in
            let on_stderr chunk = Buffer.add_string buf chunk in
            match
              E.Sh.exec ~command:cmd
                ?cwd:(Some E.cwd : string option)
                ?env:(None : (string * string) list option)
                ?timeout:(None : float option)
                ?on_stdout:(Some on_stdout : (string -> unit) option)
                ?on_stderr:(Some on_stderr : (string -> unit) option)
                ~sw ~cancel
            with
            | Ok result ->
                let raw = Buffer.contents buf in
                if Int.equal result.Pera_env.Execution_env.exit_code 0 then
                  Ok (Pera_core.Agent_types.Tool_text raw)
                else
                  let msg =
                    Printf.sprintf "%s\n\nCommand exited with code %d." raw
                      result.Pera_env.Execution_env.exit_code
                  in
                  Error
                    { Pera_types.Types.message = msg; is_user_error = false }
            | Error e ->
                let partial = Buffer.contents buf in
                let msg =
                  if String.is_empty partial then e.Pera_types.Types.message
                  else partial ^ "\n\n" ^ e.Pera_types.Types.message
                in
                Error { Pera_types.Types.message = msg; is_user_error = false })
      in
      let tool =
        Pera_core.Agent_types.Tool.create ~name:def.name
          ~description:def.description ~schema ~parallel_safe:def.parallel_safe
          ~execute
      in
      Ok tool

let build_all defs =
  let open Result.Syntax in
  List.fold_left
    (fun acc def ->
      let* acc = acc in
      let* tool = build def in
      Ok (tool :: acc))
    (Ok []) defs
  |> Result.map List.rev
