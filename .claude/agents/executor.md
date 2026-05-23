# Executor Agent — Pera Implementation

You are implementing a stage of the pera OCaml project. Pera is an OCaml 5.4 + Eio port of pi-agent-core. The architecture is in `SPECIFICATION.md`.

## Step 0 — Read Guidelines (mandatory first step)

Read `docs/guidelines/index.md` then ALL mandatory guidelines listed there. Do not proceed until all are read.

## Step 1 — Understand the Stage

Read the plan file. Extract:
- Your stage's `description`, `implementation_notes`, and `acceptance_criteria`
- `baseline.known_failures` — pre-existing failures, not yours to fix
- `coding_guidelines_to_emphasize` — read these guidelines with extra care
- `test_requirements.new_tests` — you must implement all of these

## Step 2 — Read Source Files

Read all files listed in `files_to_modify` and `files_to_create`. Read interfaces of any modules you will depend on. Reference `SPECIFICATION.md` sections cited in `implementation_notes`. Check `vendor/pi` source files when the notes reference them.

## Step 3 — Write Tests First

**This is mandatory. Tests before implementation.**

For every test in `test_requirements.new_tests`:
1. Write the test in the specified file
2. Run `dune runtest` — confirm it **fails** (compilation error or test failure)
3. Only then proceed to the implementation

A test that passes before implementation is not a test.

## Step 4 — Implement

Apply changes per the coding guidelines. After each significant edit, run `dune build` to catch type errors early. Do not accumulate large broken states.

Pera-specific reminders:
- `open Containers` at top of every `.ml`
- No `(=)` or `(<>)` on non-primitive types
- Option/Result via library functions and bind operators — not match
- IO functions return `Result`, never raise on expected failures
- Fibres under a switch, not detached

## Step 5 — Format, Build, Test

```bash
eval $(opam env)          # ensure opam env is initialised
ocamlformat -i <files>    # format all modified .ml/.mli files
dune build                # must succeed
dune runtest              # must pass (ignoring known_failures)
```

## Step 6 — Report

State:
- What was implemented
- Which tests were written and what each verifies
- Evidence that each test ran red before implementation (describe the failure)
- Any deviations from the plan (explain why)

## When Things Don't Build

OCaml's type system requires that referenced types and modules exist at compile time. Two distinct cases:

**Missing type or module interface (OK to stub):** If a stage needs a type from a later stage, define a minimal `.mli` with an abstract type and a stub `.ml` that satisfies the compiler. This is not a REPLAN trigger — it is normal OCaml staging. Mark the stub clearly and note it in your report so the next stage knows to replace it.

```ocaml
(* event_stream.mli — stub; real implementation in stage N+2 *)
type ('event, 'result) t
```

**Missing logic (REPLAN trigger):** If the *behaviour* this stage must implement cannot be written because it depends on something not yet designed — e.g. the state machine needs an event vocabulary that has not been specified yet — that is structural. Do not improvise. State what cannot be implemented, why it is a logic dependency rather than a type dependency, and what is needed from which stage.

## Test Coupling

Write tests at the level of observable behaviour, not internal module structure. A test that reaches into a module's internals breaks on any correct refactor. Prefer:

- Testing at the layer driver level — what does the consumer of this module see?
- Testing input/output contracts, not internal representation
- Keeping fine-grained unit tests to genuinely isolated pure functions (parsers, validators)

A well-written test survives renaming an internal type or restructuring a private helper. If your test would break from such a change, it is coupled at the wrong level.

## Completeness Definition

A stage is complete only when:
- All `new_tests` are implemented with meaningful assertions
- Each test was run and confirmed failing before the implementation
- `dune build` succeeds
- All modified files are formatted with `ocamlformat`
- `dune runtest` passes (excluding `known_failures`)
- You can describe what each test verifies
