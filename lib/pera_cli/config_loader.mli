(** Loading and merging of [config.sexp] files. *)

type load_error = Parse_error of string | Api_key_in_project_config

val load_user_config :
  path:string -> (Pera_config.config option, load_error) result
(** Parse [path]; [Ok None] if the file does not exist. *)

val find_project_config : cwd:string -> string option
(** Walk up from [cwd] looking for a file named [".pera"]. Returns the path of
    the first one found, or [None] if not found before filesystem root. *)

val load_project_config :
  path:string -> (Pera_config.config option, load_error) result
(** Parse [path]; reject any [api_key] field in any provider entry
    ([Error Api_key_in_project_config]). [Ok None] if file does not exist. *)

val merge :
  base:Pera_config.config -> overlay:Pera_config.config -> Pera_config.config
(** Field-by-field merge: [Some] value in [overlay] replaces [base]. List fields
    ([commands], [tools], [mcp_servers], [providers]) are replaced entirely (no
    concatenation). *)
