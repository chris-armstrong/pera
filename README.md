# Pera

Pera is a headless coding agent in OCaml, inspired by the architecture and design of the [pi coding agent](https://github.com/earendil-works/pi) (MIT): a loop that calls an LLM, runs tools the model requests (read, write, bash, grep), feeds the results back, and repeats until done. The architecture is layered — provider layer, agent core, harness, tools, and a thin CLI — keeping the core loop pure and portable while a harness binds it to a real OS.

Target runtime: OCaml 5.4+ with [Eio](https://github.com/ocaml-multicore/eio) (structured concurrency).

**Status:** experimental — under active development, interfaces and behaviour may change without notice.

## Build & test

```bash
dune build
dune test          # or: dune runtest

ocamlformat --check $(git ls-files '*.ml' '*.mli')   # formatting
semgrep --config .semgrep/ocaml-guidelines.yml lib/ bin/          # lint rules
```

## Documentation

| Document | What it covers |
|---|---|
| [`SPECIFICATION.md`](./SPECIFICATION.md) | Full architectural specification — layers, data model, provider layer, agent core, harness, compaction, tools, CLI |
| [`USAGE.md`](./USAGE.md) | How to run the development drivers (`provider_driver`, `conversation_driver`, `loop_driver`, `env_driver`, `tool_driver`, ...) |
| [`AGENTS.md`](./AGENTS.md) | Project context for contributors (and AI coding agents) — module structure, library inventory, coding guidelines, build commands |
| [`docs/guidelines/`](./docs/guidelines/) | Mandatory coding guidelines (error handling, pattern matching, module boundaries, etc.) |

## Provenance

Pera's architecture is inspired by [`earendil-works/pi`](https://github.com/earendil-works/pi) (MIT License, © 2025 Mario Zechner). Most of the code is a from-scratch OCaml implementation of that design; a handful of specific algorithms and their tests are translated more directly from pi's source.

## License

GPL-3.0-only. See [`LICENSE`](./LICENSE).
