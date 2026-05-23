# Pera-Specific Guidelines

## 1. Open Containers in Every File

Every `.ml` file must open `Containers` at the top. This is non-negotiable.

```ocaml
open Containers

(* rest of file *)
```

This provides the safe alternatives to the stdlib, removes structural equality,
and makes List, Option, Result, etc. consistently available.

---

## 2. No Structural Equality

`Containers` removes `Stdlib.(=)` and `Stdlib.(<>)` by design. Never use them
on non-primitive types.

### Bad
```ocaml
if event = AME_done then ...
if errors <> [] then ...
```

### Good
```ocaml
match event with AME_done -> ... | _ -> ...
if not (List.is_empty errors) then ...

(* For primitive types only: *)
if Int.equal n 0 then ...
if String.equal s "" then ...
```

---

## 3. Library Functions Over Match on Option and Result

Avoid `match` expressions over `option` and `result` when a library function
expresses the intent more directly. Use the pipe operator to chain.

### Bad
```ocaml
let x =
  match find_thing () with
  | None -> default
  | Some v -> v

let y =
  match do_thing () with
  | Error _ -> None
  | Ok v -> Some v
```

### Good
```ocaml
let x = find_thing () |> Option.value ~default

let y = do_thing () |> Result.to_option
```

Prefer `let*` / `let+` bind operators for sequential chains (see
`nesting-and-control-flow.md`). Use `match` when the two branches have
meaningfully different logic that does not reduce to a combinator.

---

## 4. Tests Before Implementation (TDD)

Write the test first. Run it and confirm it fails before writing the
implementation. A test that was never red proves nothing.

### Process for each unit of behaviour:
1. Write the test in the appropriate test file
2. Run `dune runtest` — confirm it fails with a compilation error or a test
   failure (not a trivially-passing test)
3. Write the minimum implementation to make it pass
4. Run `dune runtest` again — confirm green

This applies to layer drivers too: write the driver that exercises the
expected behaviour, confirm it fails, then implement.

---

## 5. Eio Concurrency Conventions

- Every function that does IO takes `sw:Eio.Switch.t` as a labelled argument
- Cancellation via `Eio.Cancel.t`, not custom flags
- Use structured concurrency: fibres are children of a switch, not detached
- Backpressure via bounded `Eio.Stream.t` (default capacity 32)
- `Eio.Promise.t` for single-shot completion signals (not streams)

### Pattern: fibre + stream
```ocaml
let run_producer ~sw stream =
  Eio.Fiber.fork ~sw (fun () ->
    (* push events until done *)
    Eio.Stream.add stream event;
    Eio.Stream.close stream)

let consume stream =
  let rec loop () =
    match Eio.Stream.take_opt stream with
    | None -> ()
    | Some event -> handle event; loop ()
  in
  loop ()
```

---

## 6. IO Operations Return Result, Not Raise

All IO-facing functions return `(_, error) result`. They never raise on
expected failure modes (file not found, permission denied, timeout).

Programmer errors — calling functions in wrong order, violating invariants —
may raise. They are bugs, not recoverable conditions.

---

## Checklist

Before submitting code, verify:

- [ ] Every `.ml` file starts with `open Containers`
- [ ] No `(=)` or `(<>)` on non-primitive types
- [ ] Option/Result handled with library functions or bind operators, not match
- [ ] Tests were written before implementation and confirmed failing first
- [ ] IO functions that can fail return `Result`, never raise
- [ ] Fibres are created under a switch, not detached
