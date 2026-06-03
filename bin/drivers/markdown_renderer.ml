(*
  Incremental markdown renderer for streaming LLM output.

  Strategy: split input at block boundaries (\n\n). Everything before the last
  boundary is "stable" — fully committed to stdout with balanced ANSI codes.
  The tail after the boundary stays in pending until more text arrives or finish
  is called. We never erase or reposition the cursor.

  Known limitation: code blocks that contain blank lines internally will be split
  prematurely during streaming (though finish always renders them correctly).
*)

type t = {
  pending : Buffer.t;
}

let create () = { pending = Buffer.create 1024 }

(* --- ANSI codes (raw strings — no Format module) --- *)

let reset  = "\x1b[0m"
let bold   = "\x1b[1m"
let faint  = "\x1b[2m"
let italic = "\x1b[3m"
let yellow = "\x1b[33m"
let blue   = "\x1b[34m"
let cyan_b = "\x1b[96m"
let blue_b = "\x1b[94m"

let add buf s = Buffer.add_string buf s
let nl  buf   = Buffer.add_char  buf '\n'

(* --- AST rendering --- *)

let rec render_inline buf = function
  | Cmarkit.Inline.Text (text, _) ->
      add buf text
  | Cmarkit.Inline.Emphasis (em, _) ->
      add buf italic;
      render_inline buf (Cmarkit.Inline.Emphasis.inline em);
      add buf reset
  | Cmarkit.Inline.Strong_emphasis (em, _) ->
      add buf bold;
      render_inline buf (Cmarkit.Inline.Emphasis.inline em);
      add buf reset
  | Cmarkit.Inline.Code_span (cs, _) ->
      add buf yellow;
      add buf "`"; add buf (Cmarkit.Inline.Code_span.code cs); add buf "`";
      add buf reset
  | Cmarkit.Inline.Break (br, _) ->
      (match Cmarkit.Inline.Break.type' br with
       | `Hard -> nl buf
       | `Soft -> add buf " ")
  | Cmarkit.Inline.Inlines (inlines, _) ->
      List.iter (render_inline buf) inlines
  | Cmarkit.Inline.Link (lk, _) ->
      render_inline buf (Cmarkit.Inline.Link.text lk)
  | Cmarkit.Inline.Image (lk, _) ->
      add buf "[image: ";
      render_inline buf (Cmarkit.Inline.Link.text lk);
      add buf "]"
  | Cmarkit.Inline.Autolink (al, _) ->
      let (link, _) = Cmarkit.Inline.Autolink.link al in
      add buf cyan_b; add buf link; add buf reset
  | Cmarkit.Inline.Raw_html _ -> ()
  | Cmarkit.Inline.Ext_strikethrough (st, _) ->
      add buf faint;
      render_inline buf (Cmarkit.Inline.Strikethrough.inline st);
      add buf reset
  | _ -> ()

let rec render_block ?(tight = false) buf block =
  match block with
  | Cmarkit.Block.Paragraph (p, _) ->
      render_inline buf (Cmarkit.Block.Paragraph.inline p);
      nl buf;
      if not tight then nl buf
  | Cmarkit.Block.Heading (h, _) ->
      let level  = Cmarkit.Block.Heading.level h in
      let color  = match level with 1 -> cyan_b | 2 -> blue_b | _ -> blue in
      let prefix = String.make level '#' ^ " " in
      add buf bold; add buf color; add buf prefix;
      render_inline buf (Cmarkit.Block.Heading.inline h);
      add buf reset;
      nl buf; nl buf
  | Cmarkit.Block.Code_block (cb, _) ->
      let lang =
        match Cmarkit.Block.Code_block.info_string cb with
        | Some (info, _) ->
            (match Cmarkit.Block.Code_block.language_of_info_string info with
             | Some (lang, _) -> lang | None -> "")
        | None -> ""
      in
      add buf faint;
      add buf (if lang = "" then "```" else "```" ^ lang);
      nl buf;
      List.iter (fun (line, _) -> add buf line; nl buf)
        (Cmarkit.Block.Code_block.code cb);
      add buf "```"; add buf reset;
      nl buf; nl buf
  | Cmarkit.Block.List (l, _) ->
      let type'    = Cmarkit.Block.List'.type' l in
      let is_tight = Cmarkit.Block.List'.tight l in
      let items    = Cmarkit.Block.List'.items l in
      List.iteri (fun i (item, _) ->
        let bullet = match type' with
          | `Unordered _ -> "• "
          | `Ordered (start, _) -> string_of_int (start + i) ^ ". "
        in
        add buf cyan_b; add buf bullet; add buf reset;
        render_block ~tight:is_tight buf (Cmarkit.Block.List_item.block item)
      ) items;
      if not tight then nl buf
  | Cmarkit.Block.Block_quote (bq, _) ->
      add buf blue; add buf "│ "; add buf reset;
      render_block buf (Cmarkit.Block.Block_quote.block bq)
  | Cmarkit.Block.Thematic_break _ ->
      add buf faint;
      for _ = 1 to 40 do add buf "─" done;
      add buf reset;
      nl buf; nl buf
  | Cmarkit.Block.Blocks (blocks, _) ->
      List.iter (render_block ~tight buf) blocks
  | Cmarkit.Block.Blank_line _ -> ()
  | _ -> ()

let render_to_string text =
  let doc = Cmarkit.Doc.of_string ~strict:false text in
  let buf = Buffer.create (String.length text * 2) in
  render_block buf (Cmarkit.Doc.block doc);
  Buffer.contents buf

(* --- Block-boundary detection --- *)

(* Return the byte offset just past the last \n\n (block separator) in [s],
   skipping over any additional consecutive newlines. Returns 0 if none found.
   We skip \n\n that appear to be inside a fenced code block (``` fence). *)
let find_stable_split s =
  let len = String.length s in
  let in_fence = ref false in
  let last_split = ref 0 in
  let i = ref 0 in
  while !i < len do
    (* Detect ``` at the start of a line — toggles fence state *)
    let at_line_start = !i = 0 || Char.equal s.[!i - 1] '\n' in
    if at_line_start && !i + 2 < len
       && Char.equal s.[!i] '`'
       && Char.equal s.[!i + 1] '`'
       && Char.equal s.[!i + 2] '`'
    then
      in_fence := not !in_fence;
    (* Block boundary: \n\n outside a fence *)
    if not !in_fence && !i + 1 < len
       && Char.equal s.[!i] '\n'
       && Char.equal s.[!i + 1] '\n'
    then begin
      let j = ref (!i + 2) in
      while !j < len && Char.equal s.[!j] '\n' do incr j done;
      last_split := !j;
      i := !j
    end else
      incr i
  done;
  !last_split

(* --- Public interface --- *)

let push t chunk =
  Buffer.add_string t.pending chunk;
  let s = Buffer.contents t.pending in
  let split = find_stable_split s in
  if split > 0 then begin
    let stable = String.sub s 0 split in
    let rest   = String.sub s split (String.length s - split) in
    print_string (render_to_string stable);
    flush stdout;
    Buffer.clear t.pending;
    Buffer.add_string t.pending rest
  end

let finish t =
  let remaining = Buffer.contents t.pending in
  if String.length remaining > 0 then begin
    print_string (render_to_string remaining);
    flush stdout
  end;
  Buffer.clear t.pending
