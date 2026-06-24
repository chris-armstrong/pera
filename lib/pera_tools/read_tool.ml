open Containers

let format_footer ~truncated ~output_lines ~total_lines ~next_offset
    ~remaining_after_trunc ~shown_count ~total_remaining =
  if truncated then
    Printf.sprintf
      "\n\
       [Output truncated to %d lines (%d total). Use offset=%d to view \
       remaining lines.]"
      output_lines total_lines next_offset
  else if remaining_after_trunc > 0 then
    Printf.sprintf
      "\n\
       [Showing %d lines; %d remaining. Use offset=%d to view remaining lines.]"
      shown_count remaining_after_trunc next_offset
  else if shown_count < total_remaining then
    Printf.sprintf
      "\n\
       [Showing %d lines; %d remaining. Use offset=%d to view remaining lines.]"
      shown_count
      (total_remaining - shown_count)
      next_offset
  else ""

let read_schema =
  Pera_connector.Json_schema.object_ ~required:[ "path" ]
    ~properties:
      [
        ( "path",
          Pera_connector.Json_schema.string
            ~description:"Path to read (use absolute path when possible)." () );
        ( "offset",
          Pera_connector.Json_schema.optional
            (Pera_connector.Json_schema.integer
               ~description:
                 "Start reading from this line number (1-indexed). Default is \
                  0 (beginning)."
               ()) );
        ( "limit",
          Pera_connector.Json_schema.optional
            (Pera_connector.Json_schema.integer
               ~description:
                 "Maximum number of lines to return. Default is 2000."
               ()) );
      ]
    ()

let read (env : (module Pera_env.Execution_env.S)) =
  let module E = (val env : Pera_env.Execution_env.S) in
  Pera_core.Agent_types.Tool.create ~name:"read"
    ~description:
      "Read a file. Output is automatically truncated to 2000 lines or 256 KB."
    ~schema:read_schema ~parallel_safe:true
    ~execute:
      (fun ~ctx:() ~args ~sw ~cancel:_ ->
        let open Result.Syntax in
        let* path = Tool_util.get_string "path" args in
        let user_offset =
          Tool_util.get_int_opt "offset" args |> Option.value ~default:0
        in
        let limit = Tool_util.get_int_opt "limit" args in
        let* content =
          E.Fs.read_text_file ~path ~sw
          |> Result.map_error Tool_util.file_error_to_tool_error
        in
        let lines = String.split_on_char '\n' content in
        let total_lines = List.length lines in
        (* Normalize offset: 0 means start from beginning; otherwise 1-indexed *)
        let offset = if user_offset <= 0 then 1 else user_offset in
        let start_idx = offset - 1 in
        if start_idx >= total_lines then
          Error
            {
              Pera_types.Types.message =
                Printf.sprintf
                  "Offset %d is beyond end of file. File has %d lines." offset
                  total_lines;
              is_user_error = true;
            }
        else
          let remaining = List.drop start_idx lines in
          let total_remaining = List.length remaining in
          let limited =
            match limit with
            | Some l -> List.take l remaining
            | None -> remaining
          in
          let shown_count = List.length limited in
          let joined = String.concat "\n" limited in
          let truncated_str, info = Truncate.truncate_head joined in
          let next_offset = offset + info.output_lines in
          let remaining_after_trunc = total_remaining - info.output_lines in
          let footer =
            format_footer ~truncated:info.truncated
              ~output_lines:info.output_lines ~total_lines:info.total_lines
              ~next_offset ~remaining_after_trunc ~shown_count ~total_remaining
          in
          Ok (Pera_core.Agent_types.Tool_text (truncated_str ^ footer)))
