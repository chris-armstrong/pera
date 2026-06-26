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

let parse_effort s =
  match String.lowercase_ascii s with
  | "low" -> Some Pera_config.Low
  | "medium" -> Some Pera_config.Medium
  | "high" -> Some Pera_config.High
  | _ -> None

let parse_cache_policy s =
  match String.lowercase_ascii s with
  | "no_cache" -> Some Pera_config.No_cache
  | "conversation" -> Some Pera_config.Conversation
  | "system_and_tools" -> Some Pera_config.System_and_tools
  | _ -> None

let parse_cache_ttl s =
  match String.lowercase_ascii s with
  | "five_minutes" -> Some Pera_config.Five_minutes
  | "one_hour" -> Some Pera_config.One_hour
  | _ -> None

let parse_int s = Int.of_string s

let read_partial_config ~getenv_opt =
  let get k = getenv_opt k in
  let effort = Option.flat_map parse_effort (get "PERA_EFFORT") in
  let default_model = get "PERA_MODEL" in
  let max_tokens = Option.flat_map parse_int (get "PERA_MAX_TOKENS") in
  let cache_policy =
    Option.flat_map parse_cache_policy (get "PERA_CACHE_POLICY")
  in
  let cache_ttl = Option.flat_map parse_cache_ttl (get "PERA_CACHE_TTL") in
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
  let compact_threshold =
    Option.flat_map parse_int (get "PERA_COMPACT_THRESHOLD")
  in
  let compact_tail = Option.flat_map parse_int (get "PERA_COMPACT_TAIL") in
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
