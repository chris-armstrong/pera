# Pera — Agent Project Context

## What this project is

Pera is an OCaml port of the **pi coding agent** (`github.com/earendil-works/pi`, MIT).  
It is a headless coding agent: a loop that calls an LLM, runs tools the model requests (read, write, bash, grep), feeds the results back, and repeats until done.  
The architecture is layered — provider layer, agent core, harness, tools, and a thin CLI — with the goal of keeping the core loop pure and portable while the harness binds it to a real OS.

Target runtime: **OCaml 5.4+** with **Eio** (structured concurrency).

---

## Libraries in use

| Library | Purpose |
|---------|---------|
| `containers` | Core data structures and utilities (open at the top of every `.ml` file) |
| `eio`, `eio_main`, `eio_linux` | Structured concurrency, fibres, cancellation, async I/O |
| `piaf` | HTTP client for provider SSE streams |
| `yojson` | JSON encoding/decoding |
| `re` | Regular expressions (fallback for `grep` tool) |
| `ppx_deriving` | Deriving show, eq, etc. |
| `alcotest` | Unit testing framework |
| `qcheck-core`, `qcheck-alcotest` | Property-based testing |

**Future / planned:** `fmt`, `fpath`, `uuidm` (mentioned in guidelines; may already be referenced in uncommitted code).

Dune version: **3.16**.  
Opam packages generated from `dune-project`.

---

## Module structure

```
lib/
├── pera_types/           # Pure type definitions (no IO)
│   └── types.{ml,mli}    # Messages, tool schemas, events, errors, sessions
│
├── pera_provider/        # Provider layer — talks to LLMs over HTTP
│   ├── provider.{ml,mli}                 # Provider.S interface
│   ├── provider_registry.{ml,mli}        # Explicit registry (no global state)
│   ├── event_stream.{ml,mli}             # ('event, 'result) Event_stream.t primitive
│   ├── sse_parser.{ml,mli}               # Provider-agnostic SSE chunk parser
│   ├── http_client.{ml,mli}              # Thin wrapper over piaf
│   ├── json_schema.{ml,mli}              # Runtime JSON schema constructors
│   ├── json_repair.{ml,mli}              # JSON repair utilities
│   ├── anthropic_provider.{ml,mli}       # Anthropic native API
│   ├── anthropic_request.{ml,mli}        # Request builder
│   ├── anthropic_interpreter.{ml,mli}    # Anthropic SSE → assistant_message_event
│   ├── openai_completions_provider.{ml,mli}  # OpenAI chat-completions (Zen / Go)
│   ├── openai_completions_request.{ml,mli}     # Request builder
│   └── openai_completions_interpreter.{ml,mli} # OpenAI SSE → assistant_message_event
│
├── pera_core/            # Agent loop — orchestration, tool execution, hooks
│   ├── agent_types.{ml,mli}      # agent_message, agent_event, hook types
│   ├── agent_loop.{ml,mli}       # The turn loop, tool execution, cancellation
│   └── provider_adapter.{ml,mli} # Adapter between provider event stream and agent core
│
└── pera_core_test_util/  # Test doubles and Alcotest testables
    ├── faux_provider.{ml,mli}    # Fake provider for testing agent_loop
    └── pera_core_test_util.ml   # Re-exports

bin/drivers/              # Thin drivers / CLI entry points (conversation, loop, provider)
```

### Package dependency graph

```
pera-types  (no internal deps)
    ↑
pera-provider  (depends on pera-types)
    ↑
pera-core  (depends on pera-types, pera-provider)
    ↑
pera-core-test-util  (depends on all three)
```

---

## Coding guidelines

**Entry point:** `docs/guidelines/index.md`

This file lists **all mandatory guideline documents** that must be read before writing or reviewing code.


### Guideline priority order

When guidelines conflict:

1. Correctness (no bugs)
2. Type safety (catch errors at compile time)
3. Clarity (readable code)
4. Consistency (match surrounding code)
5. Brevity (less code when equally clear)

---

## Build, test, and checks

```bash
# Build everything
dune build

# Run tests
dune test
# or
dune runtest

# Check formatting (empty .ocamlformat → ocamlformat defaults)
ocamlformat --check $(git ls-files '*.ml' '*.mli')

# Fix formatting
ocamlformat --inplace <file>

# Run semgrep rules (enforced in CI)
semgrep --config .semgrep/ocaml-guidelines.yml
```

A pre-commit hook in `scripts/pre-commit` checks `ocamlformat` on staged `.ml`/`.mli` files.  
Install it manually with:

```bash
ln -sf ../../scripts/pre-commit .git/hooks/pre-commit
```

---

## Semgrep rules

`.semgrep/ocaml-guidelines.yml` enforces:

- **Banned partial functions:** `List.hd`, `List.tl`, `List.nth`, `Map.find`, `Hashtbl.find`, `int_of_string`, `float_of_string`, `Option.get`
- **No `Stdlib.(=)`** — use `String.equal`, `Int.equal`, etc.
- **No silent ignores** of `Result` or `Option` arms
- **Eio concurrency:** prefer `Eio.Promise` over `Eio.Condition` for one-shot signals

---

## Where to add new code

- **New types** (messages, events, errors) → `pera_types`
- **New provider** (e.g. a third LLM API) → `pera_provider`, implement `Provider.S`, add to `provider_registry`
- **New tool** → depends on the harness layer (not yet in `lib/` as of this writing; see `SPECIFICATION.md` §9)
- **Agent loop changes** → `pera_core`
- **Test doubles / testables** → `pera_core_test_util`

---

## Meta-agent context

This project uses AI agents for its own development:

- `.opencode/agents/` — OpenCode-specific agents (executor, planner, reviewers)
- `.claude/agents/` — Claude-specific agents (executor, planner, reviewers)
- `.claude/plans/` — Development plans (e.g. `m2-agent-core.md`)

These are part of the project's workflow, not runtime code.

---

## Key documents

| Document | What it covers |
|----------|---------------|
| `SPECIFICATION.md` | Full architectural specification (layers, data model, provider layer, agent core, harness, compaction, tools, CLI) |
| `USAGE.md` | How to run the development drivers (`provider_driver`, `conversation_driver`, `loop_driver`) |
| `docs/guidelines/index.md` | Mandatory coding guidelines index |
| `dune-project` | Package definitions and dependencies |


