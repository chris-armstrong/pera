# Pera — Agent Project Context

## Mandatory guidelines

* When working on major/complex changes, plan them and ask the user for feedback first
* Ask the user questions when things are unclear or ambiguous
* **Always load and read the individual code file** listed in `docs/guidelines/index.md` before planning or writing any code.

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
| `cohttp-eio`, `tls-eio`, `ca-certs` | HTTP/HTTPS client for provider SSE streams |
| `domain-name`, `uri` | DNS name handling and URI construction (HTTP stack support) |
| `mirage-crypto-rng` | Cryptographic RNG (required by TLS stack) |
| `yojson` | JSON encoding/decoding |
| `re` | Regular expressions (fallback for `grep` tool) |
| `fpath` | Cross-platform path handling |
| `decimal` | Decimal arithmetic |
| `uuidm` | UUID generation (session entry IDs) |
| `logs` | Structured logging |
| `cmarkit` | CommonMark rendering (drivers) |
| `ppx_deriving` | Deriving show, eq, etc. |
| `alcotest` | Unit testing framework |
| `qcheck-core`, `qcheck-alcotest` | Property-based testing |

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
│   ├── provider.{ml,mli}                      # Provider.S interface
│   ├── provider_registry.{ml,mli}             # Explicit registry (no global state)
│   ├── event_stream.{ml,mli}                  # ('event, 'result) Event_stream.t primitive
│   ├── sse_parser.{ml,mli}                    # Provider-agnostic SSE chunk parser
│   ├── http_client.{ml,mli}                   # Thin wrapper over cohttp-eio
│   ├── json_schema.{ml,mli}                   # Runtime JSON schema constructors
│   ├── json_repair.{ml,mli}                   # JSON repair utilities
│   ├── anthropic_provider.{ml,mli}            # Anthropic native API
│   ├── anthropic_request.{ml,mli}             # Request builder
│   ├── anthropic_interpreter.{ml,mli}         # Anthropic SSE → assistant_message_event
│   ├── openai_completions_provider.{ml,mli}   # OpenAI chat-completions
│   ├── openai_completions_request.{ml,mli}    # Request builder
│   └── openai_completions_interpreter.{ml,mli}# OpenAI SSE → assistant_message_event
│
├── pera_core/            # Agent loop — orchestration, tool execution, hooks
│   ├── agent_types.{ml,mli}      # agent_message, agent_event, hook types
│   ├── agent_loop.{ml,mli}       # The turn loop, tool execution, cancellation
│   ├── provider_adapter.{ml,mli} # Adapter between provider event stream and agent core
│   ├── model_window.{ml,mli}     # Context window sizes per model; compaction trigger defaults
│   └── token_estimator.{ml,mli}  # Conservative token count estimator (ceil(chars/3))
│
├── pera_core_test_util/  # Test doubles and Alcotest testables
│   ├── faux_provider.{ml,mli}    # Fake provider for testing agent_loop
│   └── pera_core_test_util.ml    # Re-exports
│
├── pera_env/             # Execution environment abstraction and OS-backed implementation
│   ├── execution_env.{ml,mli}    # Module types for FS, shell, and env abstractions (S, FILESYSTEM, SHELL)
│   └── local_env.{ml,mli}        # Local (real OS) implementation of Execution_env
│
├── pera_harness/         # Session infrastructure (logging, compaction, agent actor)
│   ├── agent_wrapper.{ml,mli}    # Actor/mailbox wrapper over Agent_loop.run with fan-out subscriptions
│   ├── compaction.{ml,mli}       # Pure summarisation algorithm for context compaction
│   ├── entry_id.{ml,mli}         # Session entry ID generation (UUIDv4-based)
│   ├── session_types.{ml,mli}    # Session JSONL entry types
│   └── session_writer.{ml,mli}   # Append-only JSONL session file writer
│
├── pera_agent/           # Top-level assembly — wires env, tools, session, and wrapper
│   └── agent_harness.{ml,mli}    # create/send/subscribe entry point for the full agent
│
└── pera_tools/           # Tool implementations (read, write, bash, grep)
    ├── read_tool.{ml,mli}        # Read file contents with line/offset limits
    ├── write_tool.{ml,mli}       # Write or overwrite files
    ├── bash_tool.{ml,mli}        # Execute shell commands
    ├── grep_tool.{ml,mli}        # Regex search (ripgrep-backed, named 'grep')
    ├── truncate.{ml,mli}         # Smart truncation for file listings and command output
    ├── tool_util.{ml,mli}        # Shared tool helpers (schema builders, text splitting)
    └── tools.{ml,mli}            # Assembly: all tool schemas + dispatch

bin/drivers/              # Thin drivers / CLI entry points
  conversation_driver.ml  # Interactive conversation loop
  loop_driver.ml          # Non-interactive agent loop
  provider_driver.ml      # Raw provider streaming test
  env_driver.ml           # Execution environment smoke test
  tool_driver.ml          # Individual tool smoke test
  harness_driver.ml       # Full harness integration test (includes autonomous compaction scenario)
  session_driver.ml       # Session JSONL inspection (includes compaction entry scenario)
  compaction_driver.ml    # Compaction module layer test (offline faux + optional real-model)
  live_driver.ml          # Live agent with terminal UI
```

### Package dependency graph

```
pera-types  (no internal deps)
    ↑
pera-provider  (depends on pera-types)
pera-env       (depends on pera-types)
    ↑
pera-core        (depends on pera-types, pera-provider)
pera-harness     (depends on pera-types, pera-provider)
    ↑
pera-core-test-util  (depends on pera-types, pera-provider, pera-core)
pera-tools           (depends on pera-types, pera-env, pera-core, pera-provider)
    ↑
pera-agent  (depends on pera-types, pera-env, pera-core, pera-provider, pera-harness, pera-tools)
```



### Coding Guideline priority order

When code guidelines conflict:

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
- **New tool** → `pera_tools`, depends on `pera_env`
- **New execution environment** → `pera_env`
- **Agent loop changes** → `pera_core`
- **Session infrastructure** (logging, compaction) → `pera_harness`
- **Top-level assembly / CLI wiring** → `pera_agent`; `Agent_harness.config.compaction` enables autonomous compaction (M6)
- **Test doubles / testables** → `pera_core_test_util`

---

## Meta-agent context

This project uses AI agents for its own development:

- `.opencode/agents/` — OpenCode-specific agents (executor, planner, reviewers)
- `.claude/agents/` — Claude-specific agents (executor, planner, reviewers)
- `.claude/commands/` — Custom slash commands (e.g. `orchestrate`)
- `.claude/hooks/` — Pre-tool hooks (e.g. `check_ml_conventions.sh`)
- `.claude/plans/` — Development plans (e.g. `m6-survivable-agent.md`)

These are part of the project's workflow, not runtime code.

---

## Key documents

| Document | What it covers |
|----------|---------------|
| `SPECIFICATION.md` | Full architectural specification (layers, data model, provider layer, agent core, harness, compaction, tools, CLI) |
| `USAGE.md` | How to run the development drivers (`provider_driver`, `conversation_driver`, `loop_driver`, `env_driver`, `tool_driver`) |
| `docs/usage/cli.md` | Pera CLI usage (options, interactive mode, configuration, environment variables) |
| `docs/usage/models-gen.md` | Model database generator (`pera-models-gen`) — converting models.dev JSON to `models.sexp` |
| `docs/guidelines/index.md` | Mandatory coding guidelines index |
| `dune-project` | Package definitions and dependencies |


