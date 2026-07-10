open Containers

type api_key_override =
  | AK_key of string
  | AK_file of string
  | AK_command of string list
  | AK_none

let read_api_key_override ~getenv_opt =
  let k = getenv_opt "PERA_API_KEY" in
  let f = getenv_opt "PERA_API_KEY_FILE" in
  let c = getenv_opt "PERA_API_KEY_COMMAND" in
  let count = List.length (List.filter_map (fun x -> x) [ k; f; c ]) in
  if count > 1 then
    Error
      "[pera] PERA_API_KEY, PERA_API_KEY_FILE, and PERA_API_KEY_COMMAND are \
       mutually exclusive; set at most one"
  else
    match (k, f, c) with
    | Some v, None, None -> Ok (AK_key v)
    | None, Some p, None -> Ok (AK_file p)
    | None, None, Some cmd ->
        Ok
          (AK_command
             (String.split_on_char ' ' cmd
             |> List.filter (fun s -> not (String.is_empty s))))
    | None, None, None -> Ok AK_none
    | _ ->
        Error
          "[pera] PERA_API_KEY, PERA_API_KEY_FILE, and PERA_API_KEY_COMMAND \
           are mutually exclusive; set at most one"

let parse_effort ~context s =
  match String.lowercase_ascii s with
  | "low" -> Ok Pera_config.Low
  | "medium" -> Ok Pera_config.Medium
  | "high" -> Ok Pera_config.High
  | _ ->
      Error
        (Printf.sprintf "invalid value %S for %s (expected: low|medium|high)" s
           context)

let parse_cache_policy ~context s =
  match String.lowercase_ascii s with
  | "no_cache" -> Ok Pera_config.No_cache
  | "conversation" -> Ok Pera_config.Conversation
  | "system_and_tools" -> Ok Pera_config.System_and_tools
  | _ ->
      Error
        (Printf.sprintf
           "invalid value %S for %s (expected: \
            no_cache|conversation|system_and_tools)"
           s context)

let parse_cache_ttl ~context s =
  match String.lowercase_ascii s with
  | "five_minutes" -> Ok Pera_config.Five_minutes
  | "one_hour" -> Ok Pera_config.One_hour
  | _ ->
      Error
        (Printf.sprintf
           "invalid value %S for %s (expected: five_minutes|one_hour)" s context)

let parse_int ~context s =
  match Int.of_string s with
  | Some i -> Ok i
  | None ->
      Error
        (Printf.sprintf "invalid value %S for %s (expected: integer)" s context)

let opt_parse f = function
  | None -> Ok None
  | Some s -> Result.map (fun v -> Some v) (f s)

let read_partial_config ~getenv_opt =
  let open Result.Syntax in
  let get k = getenv_opt k in
  let* effort =
    opt_parse (parse_effort ~context:"PERA_EFFORT") (get "PERA_EFFORT")
  in
  let default_model = get "PERA_MODEL" in
  let* max_tokens =
    opt_parse (parse_int ~context:"PERA_MAX_TOKENS") (get "PERA_MAX_TOKENS")
  in
  let* cache_policy =
    opt_parse
      (parse_cache_policy ~context:"PERA_CACHE_POLICY")
      (get "PERA_CACHE_POLICY")
  in
  let* cache_ttl =
    opt_parse (parse_cache_ttl ~context:"PERA_CACHE_TTL") (get "PERA_CACHE_TTL")
  in
  let cache =
    match (cache_policy, cache_ttl) with
    | None, None -> None
    | _ -> Some Pera_config.{ policy = cache_policy; ttl = cache_ttl }
  in
  let session_dir = get "PERA_SESSION_DIR" in
  let session =
    match session_dir with
    | None -> None
    | Some dir -> Some Pera_config.{ dir = Some dir }
  in
  let no_compact =
    match get "PERA_NO_COMPACT" with Some _ -> true | None -> false
  in
  let* compact_threshold =
    opt_parse
      (parse_int ~context:"PERA_COMPACT_THRESHOLD")
      (get "PERA_COMPACT_THRESHOLD")
  in
  let* compact_tail =
    opt_parse (parse_int ~context:"PERA_COMPACT_TAIL") (get "PERA_COMPACT_TAIL")
  in
  let compaction =
    match (no_compact, compact_threshold, compact_tail) with
    | false, None, None -> None
    | _ ->
        Some
          Pera_config.
            {
              enabled = (if no_compact then Some false else None);
              threshold = compact_threshold;
              tail = compact_tail;
            }
  in
  Ok
    Pera_config.
      {
        providers = [];
        default_model;
        effort;
        max_tokens;
        cache;
        session;
        compaction;
        output = None;
        commands = [];
        tools = [];
        mcp_servers = [];
      }
