open Containers

let provider_named ~name (p : Models_config.provider_spec) =
  String.equal p.name name

let model_named ~name (m : Models_config.model_spec) = String.equal m.name name

let names_of_providers =
  List.map (fun (p : Models_config.provider_spec) -> p.name)

let names_of_models = List.map (fun (m : Models_config.model_spec) -> m.name)

let merge_model_lists base_models overlay_models =
  let overlay_names = names_of_models overlay_models in
  let is_not_overlaid (bm : Models_config.model_spec) =
    not (List.mem ~eq:String.equal bm.name overlay_names)
  in
  let kept = List.filter is_not_overlaid base_models in
  overlay_models @ kept

let merge_one_provider base_providers (op : Models_config.provider_spec) =
  match List.find_opt (provider_named ~name:op.name) base_providers with
  | Some bp -> { op with models = merge_model_lists bp.models op.models }
  | None -> op

let merge_providers base_providers overlay_providers =
  let merged = List.map (merge_one_provider base_providers) overlay_providers in
  let overlay_names = names_of_providers overlay_providers in
  let is_kept (bp : Models_config.provider_spec) =
    not (List.mem ~eq:String.equal bp.name overlay_names)
  in
  let kept = List.filter is_kept base_providers in
  merged @ kept

let merge ~base ~overlay =
  let open Models_config in
  { providers = merge_providers base.providers overlay.providers }

let read_and_parse ~path =
  let open Result.Syntax in
  let* content =
    try Ok (In_channel.with_open_text path In_channel.input_all)
    with exn ->
      Error
        (Printf.sprintf "failed to read %S: %s" path (Printexc.to_string exn))
  in
  try
    let sexp = Sexplib.Sexp.of_string content in
    Ok (Models_config.models_file_of_sexp sexp)
  with exn ->
    Error
      (Printf.sprintf "failed to parse %S: %s" path (Printexc.to_string exn))

let load ~packaged_path ~user_path =
  let open Result.Syntax in
  let* packaged = read_and_parse ~path:packaged_path in
  match user_path with
  | None -> Ok packaged
  | Some path ->
      let* user = read_and_parse ~path in
      Ok (merge ~base:packaged ~overlay:user)

let resolve_model mf qualified_name =
  let open Result.Syntax in
  let open Models_config in
  let* provider_name, model_name =
    match String.split_on_char '/' qualified_name with
    | [] | [ _ ] ->
        Error
          (Printf.sprintf
             "[pera] not a fully qualified model name %S — expected \
              \"provider/model\""
             qualified_name)
    | p :: parts -> Ok (p, String.concat "/" parts)
  in
  let* p =
    List.find_opt (provider_named ~name:provider_name) mf.providers
    |> Option.to_result
         (Printf.sprintf
            "[pera] unknown provider %S — add it to \
             $XDG_CONFIG_HOME/pera/models.sexp"
            provider_name)
  in
  let* m =
    List.find_opt (model_named ~name:model_name) p.models
    |> Option.to_result
         (Printf.sprintf
            "[pera] unknown model %S in provider %S — add it to \
             $XDG_CONFIG_HOME/pera/models.sexp"
            model_name provider_name)
  in
  Ok (p, m)
