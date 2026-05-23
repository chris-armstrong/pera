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

## Checklist

- [ ] No catch-all `_` that hides unhandled cases in closed variants
- [ ] Catch-all only used for intentionally grouped cases or open types
- [ ] Pattern matching preferred over if-else chains
- [ ] Fields destructured in pattern, not accessed after
- [ ] Or-patterns used for shared handling
- [ ] Deep nesting flattened with nested patterns or bind operators
