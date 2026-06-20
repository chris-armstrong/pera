open Containers

let write_schema =
  Pera_provider.Json_schema.object_ ~required:[ "path"; "content" ]
    ~properties:
      [
        ( "path",
          Pera_provider.Json_schema.string
            ~description:"Path to write to (relative or absolute)." () );
        ( "content",
          Pera_provider.Json_schema.string
            ~description:"Content to write to the file." () );
      ]
    ()

let write (env : (module Pera_env.Execution_env.S)) =
  let module E = (val env : Pera_env.Execution_env.S) in
  Pera_core.Agent_types.Tool.create ~name:"write"
    ~description:
      "Write content to a file. Creates parent directories if needed. \
       Overwrites existing content."
    ~schema:write_schema ~parallel_safe:false
    ~execute:
      (fun ~ctx:() ~args ~sw ~cancel:_ ->
        let open Result.Syntax in
        let* path = Tool_util.get_string "path" args in
        let* content = Tool_util.get_string "content" args in
        let* () =
          E.Fs.write_file ~path ~content ~sw
          |> Result.map_error Tool_util.file_error_to_tool_error
        in
        let bytes = String.length content in
        Ok
          (Pera_core.Agent_types.Tool_text
             (Printf.sprintf "%d bytes written to %s." bytes path)))
