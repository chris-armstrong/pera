open Containers

type framed_event = { event_type : string; data : string; id : string option }

type state = { buf : string }
(** Accumulated buffer of bytes not yet forming a complete event. *)

let initial_state = { buf = "" }

(** Strip a leading space from [s] when the field value begins with one, per the
    SSE specification ("if the character after the colon is a space, remove it
    from value"). *)
let strip_leading_space s =
  if String.length s > 0 && Char.equal s.[0] ' ' then
    String.sub s 1 (String.length s - 1)
  else s

(** Parse one SSE field line ([key:value] or [key:]) and update the mutable
    accumulators for event_type, data lines, and id. *)
let apply_field ~event_type ~data_lines ~id line =
  match String.split_on_char ':' line with
  | [] | [ "" ] ->
      (* Empty line — not a field; callers should not pass this here. *)
      ()
  | [ key ] -> (
      (* Field with no colon — treat as field name with empty value per spec. *)
      match key with
      | "data" -> data_lines := !data_lines @ [ "" ]
      | "event" -> event_type := ""
      | "id" -> id := Some ""
      | _ -> ())
  | key :: rest -> (
      let raw_value = String.concat ":" rest in
      let value = strip_leading_space raw_value in
      match key with
      | "data" -> data_lines := !data_lines @ [ value ]
      | "event" -> event_type := value
      | "id" -> id := Some value
      | _ -> ())

(** Parse a single event block (the text between two blank lines) into a
    [framed_event]. Lines in [block] are [\\n]-separated field lines; the
    surrounding blank lines are not included. *)
let parse_event_block block =
  let lines = String.split_on_char '\n' block in
  let event_type = ref "" in
  let data_lines = ref [] in
  let id = ref None in
  List.iter (fun line -> apply_field ~event_type ~data_lines ~id line) lines;
  let data = String.concat "\n" !data_lines in
  { event_type = !event_type; data; id = !id }

(** Split the accumulated buffer on the double-newline delimiter [\\n\\n].
    Returns a list of event blocks (non-empty strings between delimiters) and
    the remaining incomplete tail (which may be empty). *)
let split_on_double_newline s =
  (* We split on "\n\n".  [String.split_on_char] is not sufficient here
     because we need to match a two-character sequence. We do a manual scan
     instead. *)
  let len = String.length s in
  let rec scan start acc i =
    if i >= len - 1 then
      (* Reached end without finding another delimiter. *)
      let tail = String.sub s start (len - start) in
      (List.rev acc, tail)
    else if Char.equal s.[i] '\n' && Char.equal s.[i + 1] '\n' then
      (* Found delimiter at position i. *)
      let block = String.sub s start (i - start) in
      scan (i + 2) (block :: acc) (i + 2)
    else scan start acc (i + 1)
  in
  scan 0 [] 0

let feed state chunk =
  let accumulated = state.buf ^ chunk in
  let event_blocks, remaining = split_on_double_newline accumulated in
  (* Filter out empty blocks (e.g. from consecutive delimiters or leading
     delimiter) then parse each non-empty block into a framed_event. *)
  let is_non_empty_block b = not (String.equal (String.trim b) "") in
  let events =
    event_blocks |> List.filter is_non_empty_block |> List.map parse_event_block
  in
  ({ buf = remaining }, events)
