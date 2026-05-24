# Pattern Matching Guidelines

## 1. Pattern Matching Completeness

Never use a catch-all `_` on a closed variant. When you add a new variant, the compiler shows every place that needs updating.

```ocaml
(* Bad: Suspended and Deleted silently conflated *)
let status_message = function
  | Pending -> "Waiting for approval"
  | Active -> "Account is active"
  | _ -> "Account unavailable"

(* Good: compiler enforces exhaustiveness *)
let status_message = function
  | Pending -> "Waiting for approval"
  | Active -> "Account is active"
  | Suspended -> "Account temporarily suspended"
  | Deleted -> "Account has been deleted"
```

---

## 2. When Catch-All IS Acceptable

- Grouping "all others" explicitly: `| Pending | Suspended | Deleted -> false`
- Matching on open types (strings, integers): `| other -> `Unknown other`
- Unknown variants in an open external protocol (e.g. SSE event types) — document the catch-all

---

## 3. Prefer Pattern Matching over If-Else

```ocaml
(* Bad *)
let classify x =
  if x < 0 then "negative" else if x = 0 then "zero" else "positive"

(* Good *)
let classify = function
  | x when x < 0 -> "negative"
  | 0 -> "zero"
  | _ -> "positive"
```

---

## 4. Destructure in Pattern Matches

```ocaml
(* Bad: accessing fields after the match *)
let process entity =
  match entity with
  | Class c -> generate_class c.name c.methods
  | Interface i -> generate_interface i.name i.methods

(* Good: destructure in the pattern *)
let process = function
  | Class { name; methods; _ } -> generate_class name methods
  | Interface { name; methods; _ } -> generate_interface name methods
```

---

## 5. Use Or-Patterns for Shared Handling

```ocaml
let handle = function
  | Add x | Sub x | Mul x -> log "operation"; compute x
  | Div x -> handle_div x
```

---

## 6. Avoid Deep Nesting in Patterns

When match arms contain further matches, flatten using nested patterns in a single match, or use bind operators (see `nesting-and-control-flow.md`).

```ocaml
(* Bad: three nested match levels *)
let process opt =
  match opt with
  | Some result ->
    match result with
    | Ok (Some data) -> use data
    | Ok None -> default ()
    | Error e -> handle_error e
  | None -> default ()

(* Good: single match with nested patterns *)
let process = function
  | Some (Ok (Some data)) -> use data
  | Some (Error e) -> handle_error e
  | Some (Ok None) | None -> default ()
```

If the branches are sequential Result/Option operations, prefer `let*` from `nesting-and-control-flow.md` instead.

---

## 7. Never Return a Zero-Value Sentinel from a Catch-All

Returning `""`, `0`, `false`, `None`, `[]`, or any other zero-value from a catch-all arm silently discards unhandled cases. The compiler cannot warn you, and the bug surfaces far from the source.

```ocaml
(* Bad: non-AText content is silently dropped as "" *)
let extract_text blocks =
  List.map (function AText s -> s | _ -> "") blocks

(* Bad: unknown stop_reason mapped to a default that may be wrong *)
let stop_reason_str = function
  | EndTurn -> "end_turn"
  | _ -> ""
```

If a case genuinely cannot occur, say so explicitly:

```ocaml
(* Good: impossible cases made loud *)
let extract_text blocks =
  List.map (function
    | AText s -> s
    | AThinking _ | AToolCall _ ->
        failwith "extract_text: non-text block in text-only stream") blocks
```

If a case may occur but has no sensible mapping, return `Result` or `Option`:

```ocaml
(* Good: caller decides what to do with unexpected variants *)
let text_of_block = function
  | AText s -> Some s
  | AThinking _ | AToolCall _ -> None
```

If you are mapping an open external value (a string from an API, an integer code) to an internal type, map the unknown case to an explicit error variant — not a default that pretends to be success:

```ocaml
(* Bad: unknown stop reason silently becomes EndTurn *)
let parse_stop_reason = function
  | "end_turn" -> EndTurn
  | "tool_use" -> ToolUse
  | _ -> EndTurn  (* wrong: hides API changes *)

(* Good: unknown becomes an explicit Error variant *)
let parse_stop_reason = function
  | "end_turn" -> EndTurn
  | "tool_use" -> ToolUse
  | "max_tokens" -> MaxTokens
  | _ -> Error  (* or return (Error "unknown stop_reason") if caller needs the string *)
```

The test analogue of this rule: `| _ -> ()` in a test assertion is the same smell — it silently passes when it should fail.

---

## Checklist

- [ ] No catch-all `_` that hides unhandled cases in closed variants
- [ ] Catch-all only used for intentionally grouped cases or open types
- [ ] No zero-value sentinel (`""`, `0`, `[]`, `None`, `false`) returned from a catch-all arm
- [ ] Unknown external values mapped to an explicit error variant, not a silent default
- [ ] Impossible cases use `failwith` / `assert false`, not a silent zero value
- [ ] Pattern matching preferred over if-else chains
- [ ] Fields destructured in pattern, not accessed after
- [ ] Or-patterns used for shared handling
- [ ] Deep nesting flattened with nested patterns or bind operators
