# Abstraction Guidelines

## 1. Reduce Parameter Passing with Context Records

When the same group of parameters is passed to multiple functions, bundle them into a record.

Rule of thumb: 3+ parameters passed together to 3+ functions → extract a context record. Context records should be immutable (use `with` for updates).

---

## 2. When to Extract a Module

Extract when:
- Code is used from 2+ other modules
- Code has a clear, nameable responsibility
- Code has internal state or invariants to protect

Keep inline when:
- Code is only used in one place
- The abstraction boundary is unclear

---

## 3. Interface-First Design

Define the `.mli` before implementing the `.ml`, especially for shared modules.

1. Write the `.mli` with types and function signatures
2. Document invariants and contracts
3. Implement the `.ml` to satisfy the interface

---

## 4. Functors for Cross-Layer Code Sharing

When multiple layers need the same pattern with different types, use functors.

```ocaml
module type METHOD_RENDERER = sig
  type output
  val should_skip : method_info -> bool
  val render : method_info -> output
end

module Make (R : METHOD_RENDERER) = struct
  let generate method_info =
    if R.should_skip method_info then None
    else Some (R.render method_info)

  let generate_all methods = List.filter_map generate methods
end
```

Use functors when: same algorithm with different types, cross-layer patterns that must stay in sync, configurable behaviour without runtime cost.

---

## 5. Layered Module Dependencies

```
┌─────────────────────────────────────┐
│           Application               │
└──────────────┬──────────────────────┘
               │ uses
               ▼
┌─────────────────────────────────────┐
│          Generation / Core          │
└──────────────┬──────────────────────┘
               │ uses
               ▼
┌─────────────────────────────────────┐
│         Infrastructure / Types      │
└─────────────────────────────────────┘
```

Lower layers never import from higher layers. Cross-cutting concerns live in infrastructure.

---

## 6. Extension Points for Future Features

When you know more cases will be added, use a registry rather than hard-coded dispatch.

```ocaml
module type ENTITY_GENERATOR = sig
  type t
  val name : string
  val generate : t -> output
end

let generators : (module ENTITY_GENERATOR) list ref = ref []
let register gen = generators := gen :: !generators

let generate_entity entity =
  List.find_map (fun (module G : ENTITY_GENERATOR) ->
    if String.equal G.name (entity_type entity) then Some (G.generate entity)
    else None) !generators
```

Use extension points when: more cases are known to be coming, external code needs to hook in, testing benefits from substitution.

---

## Checklist

- [ ] Functions with 5+ repeated parameters use a context record
- [ ] Shared code lives in infrastructure, not duplicated
- [ ] Public modules have `.mli` files
- [ ] No upward dependencies
- [ ] Duplicated cross-layer patterns use functors or shared modules
- [ ] Extension points exist for known future features
