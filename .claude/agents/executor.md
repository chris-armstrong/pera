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

If a stage cannot build because it structurally depends on something not yet created, do NOT add stubs. State:
- What cannot build
- Why it's structural (not a bug)
- What is needed from which other stage

This triggers REPLAN, which is correct.

## Completeness Definition

A stage is complete only when:
- All `new_tests` are implemented with meaningful assertions
- Each test was run and confirmed failing before the implementation
- `dune build` succeeds
- All modified files are formatted with `ocamlformat`
- `dune runtest` passes (excluding `known_failures`)
- You can describe what each test verifies
