open Containers

type verdict = Pass | Fail of string

let parse_session_file path =
  let contents = Stdlib.In_channel.(with_open_text path input_all) in
  let lines = String.split_on_char '\n' contents in
  let nonempty = List.filter (fun s -> not (String.is_empty s)) lines in
  List.map Yojson.Safe.from_string nonempty

let get_string key json = Yojson.Safe.Util.(member key json |> to_string)

let get_string_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Null -> None
  | `String s -> Some s
  | _ -> None

let check_content_chain entries =
  let content =
    List.filter (fun e -> not (String.equal (get_string "type" e) "leaf")) entries
  in
  let rec check = function
    | [] | [ _ ] -> None
    | prev :: (cur :: _ as rest) ->
        let prev_id = get_string "id" prev in
        (match get_string_opt "parent_id" cur with
        | None ->
            Some (Printf.sprintf "entry '%s' has no parent_id" (get_string "id" cur))
        | Some pid when not (String.equal pid prev_id) ->
            Some
              (Printf.sprintf "chain broken at '%s': parent='%s' expected='%s'"
                 (get_string "id" cur) pid prev_id)
        | Some _ -> check rest)
  in
  check content

let assert_leaves_childless entries =
  let leaf_ids =
    List.filter_map
      (fun e ->
        if String.equal (get_string "type" e) "leaf" then Some (get_string "id" e)
        else None)
      entries
  in
  List.find_opt
    (fun e ->
      match get_string_opt "parent_id" e with
      | Some pid -> List.mem ~eq:String.equal pid leaf_ids
      | None -> false)
    entries

let verify_chain_and_leaves entries =
  match check_content_chain entries with
  | Some msg -> Fail ("content chain broken: " ^ msg)
  | None ->
      (match assert_leaves_childless entries with
      | Some e ->
          Fail (Printf.sprintf "leaf has child entry '%s'" (get_string "id" e))
      | None -> Pass)

let make_temp_dir env ~prefix =
  let tmpdir = Filename.get_temp_dir_name () in
  let pid = Unix.getpid () in
  let ts = Int64.of_float (Unix.gettimeofday ()) in
  let name = Printf.sprintf "%s_%d_%Ld" prefix pid ts in
  let path = Filename.concat tmpdir name in
  Eio.Path.(mkdirs ~exists_ok:false ~perm:0o700 (env#fs / path));
  path

let cleanup path =
  try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote path)))
  with _ -> ()

let print_verdict ~tag ~scenario = function
  | Pass -> Printf.printf "[%s] %s ... PASS\n" tag scenario
  | Fail msg -> Printf.printf "[%s] %s ... FAIL: %s\n" tag scenario msg

let count_passed scenarios =
  List.length
    (List.filter (fun (_, v) -> match v with Pass -> true | Fail _ -> false) scenarios)

let int_field key json =
  match Yojson.Safe.Util.member key json with
  | `Int n -> n
  | _ -> 0

(** Extract the [usage] object from an assistant-message JSONL entry, or [None]
    if the entry is not an assistant message or has no usage object. *)
let usage_of_entry entry =
  if not (String.equal (get_string "type" entry) "message") then None
  else
    let msg = Yojson.Safe.Util.member "message" entry in
    match get_string_opt "role" msg with
    | Some "assistant" ->
        (match Yojson.Safe.Util.member "usage" msg with
        | `Assoc _ as usage -> Some usage
        | _ -> None)
    | _ -> None

let collect_cumulative_usage entries =
  List.filter_map usage_of_entry entries
  |> List.fold_left
       (fun acc usage ->
         Pera_types.Types.
           {
             input_tokens =
               acc.input_tokens + int_field "input_tokens" usage;
             output_tokens =
               acc.output_tokens + int_field "output_tokens" usage;
             cache_read_tokens =
               acc.cache_read_tokens + int_field "cache_read_tokens" usage;
             cache_write_tokens =
               acc.cache_write_tokens + int_field "cache_write_tokens" usage;
             cost_usd = None;
           })
       Pera_types.Types.
         {
           input_tokens = 0;
           output_tokens = 0;
           cache_read_tokens = 0;
           cache_write_tokens = 0;
           cost_usd = None;
         }

let parse_session_file_lenient path =
  let contents = Stdlib.In_channel.(with_open_text path input_all) in
  let lines = String.split_on_char '\n' contents in
  let nonempty = List.filter (fun s -> not (String.is_empty s)) lines in
  List.filter_map
    (fun line ->
      try Some (Yojson.Safe.from_string line)
      with Yojson.Json_error _ -> None)
    nonempty
