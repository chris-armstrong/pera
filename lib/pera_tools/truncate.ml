open Containers

let max_lines = 2000
let max_bytes = 262_144

type truncation_info = {
  truncated : bool;
  total_lines : int;
  output_lines : int;
  truncated_by : [`Lines | `Bytes] option;
}

(** Find how many lines starting from [lines] fit within [byte_limit] bytes,
    including newline separators. Returns the count of fitting lines. *)
let lines_fit_in_bytes lines byte_limit =
  let rec count acc_bytes n = function
    | [] -> n
    | line :: rest ->
        let line_len = String.length line in
        (* +1 for the newline that would be added when joining *)
        let next = acc_bytes + line_len + 1 in
        if next > byte_limit then n
        else count next (n + 1) rest
  in
  count 0 0 lines

let truncate_head content =
  let all_lines = String.split_on_char '\n' content in
  let total = List.length all_lines in
  (* First, cap by line count *)
  let by_lines = List.take max_lines all_lines in
  let joined = String.concat "\n" by_lines in
  if String.length joined > max_bytes then
    (* Byte limit hit first; find how many lines fit *)
    let n = lines_fit_in_bytes all_lines max_bytes in
    let truncated_lines = List.take n all_lines in
    let result = String.concat "\n" truncated_lines in
    let output = List.length truncated_lines in
    ( result,
      {
        truncated = true;
        total_lines = total;
        output_lines = output;
        truncated_by = Some `Bytes;
      } )
  else if List.length by_lines < total then
    (* Line limit hit *)
    ( joined,
      {
        truncated = true;
        total_lines = total;
        output_lines = List.length by_lines;
        truncated_by = Some `Lines;
      } )
  else
    (* No truncation needed *)
    ( content,
      {
        truncated = false;
        total_lines = total;
        output_lines = total;
        truncated_by = None;
      } )

let truncate_tail content =
  let all_lines = String.split_on_char '\n' content in
  let total = List.length all_lines in
  (* Take from the end *)
  let by_lines =
    if total <= max_lines then all_lines
    else
      let skip = total - max_lines in
      List.drop skip all_lines
  in
  let joined = String.concat "\n" by_lines in
  if String.length joined > max_bytes then
    (* Byte limit hit; find how many trailing lines fit within max_bytes *)
    let n = lines_fit_in_bytes (List.rev by_lines) max_bytes in
    let truncated_lines =
      let skip = List.length by_lines - n in
      List.drop skip by_lines
    in
    let result = String.concat "\n" truncated_lines in
    ( result,
      {
        truncated = true;
        total_lines = total;
        output_lines = List.length truncated_lines;
        truncated_by = Some `Bytes;
      } )
  else if List.length by_lines < total then
    ( joined,
      {
        truncated = true;
        total_lines = total;
        output_lines = List.length by_lines;
        truncated_by = Some `Lines;
      } )
  else
    ( content,
      {
        truncated = false;
        total_lines = total;
        output_lines = total;
        truncated_by = None;
      } )
