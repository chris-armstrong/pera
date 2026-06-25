open Containers

let merge ~base ~overlay =
  let open Models_config in
  let merge_model_lists base_models overlay_models =
    let replaced = List.map (fun (om : model_spec) ->
      match List.find_opt (fun (bm : model_spec) ->
        String.equal bm.name om.name) base_models with
      | Some _ -> om
      | None -> om) overlay_models
    in
    let kept = List.filter (fun (bm : model_spec) ->
      Option.is_none (List.find_opt (fun (om : model_spec) ->
        String.equal om.name bm.name) overlay_models)) base_models
    in
    replaced @ kept
  in
  let merge_providers base_providers overlay_providers =
    let merged = List.map (fun (op : provider_spec) ->
      match List.find_opt (fun (bp : provider_spec) ->
        String.equal bp.name op.name) base_providers with
      | Some bp ->
          { op with models = merge_model_lists bp.models op.models }
      | None -> op) overlay_providers
    in
    let kept = List.filter (fun (bp : provider_spec) ->
      Option.is_none (List.find_opt (fun (op : provider_spec) ->
        String.equal op.name bp.name) overlay_providers)) base_providers
    in
    merged @ kept
  in
  { providers = merge_providers base.providers overlay.providers }

let read_and_parse ~path =
  let open Result.Syntax in
  let* content =
    try Ok (In_channel.with_open_text path In_channel.input_all)
    with exn ->
      Error (Printf.sprintf "failed to read %S: %s" path
               (Printexc.to_string exn))
  in
  try
    let sexp = Sexplib.Sexp.of_string content in
    Ok (Models_config.models_file_of_sexp sexp)
  with exn ->
    Error (Printf.sprintf "failed to parse %S: %s" path
             (Printexc.to_string exn))

let load ~packaged_path ~user_path =
  let open Result.Syntax in
  let* packaged = read_and_parse ~path:packaged_path in
  match user_path with
  | None -> Ok packaged
  | Some path ->
      let* user = read_and_parse ~path in
      Ok (merge ~base:packaged ~overlay:user)

let resolve_model mf qualified_name =
  let open Models_config in
  match String.split_on_char '/' qualified_name with
  | [provider_name; model_name] ->
      (match List.find_opt (fun (p : provider_spec) ->
         String.equal p.name provider_name) mf.providers with
       | Some p ->
           (match List.find_opt (fun (m : model_spec) ->
              String.equal m.name model_name) p.models with
            | Some m -> Ok (p, m)
            | None ->
                Error (Printf.sprintf
                         "[pera] unknown model %S in provider %S — add it to \
                          $XDG_CONFIG_HOME/pera/models.sexp"
                         model_name provider_name))
       | None ->
           Error (Printf.sprintf
                    "[pera] unknown provider %S — add it to \
                     $XDG_CONFIG_HOME/pera/models.sexp"
                    provider_name))
  | _ ->
      Error (Printf.sprintf
               "[pera] not a fully qualified model name %S — expected \
                \"provider/model\""
               qualified_name)
