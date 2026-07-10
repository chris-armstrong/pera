(** Loading and merging of [models.sexp] files. *)

val load :
  packaged_path:string option ->
  user_path:string option ->
  (Models_config.models_file, string) result
(** [load ~packaged_path ~user_path] parses the packaged models file (if
    provided), then (if [user_path] is [Some p]) parses and merges the user file
    on top. At least one of [packaged_path] or [user_path] must be [Some].
    Returns [Error] if a file fails to parse, or if neither path is provided. *)

val merge :
  base:Models_config.models_file ->
  overlay:Models_config.models_file ->
  Models_config.models_file
(** Merge [overlay] into [base]: providers matched by name have their model
    lists merged (model matched by name; overlay model fields replace base); new
    providers from overlay are appended. *)

val resolve_model :
  Models_config.models_file ->
  string ->
  (Models_config.provider_spec * Models_config.model_spec, string) result
(** [resolve_model mf "provider/model"] splits the string, finds the provider by
    name, finds the model by name within it. [Error] message: "[pera] unknown
    model \"p/m\" — add it to $XDG_CONFIG_HOME/pera/models.sexp". *)
