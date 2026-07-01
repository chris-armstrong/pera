open Containers
open Pera_cli

(** Maps models.dev npm package name to the pera connector protocol string.
    Only entries in this table are emitted; providers using other npm packages
    are skipped. *)
let npm_to_protocol =
  [
    ("@ai-sdk/anthropic", "anthropic");
    ("@ai-sdk/openai", "openai-completions");
    ("@ai-sdk/openai-compatible", "openai-completions");
    ("@ai-sdk/groq", "openai-completions");
    ("@ai-sdk/togetherai", "openai-completions");
    ("@ai-sdk/mistral", "openai-completions");
  ]

let die fmt =
  Printf.ksprintf
    (fun s ->
      Printf.eprintf "[models_gen] %s\n%!" s;
      exit 1)
    fmt

(* ── Yojson helpers ───────────────────────────────────────────────────────── *)

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt ~eq:String.equal key fields
  | _ -> None

let string_opt key json =
  match assoc_opt key json with
  | Some (`String s) -> Some s
  | _ -> None

let strings key json =
  match assoc_opt key json with
  | Some (`List items) ->
      List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let int_of_json = function
  | `Int n -> Some n
  | `Float f -> Some (int_of_float f)
  | _ -> None

let int_opt key json =
  match assoc_opt key json with
  | Some j -> int_of_json j
  | None -> None

let number_to_decimal_string = function
  | `Int n -> Some (string_of_int n)
  | `Float f -> Some (Printf.sprintf "%g" f)
  | _ -> None

(* ── Augmentation helpers ─────────────────────────────────────────────────── *)

let aug_provider_of aug_providers provider_id =
  match List.assoc_opt ~eq:String.equal provider_id aug_providers with
  | Some p -> p
  | None -> `Null

let model_filter_of aug_provider =
  match assoc_opt "model_filter" aug_provider with
  | Some (`List items) ->
      Some (List.filter_map (function `String s -> Some s | _ -> None) items)
  | _ -> None

(* ── Parsers ──────────────────────────────────────────────────────────────── *)

let parse_compat aug_provider =
  match assoc_opt "compat" aug_provider with
  | None -> None
  | Some c ->
      let s k = string_opt k c in
      let b k =
        match assoc_opt k c with
        | Some (`Bool v) -> Some v
        | _ -> None
      in
      Some
        Models_config.
          {
            reasoning_field = s "reasoning_field";
            max_tokens_field = s "max_tokens_field";
            require_tool_result_name = b "require_tool_result_name";
            enable_thinking_field = s "enable_thinking_field";
          }

let parse_thinking model_name aug_provider =
  match assoc_opt "thinking_models" aug_provider with
  | Some (`Assoc tm) -> (
      match List.assoc_opt ~eq:String.equal model_name tm with
      | Some budget_json ->
          let bm = int_opt "budget_medium" budget_json in
          let bh = int_opt "budget_high" budget_json in
          (match bm, bh with
          | Some budget_medium, Some budget_high ->
              Some Models_config.{ budget_medium; budget_high }
          | _ -> None)
      | None -> None)
  | _ -> None

let parse_cost model_json =
  match assoc_opt "cost" model_json with
  | Some (`Assoc fields) ->
      let get k =
        match List.assoc_opt ~eq:String.equal k fields with
        | Some j -> (
            match number_to_decimal_string j with
            | Some s -> Some (Decimal.of_string s)
            | None -> None)
        | None -> None
      in
      (match get "input", get "output" with
      | Some input_per_mtok, Some output_per_mtok ->
          Some
            Models_config.
              {
                input_per_mtok;
                output_per_mtok;
                cache_read_per_mtok = get "cache_read";
                cache_write_per_mtok = get "cache_write";
              }
      | _ -> None)
  | _ -> None

let parse_model model_name model_json aug_provider =
  let limit = Option.get_or ~default:`Null (assoc_opt "limit" model_json) in
  let context_window = int_opt "context" limit |> Option.get_or ~default:0 in
  let max_tokens = int_opt "output" limit |> Option.get_or ~default:0 in
  Models_config.
    {
      name = model_name;
      context_window;
      max_tokens;
      thinking = parse_thinking model_name aug_provider;
      cost = parse_cost model_json;
    }

let parse_provider provider_id provider_json aug_providers =
  let npm = Option.get_or ~default:"" (string_opt "npm" provider_json) in
  match List.assoc_opt ~eq:String.equal npm npm_to_protocol with
  | None -> None
  | Some protocol ->
      let aug_provider = aug_provider_of aug_providers provider_id in
      (* Augmentations are optional overrides (compat, thinking, model filter,
         API URL). Providers with a known npm→protocol mapping are emitted
         regardless of whether they appear in augmentations.json. *)
      let filter = model_filter_of aug_provider in
      let models_raw =
        match assoc_opt "models" provider_json with
        | Some (`Assoc m) -> m
        | _ -> []
      in
      let models_filtered =
        match filter with
        | Some names ->
            List.filter
              (fun (k, _) -> List.mem ~eq:String.equal k names)
              models_raw
        | None -> models_raw
      in
      let models =
        List.map
          (fun (name, json) -> parse_model name json aug_provider)
          models_filtered
      in
      if List.is_empty models then None
      else
        Some
          Models_config.
            {
              name = provider_id;
              protocol;
              api_key_env = strings "env" provider_json;
              api =
                (match string_opt "api" aug_provider with
                | Some url -> Some url
                | None -> string_opt "api" provider_json);
              api_env = None;
              compat = parse_compat aug_provider;
              models;
            }

(* ── Entry point ──────────────────────────────────────────────────────────── *)

let load_json path =
  match Yojson.Safe.from_file path with
  | exception Yojson.Json_error msg -> die "cannot parse %s: %s" path msg
  | exception Sys_error msg -> die "cannot read %s: %s" path msg
  | json -> json

let usage () =
  Printf.eprintf
    "usage: models_gen <api.json> [--augment <augmentations.json>]\n\n\
     Download api.json with:\n\
    \  curl -s https://models.dev/api.json > /tmp/api.json\n\n\
     Typical invocation:\n\
    \  dune exec bin/models_gen/main.exe -- /tmp/api.json \\\n\
    \    --augment share/pera/augmentations.json \\\n\
    \    > share/pera/models.sexp\n";
  exit 1

let () =
  let args = match Array.to_list Sys.argv with _ :: rest -> rest | [] -> [] in
  let input_file, aug_file =
    match args with
    | [ f ] -> (f, None)
    | [ f; "--augment"; a ] | [ "--augment"; a; f ] -> (f, Some a)
    | _ -> usage ()
  in
  let api_json = load_json input_file in
  let aug =
    match aug_file with
    | Some p -> load_json p
    | None -> `Null
  in
  let aug_providers =
    match assoc_opt "providers" aug with
    | Some (`Assoc ps) -> ps
    | _ -> []
  in
  let providers_raw =
    match api_json with
    | `Assoc ps -> ps
    | _ -> die "expected JSON object at top level of models.dev file"
  in
  let providers =
    List.filter_map
      (fun (pid, pjson) -> parse_provider pid pjson aug_providers)
      providers_raw
  in
  let mf = Models_config.{ providers } in
  print_string (Sexplib.Sexp.to_string_hum (Models_config.sexp_of_models_file mf));
  print_newline ()
