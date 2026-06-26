open Containers

let valid_json_escape_char = function
  | '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' -> true
  | _ -> false

let is_hex_digit = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let escape_control_char c =
  match c with
  | '\x08' -> "\\b"
  | '\x0C' -> "\\f"
  | '\n' -> "\\n"
  | '\r' -> "\\r"
  | '\t' -> "\\t"
  | _ ->
      let code = Char.code c in
      Printf.sprintf "\\u%04x" code

let is_control_char c =
  let code = Char.code c in
  code >= 0x00 && code <= 0x1F

(** Scan [s] from [pos] for four consecutive hex digits. Returns true if found.
*)
let has_four_hex_digits s pos =
  let len = String.length s in
  pos + 3 < len
  && is_hex_digit (String.get s pos)
  && is_hex_digit (String.get s (pos + 1))
  && is_hex_digit (String.get s (pos + 2))
  && is_hex_digit (String.get s (pos + 3))

(** Returns (appended_string, bytes_consumed) for a backslash at position [i].
*)
let handle_backslash_in_string (s : string) (i : int) (len : int) : string * int
    =
  let next_pos = i + 1 in
  if next_pos >= len then ("\\\\", 1)
  else
    let next_c = String.get s next_pos in
    if Char.equal next_c 'u' && has_four_hex_digits s (next_pos + 1) then
      let hex = String.sub s (next_pos + 1) 4 in
      ("\\u" ^ hex, 6)
    else if valid_json_escape_char next_c then
      (String.make 1 '\\' ^ String.make 1 next_c, 2)
    else ("\\\\", 1)

let repair s =
  let len = String.length s in
  let buf = Buffer.create len in
  let in_string = ref false in
  let i = ref 0 in
  while !i < len do
    let c = String.get s !i in
    if not !in_string then begin
      Buffer.add_char buf c;
      if Char.equal c '"' then in_string := true;
      i := !i + 1
    end
    else
      (* Inside a JSON string literal *)
      begin match c with
      | '"' ->
          Buffer.add_char buf c;
          in_string := false;
          i := !i + 1
      | '\\' ->
          let appended, consumed = handle_backslash_in_string s !i len in
          Buffer.add_string buf appended;
          i := !i + consumed
      | _ when is_control_char c ->
          Buffer.add_string buf (escape_control_char c);
          i := !i + 1
      | _ ->
          Buffer.add_char buf c;
          i := !i + 1
      end
  done;
  Buffer.contents buf

let parse_streaming input =
  match input with
  | None -> Error "empty input"
  | Some s when String.equal (String.trim s) "" -> Error "empty input"
  | Some s -> (
      let try_parse str =
        match Yojson.Safe.from_string str with
        | exception Yojson.Json_error msg -> Error msg
        | json -> Ok json
      in
      let direct_result = try_parse s in
      match direct_result with
      | Ok _ -> direct_result
      | Error _ ->
          let repaired = repair s in
          try_parse repaired)
