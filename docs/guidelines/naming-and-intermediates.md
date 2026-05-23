# Naming and Intermediate Values Guidelines

## 1. Named Intermediate Values over Long Pipelines

Break pipelines of 3+ stages into named `let` bindings. Each name documents what the value represents.

```ocaml
(* Bad: anonymous pipeline — intent buried in structure *)
let summarize data =
  data
  |> List.filter (fun x -> x.active && x.score > 0)
  |> List.map (fun x -> (x.category, x.score))
  |> List.fold_left accumulate_by_category Map.empty
  |> Map.to_list
  |> List.sort (fun (_, a) (_, b) -> Int.compare b a)

(* Good: names document each step *)
let summarize data =
  let active_with_scores = List.filter (fun x -> x.active && x.score > 0) data in
  let by_category = List.map (fun x -> (x.category, x.score)) active_with_scores in
  let totals = List.fold_left accumulate_by_category Map.empty by_category in
  Map.to_list totals |> List.sort (fun (_, a) (_, b) -> Int.compare b a)
```

---

## 2. Rules of Thumb

- **3+ pipeline stages** → name intermediates
- **Anonymous function > 1 line** → extract and name it
- **Complex predicate** → name it

```ocaml
(* Bad: inline predicate is hard to read and test *)
let valid = List.filter (fun m ->
  not m.deprecated && not (List.mem m.name excluded) &&
  List.for_all is_supported_type m.params) methods

(* Good: named predicate *)
let is_valid_method m =
  not m.deprecated && not (List.mem m.name excluded) &&
  List.for_all is_supported_type m.params

let valid = List.filter is_valid_method methods
```

---

## 3. Naming Conventions

- Values and functions: `snake_case`
- Types: `snake_case`
- Modules: `PascalCase`
- Avoid abbreviations; use full words that describe purpose

Acceptable short names: `f` in higher-order signatures, `acc` in folds, `i`/`j` for indices, `s` for a single string being processed.

---

## 4. Boolean Names

Use names that read naturally in `if` conditions: `is_*`, `has_*`, `should_*`, `can_*`.

```ocaml
(* Bad *)  let not_empty = ...  let flag = ...
(* Good *) let has_methods = ...  let is_deprecated = ...  let should_skip = ...
```

---

## Checklist

- [ ] Pipelines with 3+ stages use named intermediates
- [ ] Anonymous functions > 1 line are extracted and named
- [ ] Complex predicates are named
- [ ] Boolean names read naturally in `if` statements
