# Pera CLI — Phased Implementation Plan

> Derived from: `.claude/plans/pera-cli.md` (spec v0.3)
> Status: draft (rev 2 — incorporates review feedback)
>
> Convention: every stage must leave `dune build` green. Tests for a stage should
> be written at the start of the stage and must pass by the end of it (failing
> compilation is acceptable mid-stage; failing Alcotest assertions are not
> acceptable at stage end). Each phase ends with a full `dune test` + format
> check before moving on.
>
> **Commits:** commit after every stage using Conventional Commits style
> (e.g. `refactor(connector): rename Provider to Connector`,
> `feat(anthropic): emit thinking block and beta header`,
> `test(config): add models.sexp parsing tests`). Keep one commit per stage;
> do not squash phases. Run the stage's verify step (`dune build && dune test`)
> before committing so every commit is green.
>
> **No stage/phase numbers in code or commits.** Stage and phase numbers are
> ephemeral planning artefacts — they carry no meaning once the work is landed.
> Do not reference them in commit messages, PR/branch titles, doc comments,
> `[@@deprecated "..." ]` strings, module docs, or inline comments. Write
> comments and commit subjects as if the plan's numbering did not exist.
> (This header is the only place the numbering is allowed.)
>
> **Containers alignment:** every `.ml` file begins with `open Containers`. This
> re-exports `CCResult` as `Result`, `CCOption` as `Option`, `CCList` as `List`,
> etc. Use the Containers APIs (`Result.get_or ~default`, `Result.get_exn`,
> `Option.get_or ~default`, `List.find_opt`, `String.equal`, …). Do **not** use
> `Result.get_or_else` (it does not exist) or stdlib `List.hd`/`List.nth`
> (banned by semgrep). For "print error and exit 1" CLI patterns, define a
> local `or_die` helper rather than `Result.get_or_failwith` (which raises with
> a traceback).
>
> **Eio / fpath alignment:** use `Eio.Stdenv.secure_random` for cryptographic
> randomness (not `Random.State`); use `Eio.Path` / `fpath` for filesystem path
> construction; use `Eio.Stdenv.stdin` for interactive input. Wall-clock local
> time remains `Unix.gettimeofday` + `Unix.localtime` (Eio exposes only a
> monotonic clock). Process env-var reading is `Sys.getenv_opt` — there is no
> Eio primitive for it — but it is always threaded in as a function parameter
> (see §Env functor) so tests inject a mock without `Unix.putenv`.

---

## Reading order for implementors

Before writing any code, read all files listed in `docs/guidelines/index.md`.
Then read `AGENTS.md`. Then read the relevant section of the spec
(`.claude/plans/pera-cli.md`).

**Current-source-state check:** every Phase 0 stage begins with a one-line
confirmation of today's code shape (the "BEFORE" claim). If the claim does not
match the source, stop and re-scope the stage before proceeding.

---

## Phase 0 — Prerequisites

Six breaking changes that must land before `pera-cli` can be built. Stages
0.1–0.4 are pure refactors (no external behaviour change). Stages 0.5–0.6 are
small additive API changes. Stage 0.2b is the one genuine *feature* addition
(thinking emission); it is split out from the field-move refactor (0.2a) so the
history is clean.

---

### Stage 0.1 — Connector rename

**Scope:** Rename the OCaml API barrier for LLM HTTP calls from `Provider` to
`Connector`. Pure naming change; no logic changes.

**Current source state (verified):** `lib/pera_provider/` exists with
`provider.{ml,mli}`, `provider_registry.{ml,mli}`, `anthropic_provider.{ml,mli}`,
`anthropic_interpreter.{ml,mli}`, `openai_completions_provider.{ml,mli}`,
`openai_completions_interpreter.{ml,mli}`, `anthropic_request.{ml,mli}`,
`openai_completions_request.{ml,mli}`, plus `event_stream`, `http_client`,
`json_schema`, `json_repair`, `sse_parser`. `lib/pera_core/provider_adapter.{ml,mli}`
exists. Package `pera-provider` exists in `dune-project`.

**Rename map:**

| Old | New |
|---|---|
| `lib/pera_provider/` | `lib/pera_connector/` |
| `provider.{ml,mli}` | `connector.{ml,mli}` |
| `provider_registry.{ml,mli}` | `connector_registry.{ml,mli}` |
| `anthropic_provider.{ml,mli}` | `anthropic_connector.{ml,mli}` |
| `openai_completions_provider.{ml,mli}` | `openai_completions_connector.{ml,mli}` |
| `provider_adapter.{ml,mli}` (in `lib/pera_core/`) | `connector_adapter.{ml,mli}` |
| package `pera-provider` | `pera-connector` |
| module `Provider.S` | `Connector.S` |
| module `Provider_registry` | `Connector_registry` |
| module `Provider_adapter` | `Connector_adapter` |
| module `Anthropic_provider` | `Anthropic_connector` |
| module `Openai_completions_provider` | `Openai_completions_connector` |

**Kept as-is (not renamed, but moved with the directory):**
`anthropic_interpreter`, `openai_completions_interpreter`, `event_stream`,
`http_client`, `json_schema`, `json_repair`, `sse_parser`,
`openai_completions_request`, `anthropic_request`. State this explicitly so
implementors don't try to rename them.

**Files to create/rename:**
- Move all files from `lib/pera_provider/` → `lib/pera_connector/` (rename the
  directory)
- Move `lib/pera_core/provider_adapter.{ml,mli}` →
  `lib/pera_core/connector_adapter.{ml,mli}`
- Update `lib/pera_connector/dune` — library name `pera_connector`, package
  `pera-connector`
- Update `lib/pera_core/dune` to reference renamed file

**Search and replace (all `.ml`, `.mli`, `dune`, `dune-project` files):**
- `Pera_provider.Provider` → `Pera_connector.Connector`
- `Pera_provider.Provider_registry` → `Pera_connector.Connector_registry`
- `Pera_provider.Provider_adapter` (in pera_core) → `Pera_core.Connector_adapter`
- `pera_provider` (library) → `pera_connector`
- `pera-provider` (package) → `pera-connector`
- `Anthropic_provider` → `Anthropic_connector`
- `Openai_completions_provider` → `Openai_completions_connector`

**dune-project:** rename the `pera-provider` package entry to `pera-connector`.
Update all `(pera-provider (= :version))` deps to `(pera-connector (= :version))`.

**Tests:** test directories under `lib/pera_connector/test/` replace
`lib/pera_provider/test/`. No test logic changes — just updated module refs.

**Verify:** `dune build && dune test` green, `ocamlformat --check` clean.

---

### Stage 0.2a — Move thinking field from `context` to `simple_stream_options` (refactor only)

**Scope:** Remove `thinking : bool` from `Connector.context`; add
`thinking_budget_tokens : int option` to `Connector.simple_stream_options`.
No behaviour change in this stage — existing call sites set
`thinking_budget_tokens = None`, which preserves today's "thinking never
enabled" behaviour. (Anthropic doesn't emit a thinking block today anyway; see
0.2b.) Update all call sites.

**Current source state (verified):**
- `Connector.context` has `thinking : bool`; `build_provider_context` in
  `agent_loop.ml` passes `~thinking:false` hardcoded; `apply_turn_update`
  ignores `update.thinking` ("deferred to Stage 7").
- `anthropic_request.build_request_body` does **not** emit a `"thinking"` key
  and `anthropic_connector` does **not** send an `anthropic-beta` header. So
  `context.thinking` is currently a dead field for Anthropic.
- `openai_completions_request.build_request_body` **does** gate
  `compat.enable_thinking_field` on `context.thinking = true`.

**Changes to `lib/pera_connector/connector.mli` (`connector.ml`):**

```ocaml
(* REMOVE from context: *)
thinking : bool;

(* ADD to simple_stream_options: *)
thinking_budget_tokens : int option;
(* None = thinking disabled (no betas header, no thinking block).
   Some n = enable extended thinking with budget n tokens. *)
```

Add `thinking_budget_tokens = None` to every `simple_stream_options` literal in
the codebase (harness, drivers, tests, faux_provider). Remove `thinking` from
every `context` literal.

**Changes to `lib/pera_connector/openai_completions_request.ml`:**
- Change the `with_thinking` match from `(context.thinking, compat.enable_thinking_field)`
  to `(options.thinking_budget_tokens, compat.enable_thinking_field)`:
  - `Some _, Some field` → emit `(field, `Bool true)`.
  - `None, _` → omit.
  This preserves today's OpenAI behaviour exactly (today `context.thinking` is
  always `false` at the call site, so the field is never emitted; after 0.2a
  `options.thinking_budget_tokens` is always `None`, same result).

**Changes to `lib/pera_connector/anthropic_request.ml`:**
- No behaviour change in 0.2a. The request builder still does not emit a
  thinking block. (0.2b adds it, gated on `options.thinking_budget_tokens`.)

**Changes to `lib/pera_core/agent_types.mli` / `.ml` — introduce the
`thinking_update` ADT (replaces the old `thinking : bool option` field):**

```ocaml
type thinking_update =
  | Inherit          (* keep the current budget setting (no change) *)
  | Budget  of int   (* enable extended thinking with this budget *)
  | Disabled         (* disable extended thinking *)
[@@deriving show, eq]

type turn_update = {
  messages : Pera_types.Types.agent_message list option;
  model    : Pera_types.Types.model option;
  thinking : thinking_update;   (* was: bool option *)
}
[@@deriving show, eq]
```

Rationale: the nested `int option option` encoding (Some Some / Some None /
None) is unreadable and inconsistent with the rest of the system, which uses
flat `int option` for budgets. The ADT names all three states explicitly. The
default / "no update" value is `Inherit` (replaces the old `None`).

**Changes to `lib/pera_core/agent_loop.ml`:**
- Add a mutable `current_thinking_budget : int option ref` initialised from
  `config.options.thinking_budget_tokens`.
- `build_provider_context`: drop the `~thinking` argument (the field is gone
  from `Connector.context`).
- When building `options` each turn:
  `{ !options_ref with thinking_budget_tokens = !current_thinking_budget }`.
- `apply_turn_update`: replace `ignore update.thinking` with:
  ```ocaml
  (match update.thinking with
   | Inherit -> ()
   | Budget n -> current_thinking_budget := Some n
   | Disabled -> current_thinking_budget := None)
  ```
  Thread `current_thinking_budget` into `apply_turn_update` as a new ref
  argument.
- Remove the hardcoded `~thinking:false` at the `build_provider_context` call
  site.

**Changes to `lib/pera_agent/agent_harness.ml`:**
- `options` literal: add `thinking_budget_tokens = None` (Stage 0.4 wires the
  real value).
- `prepare_hook` return: change `thinking = None` → `thinking = Inherit`.

**All other `simple_stream_options` construction sites** (drivers, tests,
faux_provider): add `thinking_budget_tokens = None`.
**All `context` literals:** remove the `thinking` field.

**Tests (`lib/pera_connector/test/anthropic_request_test.ml`,
        `lib/pera_core/test/agent_loop_test.ml`):**
- Update existing tests to the new record shapes. No new behaviour assertions
  in 0.2a (those land in 0.2b).
- Add one unit test for `apply_turn_update` covering all three
  `thinking_update` arms (`Inherit` leaves budget unchanged; `Budget n` sets
  it; `Disabled` clears it).

**Verify:** `dune build && dune test` green. `grep -rn "context.thinking\|\.thinking = " lib/ bin/` should show no `bool` thinking literals remaining (only `thinking_update` constructors in `turn_update` positions).

---

### Stage 0.2b — Emit thinking block + beta header (Anthropic feature)

**Scope:** Make `Anthropic_connector` actually request extended thinking when
`options.thinking_budget_tokens` is `Some n`. This is a new feature (today
Anthropic never requests thinking), split out from 0.2a so the refactor diff
and the feature diff are separable.

**Changes to `lib/pera_connector/anthropic_request.ml`:**
- In `build_request_body`, after `with_temperature`, add a `with_thinking` step:
  ```ocaml
  let with_thinking =
    match options.thinking_budget_tokens with
    | None -> with_temperature
    | Some budget ->
        with_temperature
        @ [ ("thinking", `Assoc [ ("type", `String "enabled");
                                   ("budget_tokens", `Int budget) ]) ]
  in
  `Assoc with_thinking
  ```
  (Insert `"thinking"` in the correct alphabetical position if the body is
  sorted; confirm against `sort_assoc_pairs` usage. The existing code sorts
  some sections — keep the body consistent.)

**Changes to `lib/pera_connector/anthropic_connector.ml`:**
- `build_headers` gains a `?thinking:bool` parameter:
  ```ocaml
  let build_headers ?(thinking = false) api_key =
    let base = [
      ("x-api-key", api_key);
      ("anthropic-version", anthropic_version);
      ("content-type", "application/json");
      ("accept", "text/event-stream");
    ] in
    if thinking then
      ("anthropic-beta", "interleaved-thinking-2025-05-14") :: base
    else base
  ```
  (Header order: dune/cohttp normalises; place the beta header first or last
  consistently.)
- `do_request`: pass `~thinking:(options.thinking_budget_tokens <> None)` to
  `build_headers`.

**Tests (`lib/pera_connector/test/anthropic_request_test.ml`):**
- Add: when `thinking_budget_tokens = None`, no `"thinking"` key in JSON body,
  no `anthropic-beta` header.
- Add: when `thinking_budget_tokens = Some 8000`, JSON body contains
  `"thinking": {"type": "enabled", "budget_tokens": 8000}` and the request
  headers include `anthropic-beta: interleaved-thinking-2025-05-14`.
- Add: `budget_tokens` is always at least 1024 (Anthropic minimum). If the
  resolver can produce a smaller value, add a guard here or in the resolver;
  document the choice. (See Stage 2.2 — `Effort_resolver` returns the budget
  from `models.sexp`, so the catalog author is responsible for sane values.)

**Verify:** `dune build && dune test` green. Manually confirm with a live
Anthropic key (optional) that a `Medium`-effort request now streams thinking
deltas.

---

### Stage 0.3 — Tool refactor (`unit tool` → `(module Execution_env.S) tool`)

**Scope:** Change all tools in `pera_tools` from closing over their env at
construction time to receiving the env as `~ctx` at execute time. This touches
the **body** of every tool's `execute` function (the captured `env` becomes
`(val ctx)`), not just signatures. `agent_loop` is unchanged — it already
threads `~ctx` through every tool call.

**Current source state (verified):**
- `Tools.local_tool = unit Agent_types.tool`; `read : (module S) -> local_tool`
  etc.; `default : (module S) -> local_tool list`.
- Each tool's `execute` closes over `env` and ignores `~ctx:()`.
- `agent_loop_config.tool_ctx : 'ctx` is parametric; currently `()`.
- `bash_tool` passes `?cwd:(None : string option)` to `E.Sh.exec` (see Stage
  0.6 for the cwd fix).

**Changes to `lib/pera_tools/read_tool.{ml,mli}`:**

```ocaml
(* BEFORE *)
val read : (module Pera_env.Execution_env.S) -> unit Pera_core.Agent_types.tool
(* AFTER *)
val read : (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool
```

The `execute` body: replace the captured `env` with
`let module E = (val ctx) in …` (extract the first-class module from the
`~ctx` argument). Apply the same pattern to `write_tool`, `bash_tool`,
`grep_tool`. Each `execute` currently begins `fun ~ctx:() ~args ~sw ~cancel ->
…`; change to `fun ~ctx ~args ~sw ~cancel -> let module E = (val ctx) in …`.

**Changes to `lib/pera_tools/tools.{ml,mli}`:**

```ocaml
type local_tool = (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool
val read    : local_tool
val write   : local_tool
val bash    : local_tool
val grep    : local_tool
val default : local_tool list
```

**Changes to `lib/pera_agent/agent_harness.ml`:**
- `let tools = Pera_tools.Tools.default` (drop the `config.exec_env` argument).
- `loop_config.tool_ctx = config.exec_env` (was `()`).
- `build_system_prompt tools`: the function maps `Tool.name`/`Tool.description`
  over the tool list. After the refactor the tool type changes from
  `unit tool` to `(module S) tool`; `Tool.name`/`Tool.description` are
  non-parametric accessors, so the call still type-checks. Update the type
  annotation in `build_system_prompt` from `unit tool list` to
  `(module Pera_env.Execution_env.S) tool list`. (Stage 0.4 deletes this
  function entirely.)

**Changes to drivers and test construction sites:** every
`Read_tool.read env` → `Read_tool.read`, `Tools.default env` → `Tools.default`,
and `tool_ctx = ()` → `tool_ctx = exec_env` in loop configs. **List the test
files that construct tools** (so nothing is missed):
- `lib/pera_tools/test/read_tool_test.ml`
- `lib/pera_tools/test/write_tool_test.ml`
- `lib/pera_tools/test/bash_tool_test.ml`
- `lib/pera_tools/test/grep_tool_test.ml`
- `lib/pera_core/test/agent_loop_tools_test.ml`
- `lib/pera_core_test_util/faux_provider.ml` (if it constructs tools)
- `bin/drivers/*.ml` (until Phase 5 deletes them)

**Tests:** no new tests; existing tool tests must still pass after updating
construction sites. Verify each listed file compiles.

**Verify:** `dune build && dune test` green.

---

### Stage 0.4 — `agent_harness.config` additions + `default_system_prompt` constant

**Scope:** Add `system_prompt : string` and `thinking_budget_tokens : int
option` to `agent_harness.config`. Remove `build_system_prompt` from the
harness (the prompt is now assembled externally and passed in). Expose the
default prompt string as a named constant so drivers and `Pera_cli.Make` share
one source of truth (no duplicated magic strings).

**Changes to `lib/pera_agent/agent_harness.{ml,mli}`:**

```ocaml
val default_system_prompt : string
(** The built-in default system prompt. Callers that do not assemble a custom
    prompt should pass this as [config.system_prompt]. *)

type config = {
  cwd                    : string;
  model                  : Pera_types.Types.model;
  session_path           : string;
  stream_fn              : Pera_core.Agent_types.stream_fn;
  max_tokens             : int;
  exec_env               : (module Pera_env.Execution_env.S);
  system_prompt          : string;         (* NEW *)
  thinking_budget_tokens : int option;     (* NEW *)
  compaction             : compaction_config option;
}
```

In `create`:
- Remove the call to `build_system_prompt tools`.
- Set `loop_config.system = config.system_prompt`.
- Set `loop_config.options = { ...; thinking_budget_tokens = config.thinking_budget_tokens }`.
- Delete the `build_system_prompt` function. Keep its body as
  `default_system_prompt` (the base string only — without the per-tool
  description list, since prompt-cache stability favours a static prompt; if
  the tool-description appendix is still wanted, the CLI assembles it
  externally before passing `system_prompt` in).

**Update all `agent_harness` call sites in drivers** to supply the two new
fields: `system_prompt = Pera_agent.Agent_harness.default_system_prompt;
thinking_budget_tokens = None`.

**Tests (`lib/pera_agent/test/agent_harness_test.ml`):** update config literals
to include the two new fields. Add one test: supply a custom `system_prompt`;
verify the loop sees it as `context.system`.

**Verify:** `dune build && dune test` green.

---

### Stage 0.5 — `Connector.create` accepts `~api_key` (eager key resolution enabler)

**Scope:** Today `Anthropic_connector.create ~env ~sw` reads
`Sys.getenv_opt "ANTHROPIC_API_KEY"` itself, and `Openai_completions_connector.create`
does the same for its env var. For the CLI to control the key source
(`Key` / `File` / `Command` / env-var-name from `models.sexp`), the connector
must accept the resolved key string at creation time. This is a small,
contained API change to the connector layer.

**Current source state (verified):** `Anthropic_connector.create : env:_ -> sw:_ -> t`
reads `ANTHROPIC_API_KEY` via `Sys.getenv_opt` and `failwith`s if absent.
`Openai_completions_connector.create` likewise reads its env var.

**Changes to `lib/pera_connector/anthropic_connector.{ml,mli}`:**
```ocaml
val create : api_key:string -> env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> t
```
Move the `Sys.getenv_opt`/`failwith` out of `create` — the caller (the CLI /
registry builder) is now responsible for producing `api_key`. Keep a
convenience wrapper `create_from_env : env:_ -> sw:_ -> (t, string) result`
that reads the env var and returns `Error` (not `failwith`) if absent, for
drivers that don't go through the CLI.

**Changes to `lib/pera_connector/openai_completions_connector.{ml,mli}`:**
same pattern — `create ~api_key ~env ~sw`, plus `create_from_env`.

**Changes to call sites:** `provider_driver.ml`, `live_driver.ml`,
`compaction_driver.ml`, and `lib/pera_connector/test/` update to pass
`~api_key` (or use `create_from_env`). `provider_registry` registration is
unaffected (it stores `(module Connector.S)` values, not `create` args).

**Tests:** add a test that `create ~api_key:"k"` produces a connector whose
requests carry `x-api-key: k` (Anthropic) / `Authorization: Bearer k`
(OpenAI). The existing live-env-var path is covered by `create_from_env`.

**Verify:** `dune build && dune test` green.

---

### Stage 0.6 — Expose `cwd` in `Execution_env.S`; tools run in the agent cwd

**Scope:** `Execution_env.S` currently bakes the cwd into `Fs`/`Sh` at create
time but does not expose it as a value. `Sh.exec ?cwd` with `None` runs in the
*OS process cwd*, which may differ from the env's configured cwd. Expose
`cwd : string` so tools (and the shell tool builder in Stage 3.1) can pass
`~cwd:E.cwd` explicitly and run in the agent's session cwd regardless of the
process cwd.

**Current source state (verified):** `Execution_env.S` = `sig module Fs module Sh end`
(no `cwd`). `Local_env.create ~env ~cwd` captures `cwd_fpath` internally.
`bash_tool` passes `?cwd:(None : string option)` — so bash runs in the OS
process cwd, which happens to coincide with the agent cwd only because drivers
`chdir` to the session cwd before launching.

**Changes to `lib/pera_env/execution_env.mli`:**
```ocaml
module type S = sig
  val cwd : string
  (** The working directory this env is rooted at. Pass to [Sh.exec ~cwd]
      to run subprocesses in the agent's cwd regardless of the process cwd. *)

  module Fs : FILESYSTEM
  module Sh : SHELL
end
```

**Changes to `lib/pera_env/local_env.ml`:** the `(module Execution_env.S)`
value returned by `create` now includes `let cwd = cwd` (the captured string)
alongside `module Fs = …` and `module Sh = …`.

**Changes to tools:**
- `bash_tool`: change `?cwd:(None : string option)` → `?cwd:(Some E.cwd)`.
- `shell_tool_builder` (Stage 3.1) will use `~cwd:E.cwd`.
- `read_tool` / `write_tool` / `grep_tool`: they resolve relative paths via
  `Fs` which already uses `cwd_fpath` internally, so no change needed there —
  but audit to confirm.

**Tests (`lib/pera_env/test/`):** add a test that `cwd` matches the value
passed to `create`. Add a `bash_tool` test that a relative-path command runs
in `E.cwd` even when the process cwd is elsewhere (use a temp dir and
`Unix.chdir` in the test, restoring afterward).

**Verify:** `dune build && dune test` green.

---

### Phase 0 review checklist

- [ ] `dune build` — zero warnings, zero errors
- [ ] `dune test` — all suites pass
- [ ] `ocamlformat --check $(git ls-files '*.ml' '*.mli')` — clean
- [ ] `semgrep --config .semgrep/ocaml-guidelines.yml` — no findings
- [ ] All `Provider` / `provider` references in source are gone (grep check):
      `grep -r "Pera_provider\|Provider\.S\|provider_registry\|provider_adapter\|anthropic_provider\|openai_completions_provider" lib/ bin/`
      should return empty.
- [ ] `context.thinking` field is gone everywhere; `turn_update.thinking` is
      `thinking_update` (`Inherit`/`Budget`/`Disabled`).
- [ ] No `Result.get_or_else` calls; `Result.get_or ~default:` used instead.
- [ ] `Execution_env.S` exposes `cwd`; `bash_tool` passes `~cwd:E.cwd`.

---

## Phase 1 — Config type system

Create the `pera-cli` library package with the S-expression types for
`models.sexp` and `config.sexp`, plus loading and merging logic.

---

### Stage 1.1 — Package skeleton + dependencies

**dune-project:** add new packages:

```
(package
 (name pera-cli)
 (synopsis "Reusable CLI wiring for Pera")
 (depends
  (ocaml (>= 5.4))
  (pera-types (= :version))
  (pera-connector (= :version))
  (pera-core (= :version))
  (pera-env (= :version))
  (pera-harness (= :version))
  (pera-tools (= :version))
  (pera-agent (= :version))
  (containers (>= 3.0))
  (sexplib (>= 0.17))
  (ppx_sexp_conv (>= 0.17))
  (xdg (>= 3.0))
  (cmdliner (>= 1.2))
  (uuidm (>= 0.9))
  (yojson (>= 2.0))
  (fpath (>= 0.7))
  (re (>= 1.0))
  (cstruct (>= 6.0))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (eio_linux (>= 1.0))
  (alcotest (and (>= 1.7) :with-test))))
```

Note: `yojson` is needed by `event_renderer` (Stage 3.2) and is already a
transitive dep, but list it explicitly. `fpath` is used by `session_path` and
the packaged-file loader. `re` is used by `shell_tool_builder` and
`input_loop`.

**Create `lib/pera_cli/dune`:**

```
(library
 (name pera_cli)
 (public_name pera-cli)
 (libraries
  pera_types pera_connector pera_core pera_env pera_harness pera_tools pera_agent
  containers sexplib ppx_sexp_conv xdg cmdliner uuidm yojson fpath re cstruct
  eio eio_main eio_linux)
 (preprocess (pps ppx_sexp_conv ppx_deriving.show ppx_deriving.eq)))
```

Mixing `ppx_sexp_conv` and `ppx_deriving.{show,eq}` on the same
`[@@deriving ...]` is supported — `sexp` comes from `ppx_sexp_conv`, `show`/`eq`
from `ppx_deriving`, and their generated names don't collide. Verified to
build in Stage 1.2.

**Create `lib/pera_cli/test/dune`:**

```
(tests
 (names models_config_test pera_config_test models_loader_test config_loader_test
        session_path_test effort_resolver_test env_reader_test cli_args_test
        config_resolver_test shell_tool_builder_test event_renderer_test
        input_loop_test)
 (libraries pera_cli alcotest containers sexplib yojson fpath re eio eio_main))
```

Create a placeholder `lib/pera_cli/pera_cli.ml` with `let () = ()` so `dune
build` passes until Stage 3.4 fills it in.

**Install opam packages:**
```
opam install sexplib ppx_sexp_conv xdg cmdliner
```

**Verify:** `dune build` green (empty library compiles).

---

### Stage 1.2 — `models_config.{ml,mli}` — models.sexp types

**Create `lib/pera_cli/models_config.mli`:**

```ocaml
type thinking_spec = {
  budget_medium : int;
  budget_high   : int;
} [@@deriving sexp, show, eq]

type compat_config = {
  reasoning_field          : string option;
  max_tokens_field         : string option;
  require_tool_result_name : bool   option;
  enable_thinking_field    : string option;
} [@@deriving sexp, show, eq]

type model_spec = {
  name           : string;
  context_window : int;
  max_tokens     : int;
  thinking       : thinking_spec option;
} [@@deriving sexp, show, eq]

type provider_spec = {
  name         : string;
  api          : string;
  api_key_env  : string option;
  base_url     : string option;
  base_url_env : string option;
  compat       : compat_config option;
  models       : model_spec list;
} [@@deriving sexp, show, eq]

type models_file = {
  providers : provider_spec list;
} [@@deriving sexp, show, eq]
```

**Create `lib/pera_cli/models_config.ml`:** implement the types with
`[@sexp.default ...]` and `[@sexp.option]` attributes exactly as in the spec's
§OCaml types — models.sexp types section.

**Tests (`lib/pera_cli/test/models_config_test.ml`):**

```ocaml
(* Test 1: parse a minimal valid models sexp — pattern-match the list, no List.hd *)
let test_parse_minimal () =
  let sexp_str = {|((providers (((name anthropic) (api anthropic)
    (models (((name claude-sonnet-4-6) (context_window 200000)
              (max_tokens 16000))))))))|} in
  let mf = Models_config.models_file_of_sexp (Sexplib.Sexp.of_string sexp_str) in
  Alcotest.(check int) "one provider" 1 (List.length mf.providers);
  (match mf.providers with
   | [ p ] ->
       Alcotest.(check string) "provider name" "anthropic" p.name;
       Alcotest.(check int) "one model" 1 (List.length p.models)
   | _ -> Alcotest.fail "expected exactly one provider")

(* Test 2: round-trip sexp_of then of_sexp *)
(* Test 3: thinking_spec defaults *)
(* Test 4: compat_config @sexp.option defaults *)
```

**Verify:** `dune test` green for this test file.

---

### Stage 1.3 — `pera_config.{ml,mli}` — config.sexp types

**Create `lib/pera_cli/pera_config.mli`:** all types from the spec §OCaml types
— config.sexp types section: `api_key_source`, `effort`, `cache_policy`,
`cache_ttl`, `model_auth`, `provider_auth`, `cache_config`, `session_config`,
`compaction_config`, `output_config`, `command_def`, `shell_arg_type`,
`shell_arg`, `shell_tool_def`, `mcp_transport`, `mcp_server_def`, `config`.

All with `[@@deriving sexp, show, eq]`. Use `[@sexp.option]` and
`[@sexp.default []]` exactly as in the spec.

**Important type clarification for `api_key_source`:**

```ocaml
type api_key_source =
  | Key     of string
  | File    of string
  | Command of string list
[@@deriving sexp, show, eq]
```

sexplib variant serialisation: `(Key "abc")`, `(File "/path")`,
`(Command (a b c))`. **Add a dedicated round-trip test** for `Command`
confirming the list serialises as `(Command (a b c))` and not
`(Command ("a" "b" "c"))`.

**Create `lib/pera_cli/pera_config.ml`:** just the types + derived functions.
No logic yet.

**Tests (`lib/pera_cli/test/pera_config_test.ml`):**

```ocaml
(* Test 1: parse user config sexp (the example from the spec) *)
(* Test 2: parse project config sexp *)
(* Test 3: shell_tool_def with args *)
(* Test 4: Command api_key source round-trip *)
```

**Verify:** `dune test` green.

---

### Stage 1.4 — Models loading and merging

**Create `lib/pera_cli/models_loader.mli`:**

```ocaml
val load : packaged_path:string -> user_path:string option ->
  (Models_config.models_file, string) result
(** [load ~packaged_path ~user_path] parses the packaged models file, then
    (if [user_path] is [Some p]) parses and merges the user file on top.
    Returns [Error] if either file fails to parse. *)

val merge : base:Models_config.models_file -> overlay:Models_config.models_file ->
  Models_config.models_file
(** Merge [overlay] into [base]: providers matched by name have their model
    lists merged (model matched by name; overlay model fields replace base);
    new providers from overlay are appended. *)

val resolve_model :
  Models_config.models_file -> string ->
  (Models_config.provider_spec * Models_config.model_spec, string) result
(** [resolve_model mf "provider/model"] splits the string, finds the provider
    by name, finds the model by name within it.
    [Error] message: "[pera] unknown model \"p/m\" — add it to
    $XDG_CONFIG_HOME/pera/models.sexp". *)
```

**Implement `lib/pera_cli/models_loader.ml`:**

`merge`: iterate `overlay.providers`; for each, find matching provider in
`base` by name with `List.find_opt`:
- Not found: append the overlay provider.
- Found: merge model lists — for each overlay model, if a model with the same
  name exists in base, the overlay replaces it; otherwise append.

`resolve_model`: `String.split_on_char '/'` → must produce exactly 2 parts,
else `Error "not fully qualified"`. Then `List.find_opt` on providers, then
`List.find_opt` on models. (Use `Containers`'s `String.split_on_char`.)

**Tests (`lib/pera_cli/test/models_loader_test.ml`):**

```ocaml
(* Test 1: merge preserves unmodified provider *)
(* Test 2: overlay provider with same name merges model lists *)
(* Test 3: overlay model replaces matching base model *)
(* Test 4: overlay adds new provider *)
(* Test 5: resolve_model finds known model *)
(* Test 6: resolve_model returns Error for unknown provider *)
(* Test 7: resolve_model returns Error for unknown model within known provider *)
(* Test 8: resolve_model returns Error for unqualified name (no slash) *)
```

**Verify:** `dune test` green.

---

### Stage 1.5 — Config loading and merging

**Create `lib/pera_cli/config_loader.mli`:**

```ocaml
type load_error =
  | Parse_error of string
  | Api_key_in_project_config

val load_user_config : path:string -> (Pera_config.config option, load_error) result
(** Parse [path]; [Ok None] if the file does not exist. *)

val find_project_config : cwd:string -> string option
(** Walk up from [cwd] looking for a file named [".pera"]. Returns the path of
    the first one found, or [None] if not found before filesystem root. *)

val load_project_config : path:string ->
  (Pera_config.config option, load_error) result
(** Parse [path]; reject any [api_key] field in any provider entry
    ([Error Api_key_in_project_config]).
    [Ok None] if file does not exist. *)

val merge : base:Pera_config.config -> overlay:Pera_config.config ->
  Pera_config.config
(** Field-by-field merge: [Some] value in [overlay] replaces [base].
    List fields ([commands], [tools], [mcp_servers], [providers]) are replaced
    entirely (no concatenation). *)
```

**Implement `lib/pera_cli/config_loader.ml`:**

`find_project_config`: use `Fpath.dirname` to walk up; stop when
`Fpath.dirname path = path` (filesystem root). Use `Sys.file_exists` to test.

`load_project_config`: after parsing, iterate `cfg.providers`; if any entry
has `api_key = Some _`, return `Error Api_key_in_project_config`.

`merge`: for each field, `Option.value ~default:base_field overlay_field_opt`;
for list fields: if overlay list is non-empty, take overlay list; else base
list.

**Tests (`lib/pera_cli/test/config_loader_test.ml`):**

```ocaml
(* Test 1: merge replaces Some field *)
(* Test 2: merge keeps base value when overlay is None *)
(* Test 3: merge replaces list fields entirely *)
(* Test 4: load_project_config rejects api_key *)
(* Test 5: load_project_config allows base_url override *)
(* Test 6: find_project_config walks up to parent dir (use a temp tree) *)
(* Test 7: find_project_config returns None at root *)
```

**Verify:** `dune test` green.

---

### Phase 1 review checklist

- [ ] `dune build` — clean
- [ ] `dune test` — all suites pass including all `pera_cli` tests
- [ ] `ocamlformat --check` — clean
- [ ] `semgrep` — clean
- [ ] No use of `Option.get`, `List.hd`, `List.nth`, etc. (semgrep catches this)

---

## Phase 2 — Resolution layer

Wire env vars, CLI flags, and config tier merging into a single resolved
config. Produce a typed `resolved_config` that `Pera_cli.Make` will consume.

**Design note — testability:** `Config_resolver.resolve` is a **pure** function
that takes already-read config text and a `getenv_opt` function as parameters;
it does no filesystem I/O and does not read `Sys.getenv_opt` directly. The
functor's `Make.run` does the file/env I/O and feeds text into `resolve`. This
avoids the "bend `Config_loader` signatures for testability" anti-pattern and
makes `resolve` trivially unit-testable with canned inputs.

---

### Stage 2.1 — Session path generation

**Create `lib/pera_cli/session_path.mli`:**

```ocaml
val generate_filename :
  secure_random:(string -> unit) -> wall_time:(unit -> Unix.tm) -> string
(** Generate "<YYYYMMDD>_<HHMMSS>_<uuidv4>.jsonl".
    [secure_random buf] writes 16 cryptographically random bytes into [buf]
    (sourced from [Eio.Stdenv.secure_random] in production; a fixed stub in
    tests). [wall_time ()] returns the local-time breakdown (sourced from
    [Unix.localtime (Unix.gettimeofday ())] in production). The UUID is built
    with [Uuidm.of_bytes] (no [Random.State]). *)

val default_session_dir : string -> string
(** [default_session_dir home] is [home ^ "/.local/state/pera/sessions/"].
    Production caller passes [Xdg.state_dir (Xdg.create ~env:Sys.getenv_opt)]
    (or [home] from [Xdg.home_dir]). Uses [Fpath] for joining. *)

val resolve : session_override:string option -> session_dir:string -> string
(** If [session_override] is [Some p], return [p] directly.
    Otherwise return [session_dir / generate_filename ()] (joined via [Fpath]). *)
```

**Implement `lib/pera_cli/session_path.ml`:**

```ocaml
let generate_filename ~secure_random ~wall_time =
  let buf = Bytes.create 16 in
  secure_random (Bytes.unsafe_to_string buf);
  (* Uuidm.v4 takes 16 bytes and sets the v4 version/variant bits itself
     per its docs ("generates version-4 UUIDs using b for randomness").
     No manual RFC 4122 bit-twiddling needed. *)
  let uuid = Uuidm.v4 (Bytes.unsafe_to_string buf) in
  let t = wall_time () in
  Printf.sprintf "%04d%02d%02d_%02d%02d%02d_%s.jsonl"
    (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
    t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec
    (Uuidm.to_string uuid)
```

Note: `Unix.tm` is used only for the timestamp; Eio has no wall-clock (only a
monotonic `clock`). This is acceptable per the project guideline (Eio where
possible; Unix only for what Eio lacks).

**Production wiring (in `Pera_cli.Make`, verified against installed Eio):**
```ocaml
(* secure_random : env:Eio_unix.Stdenv.base -> string -> unit
   Writes exactly 16 cryptographically random bytes into the given string. *)
let secure_random ~env s =
  let src = Eio.Stdenv.secure_random env in      (* infinite _ Flow.source *)
  let cs = Cstruct.create 16 in                   (* needs cstruct (eio dep) *)
  Eio.Flow.read_exact src cs;                     (* fills cs completely *)
  let got = Cstruct.to_string cs in               (* ?off:0 ?len:16 defaults *)
  String.blit got 0 s 0 16
in
let wall_time () = Unix.localtime (Unix.gettimeofday ()) in
```
`Cstruct` is a transitive dependency of `eio` (see its META `requires`), so no
new opam dep — but add `cstruct` to `lib/pera_cli/dune` `libraries` so the
build sees it explicitly.

**Test wiring:** pass a `secure_random` that writes deterministic bytes:
```ocaml
let fixed_random s = String.fill s 0 16 '\x00'
```
No `Eio.Flow.string_source` needed here (the function-injection design avoids
it), but it's available if a test prefers to feed an `Eio.Flow.source`.

**Tests (`lib/pera_cli/test/session_path_test.ml`):**

```ocaml
(* Test 1: generate_filename matches pattern YYYYMMDD_HHMMSS_<uuid>.jsonl.
   Inject a fixed secure_random (writes deterministic bytes) and a fixed
   wall_time (returns a constant Unix.tm) so the output is deterministic. *)
let test_filename_pattern () =
  let fixed_time = Unix.localtime 0L in
  let fixed_random s = String.fill s 0 16 '\x00' in
  let name = Session_path.generate_filename ~secure_random:fixed_random
               ~wall_time:(fun () -> fixed_time) in
  let re = Re.(compile (seq [rep1 digit; str "_"; rep1 digit; str "_";
    repn (alt [alnum; char '-']) 36 (Some 36); str ".jsonl"])) in
  Alcotest.(check bool) "matches" true (Re.execp re name)

(* Test 2: resolve with session_override returns that path *)
(* Test 3: resolve without override returns session_dir/filename (Fpath.join) *)
(* Test 4: default_session_dir joins home with .local/state/pera/sessions *)
```

**Verify:** `dune test` green.

---

### Stage 2.2 — Effort resolution

**Create `lib/pera_cli/effort_resolver.mli`:**

```ocaml
val resolve :
  effort:Pera_config.effort ->
  model_spec:Models_config.model_spec ->
  (int option, string) result
(** Resolve the effective thinking_budget_tokens from effort + model spec.
    [Low]    → [Ok None]
    [Medium] → [Ok (Some thinking_spec.budget_medium)] or
               [Error "[pera] model X does not support extended thinking"]
    [High]   → [Ok (Some thinking_spec.budget_high)] or [Error ...] *)
```

**Implement `lib/pera_cli/effort_resolver.ml`:**

```ocaml
let resolve ~effort ~model_spec =
  match effort, model_spec.Models_config.thinking with
  | Pera_config.Low, _         -> Ok None
  | Pera_config.Medium, Some s -> Ok (Some s.budget_medium)
  | Pera_config.High,  Some s  -> Ok (Some s.budget_high)
  | Pera_config.Medium, None
  | Pera_config.High,  None    ->
      Error (Printf.sprintf
        "[pera] model %S does not support extended thinking \
         (effort > Low requires a model with thinking capability)"
        model_spec.Models_config.name)
```

**Tests (`lib/pera_cli/test/effort_resolver_test.ml`):**

```ocaml
(* Test 1: Low → None for any model *)
(* Test 2: Medium → Some budget_medium for model with thinking *)
(* Test 3: High → Some budget_high for model with thinking *)
(* Test 4: Medium → Error for model without thinking *)
(* Test 5: High → Error for model without thinking *)
```

**Verify:** `dune test` green.

---

### Stage 2.3 — Env var reading (function-injected, not process-global)

**Create `lib/pera_cli/env_reader.mli`:**

```ocaml
type api_key_override =
  | AK_key     of string
  | AK_file    of string
  | AK_command of string list
  | AK_none

val read_api_key_override :
  getenv_opt:(string -> string option) -> (api_key_override, string) result
(** Read PERA_API_KEY / PERA_API_KEY_FILE / PERA_API_KEY_COMMAND via the
    supplied [getenv_opt]. [Error] if more than one is set. [Ok AK_none] if
    none are set. *)

val read_partial_config :
  getenv_opt:(string -> string option) -> Pera_config.config
(** Build a partial [Pera_config.config] from PERA_* env vars.
    Only fields with a corresponding PERA_* var are set (rest are None / []).
    Var mapping:
      PERA_MODEL              → default_model
      PERA_EFFORT             → effort (parse "low"|"medium"|"high")
      PERA_MAX_TOKENS         → max_tokens (parse int)
      PERA_CACHE_POLICY       → cache.policy
      PERA_CACHE_TTL          → cache.ttl
      PERA_SESSION_DIR        → session.dir
      PERA_NO_COMPACT         → compaction.enabled = false (if set)
      PERA_COMPACT_THRESHOLD  → compaction.threshold
      PERA_COMPACT_TAIL       → compaction.tail
    Parsing failures for any var produce a message on stderr and that field
    is left as None. *)
```

**Design rationale (chosen over "get env through Eio"):** Eio has no
`getenv_opt` primitive, so reading env vars is unavoidably `Sys.getenv_opt`.
Instead of mutating the process env in tests (`Unix.putenv` — fragile,
order-dependent), the `getenv_opt` function is injected. Production supplies
`Sys.getenv_opt`; tests supply a `Hashtbl`-backed lookup. This is the same
injection pattern the `Env` functor uses (Stage 3.4) and keeps `Env_reader`
pure and deterministic.

**Implement `lib/pera_cli/env_reader.ml`:** use the `getenv_opt` parameter for
every variable. For `PERA_EFFORT`, match on the lowercased string. For
`PERA_CACHE_POLICY`: match `"no_cache"`, `"conversation"`, `"system_and_tools"`.

`read_api_key_override`: count how many of the three vars are set via
`getenv_opt`; if > 1, return `Error "[pera] PERA_API_KEY,
PERA_API_KEY_FILE, and PERA_API_KEY_COMMAND are mutually exclusive"`.

**Tests (`lib/pera_cli/test/env_reader_test.ml`):**

```ocaml
(* No Unix.putenv anywhere. Build a Hashtbl-backed getenv_opt per test. *)
let env_of alist k = List.assoc_opt k alist  (* use Containers List.assoc_opt *)

(* Test 1: PERA_API_KEY set → AK_key *)
let test_api_key () =
  match Env_reader.read_api_key_override
          ~getenv_opt:(env_of ["PERA_API_KEY", "test-key"]) with
  | Ok (AK_key "test-key") -> ()
  | _ -> Alcotest.fail "expected AK_key"

(* Test 2: two api key vars set → Error *)
(* Test 3: PERA_EFFORT → parses effort *)
(* Test 4: PERA_CACHE_POLICY → parses policy *)
(* Test 5: no vars set → AK_none / empty partial config *)
```

**Verify:** `dune test` green.

---

### Stage 2.4 — CLI argument parsing

**Create `lib/pera_cli/cli_args.mli`:**

```ocaml
type parsed_args = {
  model             : string option;
  api_key           : string option;
  api_key_file      : string option;
  api_key_command   : string option;   (* space-separated argv *)
  effort            : Pera_config.effort option;
  max_tokens        : int option;
  cache_policy      : Pera_config.cache_policy option;
  cache_ttl         : Pera_config.cache_ttl option;
  session           : string option;
  session_dir       : string option;
  cwd               : string option;
  system            : string option;
  system_file       : string option;
  no_compact        : bool;
  compact_threshold : int option;
  compact_tail      : int option;
  show_thinking     : bool;
  quiet             : bool;
  json              : bool;
}

val parse : argv:string array -> parsed_args
(** Parse [argv] via Cmdliner. Exits non-zero on bad args (Cmdliner handles
    this). [--system] and [--system-file] are mutually exclusive; if both are
    given, print an error and exit 1. Multiple API key flags are mutually
    exclusive; if more than one is given, print an error and exit 1.
    Takes [argv] as a parameter so tests can call it with a canned argv
    instead of [Sys.argv]. *)

val to_partial_config : parsed_args -> Pera_config.config
(** Convert the parsed CLI args to a partial [config] for merging. API key
    flags are NOT put into the config here — they are handled separately by
    [Config_resolver]. *)
```

**Implement `lib/pera_cli/cli_args.ml`:** define one `Cmdliner.Arg.t` per flag
(see the CLI flags table in the spec). Wire into a `Cmdliner.Term.t` and call
`Cmdliner.Term.eval`. On parse errors or help, let Cmdliner exit. Accept `~argv`
and pass to `Cmdliner.Term.eval` via
`Cmdliner.Term.eval ?argv:None` — actually `Cmdliner.Term.eval` reads
`Sys.argv` internally; to inject argv in tests, use
`Cmdliner.Term.eval_result ~catch:false` and set `Sys.argv` in the test, OR
test only the converters and `to_partial_config` directly (recommended — see
tests).

Effort string converter:
```ocaml
let effort_conv =
  Cmdliner.Arg.conv
    ((fun s -> match String.lowercase_ascii s with
       | "low" -> Ok Pera_config.Low
       | "medium" -> Ok Pera_config.Medium
       | "high" -> Ok Pera_config.High
       | _ -> Error (`Msg (Printf.sprintf "unknown effort %S (low|medium|high)" s))),
     (fun fmt e -> Format.pp_print_string fmt
       (match e with Low -> "low" | Medium -> "medium" | High -> "high")))
```

Similarly define `cache_policy_conv` and `cache_ttl_conv`.

`to_partial_config`: map parsed_args fields to `Pera_config.config` fields;
`no_compact = true` → `compaction = Some { enabled = Some false; ... }`.

**Tests (`lib/pera_cli/test/cli_args_test.ml`):** test the converters and
`to_partial_config` directly (do not invoke `Cmdliner.Term.eval`):

```ocaml
(* Test 1: effort_conv parses "low", "medium", "high" case-insensitively *)
(* Test 2: effort_conv rejects unknown strings *)
(* Test 3: cache_policy_conv parses all three values *)
(* Test 4: to_partial_config maps no_compact to compaction.enabled=false *)
(* Test 5: to_partial_config maps show_thinking/quiet to output fields *)
```

**Verify:** `dune test` green.

---

### Stage 2.5 — Full config resolver (pure, injectable)

**Create `lib/pera_cli/config_resolver.mli`:**

```ocaml
type resolved_config = {
  model                  : Pera_types.Types.model;
  provider_spec          : Models_config.provider_spec;
  api_key_source         : Pera_config.api_key_source option;
      (* Eagerly resolved to a concrete [api_key_source] value ([Key s] /
         [File p] / [Command argv]) — never a deferred env-var name. [None]
         means no key could be resolved; the caller errors at stream
         construction. *)
  max_tokens             : int;
  thinking_budget_tokens : int option;
  cache_policy           : Pera_config.cache_policy;
  cache_ttl              : Pera_config.cache_ttl;
  session_path           : string;
  cwd                    : string;
  system_prompt          : string option;  (* None = use built-in default *)
  compaction             : Pera_agent.Agent_harness.compaction_config option;
  output                 : Pera_config.output_config;
  tools                  : Pera_config.shell_tool_def list;
  commands               : Pera_config.command_def list;
  mcp_servers            : Pera_config.mcp_server_def list;
  json_output            : bool;
}

type resolve_inputs = {
  parsed_args       : Cli_args.parsed_args;
  models_file       : Models_config.models_file;
  user_config       : Pera_config.config option;       (* already-parsed user config *)
  project_config    : Pera_config.config option;       (* already-parsed project config *)
  getenv_opt        : string -> string option;
  home              : string;                          (* for default session dir *)
  session_override  : string option;                   (* from parsed_args.session, hoisted for clarity *)
}

val resolve : resolve_inputs -> (resolved_config, string) result
(** Pure. Merge config tiers and resolve into a typed [resolved_config].
    Merge order (lowest → highest priority):
      built-in defaults → user config → project config → env vars → CLI flags.
    Steps:
    1. Merge: built_in_defaults ← user ← project ←
       Env_reader.read_partial_config ~getenv_opt ←
       Cli_args.to_partial_config parsed_args.
    2. Resolve model: require merged.default_model = Some "p/m"; look up in
       models_file via Models_loader.resolve_model.
    3. Resolve API key source (eager): CLI --api-key* > env PERA_API_KEY* >
       provider api_key from merged config > provider_spec.api_key_env
       (read via getenv_opt, wrapped as [Key v]). Materialise [File] (read
       the file) and [Command] (run the command) here, or defer materialisation
       to the caller by returning the [api_key_source] variant as-is and
       letting the caller perform File/Command IO — **chosen: defer**. The
       variant is concrete; the caller ([Pera_cli.Make]) turns [File p] /
       [Command argv] into a key string before passing it to the connector.
    4. Resolve effort → thinking_budget_tokens via Effort_resolver.resolve.
    5. Build compaction_config from merged fields.
    6. Compute session_path via Session_path.resolve (needs
       secure_random/wall_time — these are NOT available in the pure resolver;
       instead, resolve returns [session_dir] and the caller generates the
       filename. See note below).
    Returns [Error] for any validation failure with a descriptive message. *)
```

**Session-path note:** `Session_path.generate_filename` needs `secure_random`
and `wall_time`, which are IO. To keep `resolve` pure, `resolve` computes the
*session directory* and returns it in a field `session_dir : string`; the
caller (`Make.run`) calls `Session_path.resolve ~session_override
~session_dir` with injected random/time to produce the final `session_path`.
Adjust `resolved_config` accordingly: replace `session_path : string` with
`session_dir : string`, and let `Make.run` derive the final path. (If you
prefer `session_path` in `resolved_config`, move filename generation out of
the pure resolver and into `Make.run`, passing only `session_dir` back.)

**Eager API key resolution (chosen design):** `api_key_source` in
`resolved_config` is a concrete `Pera_config.api_key_source` variant. Priority:
1. CLI `--api-key`/`--api-key-file`/`--api-key-command` (if any).
2. `Env_reader.read_api_key_override ~getenv_opt` (if `AK_*`, not `AK_none`).
3. The merged config's `provider_auth.api_key` for the resolved provider.
4. `provider_spec.api_key_env` — read via `getenv_opt`, wrap as `Key v` if
   present, else `None`.

`File` and `Command` sources are **not** materialised here (no IO in the pure
resolver). `Make.run` reads the file / runs the command to produce the key
string for `Connector.create ~api_key`. If `api_key_source = None` and the
connector requires a key, `Make.run` errors and exits.

**Implement `lib/pera_cli/config_resolver.ml`:**

```ocaml
let built_in_defaults : Pera_config.config = {
  providers = []; default_model = None; effort = Some Low; max_tokens = None;
  cache = Some { policy = Some No_cache; ttl = Some Five_minutes };
  session = None; compaction = Some { threshold = Some 70; tail = Some 4;
    enabled = Some true };
  output = Some { show_thinking = Some false; quiet = Some false };
  commands = []; tools = []; mcp_servers = [] }
```

Merge chain:
```ocaml
let merged =
  built_in_defaults
  |> Config_loader.merge ~overlay:(Option.value ~default:built_in_defaults user_config)
  |> Config_loader.merge ~overlay:(Option.value ~default:built_in_defaults project_config)
  |> Config_loader.merge ~overlay:(Env_reader.read_partial_config ~getenv_opt)
  |> Config_loader.merge ~overlay:(Cli_args.to_partial_config parsed_args)
in
```
(Use a merge that treats `built_in_defaults` as the base; `Config_loader.merge`
already handles `Some`/`None` per field.)

**Tests (`lib/pera_cli/test/config_resolver_test.ml`):** all tests call
`resolve` with canned `resolve_inputs` (no file I/O, no `Unix.putenv`):

```ocaml
(* Test 1: CLI --model overrides user config default_model *)
(* Test 2: PERA_MODEL env var (via injected getenv_opt) overrides user config *)
(* Test 3: project config default_model overrides user config *)
(* Test 4: api_key in project config is rejected at load time, not here.
   [resolve] receives already-parsed configs, so an api_key-bearing project
   config never reaches it — that check lives in Config_loader. Add the
   rejection test at the loader level; resolve tests assume valid inputs. *)
(* Test 5: effort Low → thinking_budget_tokens = None *)
(* Test 6: effort Medium with thinking model → Some budget_medium *)
(* Test 7: effort Medium without thinking model → Error *)
(* Test 8: fully-qualified model resolves to provider_spec + model_spec *)
(* Test 9: unqualified model name → Error *)
(* Test 10: unknown model → Error with suggestion text *)
(* Test 11: api_key_env resolution via injected getenv_opt *)
```

**Verify:** `dune test` green.

---

### Phase 2 review checklist

- [ ] `dune build` — clean
- [ ] `dune test` — all suites pass
- [ ] `ocamlformat --check` — clean
- [ ] `semgrep` — clean
- [ ] Grep for `Option.get` / `List.hd` — none in new code
- [ ] No `Unix.putenv` / `Unix.getenv_opt` in `pera_cli` test files
  (all env access via injected `getenv_opt`)

---

## Phase 2B — models.sexp schema alignment

Align `Models_config` types with the models.dev/LiteLLM field conventions
established in the spec update (see `pera-cli.md §Models file`):

- `provider_spec.api` (protocol discriminator) → `provider_spec.protocol`
- `provider_spec.base_url` (URL) → `provider_spec.api`
- `provider_spec.api_key_env : string option` → `string list`
- new `model_cost` type storing `Decimal.t` via custom sexp converters
- new `cost : model_cost option` field on `model_spec`

This phase touches `lib/pera_cli/` only. No changes to `pera_types`,
`pera_connector`, or any other layer. `provider_auth.base_url` in
`pera_config` (`config.sexp`) is a separate user-facing field and is
**not renamed**.

---

### Stage 2B.1 — `model_cost` type and `Decimal.t` sexp converters

**Edit `lib/pera_cli/models_config.ml`:**

Add custom sexp converters immediately after the `open` lines, before any
`[@@deriving sexp]` use:

```ocaml
let decimal_of_sexp s = Decimal.of_string (Sexplib.Conv.string_of_sexp s)
let sexp_of_decimal d = Sexplib.Conv.sexp_of_string (Decimal.to_string d)
```

`ppx_sexp_conv` resolves `decimal_of_sexp` / `sexp_of_decimal` by name from
the ambient scope — no `[@sexp.custom ...]` attribute needed.

Add `model_cost` type before `model_spec`:

```ocaml
type model_cost = {
  input_per_mtok       : decimal;
  output_per_mtok      : decimal;
  cache_read_per_mtok  : decimal option; [@sexp.option]
  cache_write_per_mtok : decimal option; [@sexp.option]
}
[@@deriving sexp, show, eq]
```

Add `cost : model_cost option [@sexp.option]` as the last field of
`model_spec`.

**Edit `lib/pera_cli/models_config.mli`:**

Add the `model_cost` type declaration (with field docs) and add `cost` to
`model_spec`.

**Edit `lib/pera_cli/dune`:**

Add `decimal` to the `libraries` stanza of the `pera_cli` library (it is
already a dep of `pera_types` and `pera_provider`; must be explicit here).

**Tests (`lib/pera_cli/test/models_config_test.ml` — extend existing):**

```ocaml
(* Test: model_cost round-trips through sexp — of_sexp (to_sexp v) = v *)
(* Test: "3.00" atom parses to Decimal.(of_string "3.00") *)
(* Test: "0.30" atom parses correctly — no float rounding loss *)
(* Test: cache fields absent in sexp parse to None *)
(* Test: cost absent in model_spec sexp parses to None in model_spec.cost *)
(* Test: model_spec with cost present round-trips *)
```

**Verify:** `dune test` green.

---

### Stage 2B.2 — Rename `api`→`protocol`, `base_url`→`api`, widen `api_key_env`

**Edit `lib/pera_cli/models_config.ml`:**

In `provider_spec`, apply three mechanical changes:

1. Rename field `api` → `protocol` (string, no type change)
2. Rename field `base_url` → `api` (string option, `[@sexp.option]` unchanged)
3. Change `api_key_env : string option [@sexp.option]` →
   `api_key_env : string list [@sexp.default []]`

**Edit `lib/pera_cli/models_config.mli`:**

Mirror the same renames and type changes in `provider_spec`.

**Edit `lib/pera_cli/models_loader.ml`:**

Update all field accesses to use the new names:

- `p.api` (where it held the protocol string) → `p.protocol`
- `p.base_url` → `p.api`
- Any `Option.is_some p.api_key_env` / `Option.get p.api_key_env` patterns →
  list operations (`p.api_key_env <> []`, `List.hd p.api_key_env`, etc.)

`resolve_model` does not access these fields directly; the renaming only
affects callers that inspect the returned `provider_spec`.

**Edit `lib/pera_cli/test/models_config_test.ml`:**

Update all sexp string fixtures and record literals:
- `(api anthropic)` → `(protocol anthropic)`
- `(base_url "...")` → `(api "...")`
- `(api_key_env ANTHROPIC_API_KEY)` → `(api_key_env (ANTHROPIC_API_KEY))`
- absent `api_key_env` → omit field (default `[]`) or `(api_key_env ())`

**Edit `lib/pera_cli/test/models_loader_test.ml`:**

Update provider/model fixtures the same way.

**Edit `lib/pera_cli/test/config_loader_test.ml`:**

Check for any references to `provider_spec.base_url` or `provider_spec.api`
in fixtures; update if present. `provider_auth.base_url` (in `pera_config`)
is unchanged.

**Verify:** `dune test` green, `ocamlformat --check` clean, `semgrep` clean.

---

### Phase 2B review checklist

- [ ] `dune build` — clean
- [ ] `dune test` — all suites pass
- [ ] `ocamlformat --check` — clean
- [ ] `semgrep` — clean
- [ ] `Decimal.t` fields use custom converters; no `float` in `model_cost`
- [ ] `api_key_env` is `string list` throughout `pera_cli`; no `Option.get`
  on old `string option` pattern
- [ ] `provider_spec.protocol` is used everywhere `provider_spec.api`
  (protocol discriminator) was used
- [ ] `provider_spec.api` (URL) is used everywhere `provider_spec.base_url`
  was used
- [ ] `provider_auth.base_url` in `pera_config` is **unchanged**
- [ ] No references to old field names (`base_url`, `provider_spec.api` as
  discriminator) remain in `lib/pera_cli/`

---

## Phase 2C — URL field naming alignment

The base URL of a provider is one concept. After Phase 2B it is spelled
`provider_spec.api` in `models.sexp`, but two adjacent fields still use the
old `base_url` spelling:

- `provider_spec.base_url_env` — the env var whose value overrides
  `provider_spec.api` at runtime.
- `provider_auth.base_url` — the user/project override of the base URL in
  `config.sexp`.

Users supply their own `models.sexp`, so they see `provider_spec.api` as the
name for "the base URL." The same concept in their `config.sexp` override and
in the env-var override should carry the same name, otherwise a user editing
both files has to hold a `base_url`↔`api` translation in their head. Rename
both to align with `api`:

- `provider_spec.base_url_env` → `provider_spec.api_env` (mirrors
  `api_key_env` — the env var for the `api` URL).
- `provider_auth.base_url` → `provider_auth.api` (the user override of the
  provider's `api`).

This phase touches `lib/pera_cli/` only. No changes to `pera_types`,
`pera_connector`, or any other layer.

### Stage 2C.1 — Rename `base_url_env` → `api_env`

**Edit `lib/pera_cli/models_config.ml`:**

In `provider_spec`, rename the field:
```ocaml
base_url_env : string option; [@sexp.option]
```
→
```ocaml
api_env : string option; [@sexp.option]
```
No type change (`string option`, `[@sexp.option]` unchanged). The sexp key
changes from `(base_url_env ...)` to `(api_env ...)`.

**Edit `lib/pera_cli/models_config.mli`:**

Mirror the rename in `provider_spec`. Update the doc comment's field name
reference only (the prose meaning — "Env var whose value, if set at runtime,
overrides `api`" — is unchanged).

**Edit `lib/pera_cli/test/models_config_test.ml`:**

- Update every `base_url_env = …` record literal to `api_env = …`.
- Add: `(api_env OLLAMA_BASE_URL)` parses to `Some "OLLAMA_BASE_URL"`.
- Add: absent `api_env` parses to `None`.

**Edit `lib/pera_cli/test/models_loader_test.ml` and
`lib/pera_cli/test/config_resolver_test.ml`:**

Update every `base_url_env = …` record literal to `api_env = …`.

**Audit `lib/pera_cli/config_resolver.ml`:** no field access to
`base_url_env` exists today (the URL override is wired in Phase 3's
`Pera_cli.Make`), so no edit is expected here. Confirm via grep.

**Downstream doc consistency — `.claude/plans/pera-cli.md`:**

Confirm §Models file uses `api_env` for the `provider_spec` field and the
Ollama example (already applied in the plan amendment; verify no `base_url_env`
remains).

**Downstream doc consistency — this plan:**

Confirm Stage 6.1 inserts `oauth` into `provider_spec` "between `api_env`
and `compat`" (already applied in the plan amendment).

**Verify:** `dune build && dune test` green, `ocamlformat --check` clean,
`semgrep` clean. `grep -rn "base_url_env" lib/pera_cli/` returns empty.

### Stage 2C.2 — Rename `provider_auth.base_url` → `provider_auth.api`

**Edit `lib/pera_cli/pera_config.ml`:**

In `provider_auth`, rename the field:
```ocaml
base_url : string option; [@sexp.option]
```
→
```ocaml
api      : string option; [@sexp.option]
```
No type change (`string option`, `[@sexp.option]` unchanged). The sexp key
changes from `(base_url ...)` to `(api ...)`. Note this is the same sexp key
as `provider_spec.api` — which is intentional: both record "the base URL of
this provider" (one the catalogued default, one the user override).

**Edit `lib/pera_cli/pera_config.mli`:**

Mirror the rename in `provider_auth`. Update the doc comment from "Override
the provider's base URL" to "Override the provider's `api` (base URL)" and
the module doc from "`base_url` allowed" to "`api` allowed".

**Edit `lib/pera_cli/test/config_loader_test.ml`:**

- Update every `base_url = …` record literal to `api = …` and every
  `p.base_url` field access to `p.api`.
- Update sexp fixtures: `(base_url "https://example.com")` →
  `(api "https://example.com")`.
- Rename the test functions/comments that mention `base_url`
  (`test_rejects_api_key_with_base_url`, `test_allows_base_url_override`,
  and their `Alcotest` test names) to use `api`.

**Edit `lib/pera_cli/test/pera_config_test.ml`:**

Update any `provider_auth` record literal or sexp fixture that sets
`base_url` to use `api`.

**Audit `lib/pera_cli/config_resolver.ml` and `lib/pera_cli/config_loader.ml`:**
no field access to `provider_auth.base_url` exists today (the URL override is
wired in Phase 3's `Pera_cli.Make`), so no edit is expected here. Confirm via
grep.

**Downstream doc consistency — `.claude/plans/pera-cli.md`:**

Confirm §Config file uses `api` for every former `provider_auth.base_url`
reference — the `provider_auth` OCaml type field, its doc comment, the module
doc ("`api_key` rejected; `api` allowed"), the security note ("`api` overrides
inside `provider_auth` are accepted in both user and project config"), and the
project-config example comment ("api overrides are permitted") (already
applied in the plan amendment; verify no `base_url` remains).

**Verify:** `dune build && dune test` green, `ocamlformat --check` clean,
`semgrep` clean. `grep -rn "base_url" lib/pera_cli/ .claude/plans/pera-cli.md`
returns empty (the `--base-url` CLI flag reference in §Models file is a CLI
flag name being removed, not a config field, and is out of scope).

### Phase 2C review checklist

- [ ] `dune build` — clean
- [ ] `dune test` — all suites pass
- [ ] `ocamlformat --check` — clean
- [ ] `semgrep` — clean
- [ ] `provider_spec.api_env` is used everywhere `provider_spec.base_url_env`
  was used
- [ ] `provider_auth.api` is used everywhere `provider_auth.base_url` was
  used; the sexp key `(api ...)` is shared with `provider_spec.api` by design
- [ ] No references to `base_url_env` or `provider_auth.base_url` remain in
  `lib/pera_cli/` or in `.claude/plans/pera-cli.md`

---

## Phase 3 — pera-cli library

Implement the reusable wiring that `Pera_cli.Make` provides: shell tool
builder, event renderer, input loop, and the functor itself.

---

### Stage 3.1 — Shell-backed tool builder

**Create `lib/pera_cli/shell_tool_builder.mli`:**

```ocaml
type build_error = Unknown_placeholder of string

val build :
  Pera_config.shell_tool_def ->
  ((module Pera_env.Execution_env.S) Pera_core.Agent_types.tool, build_error) result
(** Build a tool from a [shell_tool_def].
    Startup-time validation: every ["{name}"] token in [command] must
    correspond to a declared arg; any unknown placeholder is [Error
    (Unknown_placeholder name)].
    The constructed tool's [execute] function:
    1. Extracts each declared arg value from [args] JSON.
    2. Substitutes ["{name}"] with [Filename.quote value].
    3. Calls [(val ctx).Sh.exec ~cwd:E.cwd command_string]  (* agent cwd *)
    4. Returns [Tool_text output] on success, [tool_error] on failure. *)

val build_all :
  Pera_config.shell_tool_def list ->
  ((module Pera_env.Execution_env.S) Pera_core.Agent_types.tool list, build_error) result
(** [build_all defs] calls [build] on each element; short-circuits on the
    first error. *)
```

Note: `~cwd:E.cwd` uses the `cwd` field added to `Execution_env.S` in Stage 0.6
so shell tools run in the agent's session cwd, not the OS process cwd.

**Implement `lib/pera_cli/shell_tool_builder.ml`:**

Template validation (at build time):
```ocaml
let find_placeholders template =
  let re = Re.(compile (seq [char '{'; group (rep1 (compl [char '}'])); char '}'])) in
  Re.all re template |> List.map (fun g -> Re.Group.get g 1)

let validate template declared_names =
  let placeholders = find_placeholders template in
  let name_set = List.fold_left (fun s n -> String.Set.add n s)
    String.Set.empty declared_names in
  List.find_opt (fun p -> not (String.Set.mem p name_set)) placeholders
  |> Option.map (fun p -> Unknown_placeholder p)
```

JSON schema construction from `shell_arg list`:
- `String { description }` → `Json_schema.string_property ~description name`
- `Int { description; min; max }` → `Json_schema.integer_property ~description
  ?minimum:min ?maximum:max name`

Execute function:
```ocaml
let execute ~ctx ~args ~sw:_ ~cancel:_ =
  let module E = (val ctx : Pera_env.Execution_env.S) in
  let open Result.Syntax in
  let* arg_values = extract_args decl_args args in
  let cmd = substitute template arg_values in
  match E.Sh.exec ~command:cmd ~cwd:E.cwd ~sw ~cancel with
  | Ok output -> Ok (Pera_core.Agent_types.Tool_text output.stdout)
  | Error e   -> Error { Pera_types.Types.message = e.message; is_user_error = false }
```

**Tests (`lib/pera_cli/test/shell_tool_builder_test.ml`):**

```ocaml
(* Test 1: build with no args succeeds *)
(* Test 2: build with declared arg, no unknown placeholders → Ok *)
(* Test 3: build with undeclared placeholder → Error (Unknown_placeholder) *)
(* Test 4: execute substitutes arg with Filename.quote value *)
(* Test 5: execute shell-quotes special chars in arg value *)
(* Test 6: build_all short-circuits on first error *)
```

For Tests 4–5, use a mock `(module Execution_env.S)` that captures the
command string passed to `Sh.exec` (a `Sh` impl whose `exec` records its
input into a ref and returns a fixed `exec_result`).

**Verify:** `dune test` green.

---

### Stage 3.2 — Event renderer (no pricing)

**Create `lib/pera_cli/event_renderer.mli`:**

```ocaml
type t
(** Stateful renderer: tracks accumulated stats for [/info]. *)

val create : output:Pera_config.output_config -> json:bool -> t

val render :
  t ->
  Pera_core.Agent_types.agent_event ->
  string list
(** Render the event to zero or more output lines.
    JSON mode (json = true): emit one NDJSON line per event instead of
    human-readable text. NDJSON lines are JSON objects with a "type" field.
    Thinking blocks: only rendered when output.show_thinking = true.
    Quiet mode: only emit the final assistant text (suppress tool events). *)

val stats : t -> string
(** Format the accumulated stats for /info:
    "Model: X | Turns: N | In: N Out: N Cache-R: N Cache-W: N"
    Pricing is NOT shown: the model API responses do not carry price
    information and [models.sexp] has no price field. If pricing data becomes
    available later (e.g. from the provider response), add it then. *)
```

**Implement `lib/pera_cli/event_renderer.ml`:**

Mutable stats record (no `cost_usd`):
```ocaml
type stats = {
  mutable turns : int;
  mutable input_tokens : int;
  mutable output_tokens : int;
  mutable cache_read : int;
  mutable cache_write : int;
  mutable model_name : string;
}
```

On `AE_turn_end`, increment `turns`.
On `AE_message_end { message = Real (Connector.AssistantMessage am) }`:
- Add `am.usage.*` to the running totals.
- Update `model_name` from `am.provenance.model`.

Rendering per event (non-JSON mode):
- `AE_message_update { event = AME_text_delta { text } }` → emit `text`.
- `AE_message_update { event = AME_thinking_delta { text } }` → if
  `show_thinking`, emit `text`.
- `AE_tool_execution_start { tool_name }` → if not quiet, emit
  `"\n[tool: <name>]"`.
- `AE_tool_execution_end { tool_name; is_error }` → if not quiet, emit
  `"\n[tool: <name> — done]"` or `"\n[tool: <name> — error]"`.
- `AE_agent_end _` → emit `"\n"`.
- All other events → `[]`.

JSON mode: emit `Yojson.Safe.to_string` of a record per event, followed by
`"\n"`. (Uses `yojson`, listed in the dune stanza.)

**Tests (`lib/pera_cli/test/event_renderer_test.ml`):**

```ocaml
(* Test 1: text delta emits text *)
(* Test 2: thinking delta suppressed when show_thinking = false *)
(* Test 3: thinking delta shown when show_thinking = true *)
(* Test 4: tool start suppressed in quiet mode *)
(* Test 5: json mode emits {"type":"text_delta","text":"..."} *)
(* Test 6: stats accumulates after message_end events *)
(* Test 7: stats() formats correctly (no cost field) *)
```

**Verify:** `dune test` green.

---

### Stage 3.3 — Input parsing (pure); interactive loop lives in `pera_cli.ml`

**Create `lib/pera_cli/input_loop.mli`:** — pure parsing only. The interactive
read loop (`run_interactive`) is **not** here; it lives inside `Pera_cli.Make`
in `pera_cli.ml` because it needs the `Env` functor's stdin/tty accessors and
the harness `send` handle.

```ocaml
type command_result =
  | Send of string          (* send this text to the agent *)
  | Compact                 (* trigger /compact *)
  | Info                    (* show /info stats *)
  | Quit                    (* exit *)
  | Error of string         (* user-visible error *)

val is_tty : stdin_isatty:bool -> bool
(** [is_tty ~stdin_isaty] returns [stdin_isaty]. The tty check is injected by
    the caller (the functor) so this module stays pure and testable. *)

val parse_line :
  commands:Pera_config.command_def list ->
  string ->
  command_result
(** Parse one input line. See spec for behaviour. Pure. *)

val expand_template : template:string -> args:string -> string
(** Substitute {args} → args; {1},{2},... → whitespace-delimited tokens.
    Pure. *)
```

**Implement `lib/pera_cli/input_loop.ml`:**

`parse_line`:
1. Trim the line. If empty, `Error "ignore"` (caller skips). Actually: return
   a dedicated `Ignored` constructor or have the caller treat blank lines —
   simplest is to handle blank lines in `run_interactive` and only call
   `parse_line` on non-blank input. Document this.
2. If starts with `/`:
   - Strip `/`, split off the command name (first word).
   - Match: `"compact"` → `Compact`; `"info"` → `Info`; `"quit"` / `"q"` →
     `Quit`.
   - Otherwise scan `commands` for `cmd.name = command_name`. If found,
     `Send (expand_template ~template:cmd.template ~args:rest)`.
   - If not found, `Error (Printf.sprintf "unknown command /%s (type /info
     for help)" command_name)`.
3. Otherwise `Send text`.

`expand_template`:
- Split `args` on whitespace to get tokens list.
- Replace `{args}` with full `args` string.
- Replace `{N}` with `List.nth_opt tokens (N-1) |> Option.get_or ~default:""`
  (`List.nth_opt` is safe; `Option.get_or` is the Containers form).
- Use `Re` for substitution.

**Tests (`lib/pera_cli/test/input_loop_test.ml`):**

```ocaml
(* Test 1: parse_line "/compact" → Compact *)
(* Test 2: parse_line "/quit" → Quit *)
(* Test 3: parse_line "/info" → Info *)
(* Test 4: parse_line "/review diff" → Send (template expanded) *)
(* Test 5: parse_line "/unknown" → Error "unknown command" *)
(* Test 6: parse_line "hello world" → Send "hello world" *)
(* Test 7: expand_template {args} substitution *)
(* Test 8: expand_template {1} {2} positional substitution *)
(* Test 9: expand_template {3} beyond args → empty string *)
```

**Verify:** `dune test` green.

---

### Stage 3.4 — `Pera_cli.Make` functor (with `run_with` factored out)

**Create `lib/pera_cli/pera_cli.mli`:**

```ocaml
(** The environment the CLI runs against — two distinct concerns in one module.

    Agent execution context (create / tools / has_shell): describes where the
    agent's tools run. This may be a local process, sandbox, container, or a
    remote system. The CLI must never use this to perform its own work (config
    loading, API key commands, path lookup). Use Eio.Stdenv / Unix / Sys for
    those instead — see the "Execution env vs host" design note in pera-cli.md.

    Host process accessors (getenv_opt / home / secure_random / wall_time /
    stdin_isatty): functions of the real host process, declared here only so
    tests can inject stubs. In production these must be Sys.getenv_opt, HOME /
    getpwuid, OS entropy, Unix.localtime, and a real isatty check respectively.
    Never proxy these to a sandboxed or remote source. *)
module type Env = sig
  type ctx = (module Pera_env.Execution_env.S)

  (* Agent execution context — may be sandboxed or remote *)
  val create :
    env:Eio_unix.Stdenv.base ->
    sw:Eio.Switch.t ->
    cwd:string ->
    ctx
  val tools : ctx -> (module Pera_env.Execution_env.S) Pera_core.Agent_types.tool list
  val has_shell : bool

  (* Host process accessors — always the real host, injected for testability *)
  val getenv_opt : string -> string option
  val home : unit -> string
  val secure_random : env:Eio_unix.Stdenv.base -> bytes -> unit
  val wall_time : unit -> Unix.tm
  val stdin_isatty : env:Eio_unix.Stdenv.base -> bool
end

module Make (E : Env) : sig
  val run : unit -> unit
  (** [run ()] does process-level IO (parses [Sys.argv], reads config files
      from XDG paths, runs [Eio_main.run]), then delegates to [run_with] with
      resolved inputs. *)

  val run_with : ?stream_fn:Pera_core.Agent_types.stream_fn ->
               Pera_cli.Resolved_inputs.t -> unit
  (** [run_with inputs] assembles the harness from already-resolved config and
      runs the interactive loop. Pure-ish (still does Eio/IO for the session
      and connector, but takes no input from [Sys.argv] / stdin-tty). When
      [~stream_fn] is given, it bypasses connector/registry construction and
      uses the supplied [stream_fn] directly — the extension point used by
      the integration smoke test with a faux provider. *)
end
```

(Expose `Config_resolver.resolve_inputs` as `Pera_cli.Resolved_inputs.t` or
re-export it; pick one name and keep it consistent.)

**Implement `lib/pera_cli/pera_cli.ml`:**

```ocaml
module Make (E : Env) = struct
  (* Local CLI helper — not Result.get_or_else (doesn't exist). *)
  let or_die = function
    | Ok x -> x
    | Error e -> Printf.eprintf "%s\n%!" e; exit 1

  let run_with ?stream_fn inputs =
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let rc = Config_resolver.resolve inputs |> or_die in
        (* Materialise the API key from the concrete api_key_source. *)
        let api_key = match rc.api_key_source with
          | None -> Printf.eprintf "[pera] no API key configured\n%!"; exit 1
          | Some (Key k) -> k
          | Some (File p) -> read_key_file p   (* Eio.Path read *)
          | Some (Command argv) -> run_key_command ~env ~sw argv
        in
        (* Build stream_fn: use the injected one if provided, else build via
           Connector_registry + Connector_adapter. *)
        let stream_fn =
          Option.get_or ~default:(
            let registry = build_registry ~api_key rc.provider_spec in
            let adapter = Pera_core.Connector_adapter.create ~registry ~env ~sw in
            Pera_core.Connector_adapter.stream_fn adapter)
            stream_fn
        in
        (* Create execution context. *)
        let cwd = Option.get_or ~default:(Sys.getcwd ()) rc.cwd in
        let ctx = E.create ~env ~sw ~cwd in
        (* Build tool list. *)
        let base_tools = E.tools ctx in
        let shell_tools =
          if E.has_shell then
            Shell_tool_builder.build_all rc.tools |> or_die
          else begin
            if rc.tools <> [] then
              Printf.eprintf "[pera] warning: shell tools defined but env has no shell\n%!";
            []
          end
        in
        if rc.mcp_servers <> [] then
          Printf.eprintf "[pera] MCP servers not yet supported\n%!";
        let all_tools = base_tools @ shell_tools in
        (* System prompt. *)
        let system_prompt = Option.get_or
          ~default:Pera_agent.Agent_harness.default_system_prompt
          rc.system_prompt
        in
        (* Session path. *)
        let session_path = Session_path.resolve
          ~session_override:rc.session_override
          ~session_dir:rc.session_dir
          ~secure_random:(E.secure_random ~env)
          ~wall_time:E.wall_time
        in
        (* Harness config. *)
        let harness_config : Pera_agent.Agent_harness.config = {
          cwd; model = rc.model; session_path; stream_fn;
          max_tokens = rc.max_tokens; exec_env = ctx;
          system_prompt; thinking_budget_tokens = rc.thinking_budget_tokens;
          compaction = rc.compaction;
        } in
        let harness = Pera_agent.Agent_harness.create ~config:harness_config ~env ~sw
          |> function
          | Ok h -> h
          | Error e -> Printf.eprintf "[pera] session error: %s\n%!" e.message; exit 1
        in
        (* Renderer + subscription. *)
        let renderer = Event_renderer.create ~output:rc.output ~json:rc.json_output in
        let _unsub = Pera_agent.Agent_harness.subscribe harness (fun event ->
          let lines = Event_renderer.render renderer event in
          List.iter (fun line -> print_string line; flush stdout) lines) in
        (* Interactive loop — lives here, not in Input_loop. *)
        run_interactive ~commands:rc.commands
          ~stdin_isaty:(E.stdin_isatty ~env)
          ~send:(Pera_agent.Agent_harness.send harness)
          ~info_stats:(fun () -> Event_renderer.stats renderer)
          ~compact_fn:(fun () -> Printf.eprintf "[pera] /compact not yet wired\n%!")
          ~env
      ))

  let run () =
    let parsed_args = Cli_args.parse ~argv:Sys.argv in
    let models_file = load_models_file ~getenv_opt:E.getenv_opt () in
    let user_config = load_user_config ~home:(E.home ()) in
    let project_config = load_project_config ~cwd:(Option.get_or ~default:(Sys.getcwd ()) parsed_args.cwd) in
    run_with {
      parsed_args; models_file; user_config; project_config;
      getenv_opt = E.getenv_opt; home = E.home ();
      session_override = parsed_args.session;
    }
end
```

`run_interactive` is a local function inside `Make` (not in `input_loop.ml`).
Line reading uses `Eio.Buf_read.line` (a `string parser`) + `Eio.Buf_read.parse_exn`
against `Eio.Stdenv.stdin env` — verified against the installed Eio:

```ocaml
let run_interactive ~commands ~stdin_isaty ~send ~info_stats ~compact_fn ~env =
  let stdin_src = Eio.Stdenv.stdin env in
  let read_line () =
    Eio.Buf_read.parse_exn ~max_size:65536 Eio.Buf_read.line stdin_src
    (* raises End_of_file at EOF; may return "" for a blank line *)
  in
  let rec loop () =
    match read_line () with
    | exception End_of_file -> ()
    | line when String.is_empty line -> loop ()
    | line ->
        (match Input_loop.parse_line ~commands line with
         | Send text  -> send text; loop ()
         | Compact    -> compact_fn (); loop ()
         | Info       -> print_endline (info_stats ()); loop ()
         | Quit       -> ()
         | Error msg  -> print_endline msg; loop ())
  in
  if Input_loop.is_tty ~stdin_isaty then loop ()
  else
    (* batch mode: read one line, send, done. *)
    match read_line () with
    | exception End_of_file -> ()
    | text -> send text
```

**Knock-on effects of substituting a different execution environment (item 5
summary):** `Agent_harness.config.exec_env : (module Execution_env.S)` is the
only env axis the harness knows. Substituting envs means providing a different
`(module Execution_env.S)` — e.g. a mock `Sh`/`Fs` for tests, a sandboxed env
for production. The harness flows it through `tool_ctx` to every tool call
unchanged. The `Env` functor above is a *separate* axis: it controls how the
env handle is constructed (`create`), which tools are attached (`tools`), and
how process-level IO is done (`getenv_opt`, etc.). Because `Env.ctx` is pinned
to `(module Execution_env.S)`, any `Env` implementation that produces a
conforming `Execution_env.S` module works end-to-end. A non-`Execution_env.S`
ctx would require a different harness — explicitly out of scope for v1.

**No new tests for `Make.run`** (it does process IO). `Make.run_with` is
tested in Phase 4 with a faux `stream_fn`.

**Verify:** `dune build` green.

---

### Phase 3 review checklist

- [ ] `dune build` — clean
- [ ] `dune test` — all `pera_cli` test suites pass
- [ ] `ocamlformat --check` — clean
- [ ] `semgrep` — clean
- [ ] `pera_cli.mli` `Env` interface pins `type ctx = (module Pera_env.Execution_env.S)`
- [ ] `run_interactive` is inside `pera_cli.ml`, not `input_loop.ml`
- [ ] No `Result.get_or_else`; `or_die` helper used for CLI exit-on-error

---

## Phase 4 — `pera` binary and packaged models

---

### Stage 4.1 — `bin/pera/` and `main.ml`

**Create `bin/pera/dune`:**

```
(executable
 (name main)
 (public_name pera)
 (package pera-cli)
 (libraries pera_cli pera_env pera_tools pera_agent containers))
```

**Create `bin/pera/main.ml`:**

```ocaml
open Containers

module Cli = Pera_cli.Pera_cli.Make (struct
  type ctx = (module Pera_env.Execution_env.S)

  let create ~env ~sw:_ ~cwd =
    Pera_env.Local_env.create ~env ~cwd

  let tools _ctx = Pera_tools.Tools.default

  let has_shell = true

  let getenv_opt = Sys.getenv_opt
  let home () = Xdg.home_dir (Xdg.create ~env:Sys.getenv_opt)

  (* Writes 16 cryptographically random bytes into [s].
     Uses Cstruct (a transitive eio dep) + Eio.Flow.read_exact. *)
  let secure_random ~env s =
    let src = Eio.Stdenv.secure_random env in
    let cs = Cstruct.create 16 in
    Eio.Flow.read_exact src cs;
    let got = Cstruct.to_string cs in
    String.blit got 0 s 0 16

  let wall_time () = Unix.localtime (Unix.gettimeofday ())

  (* Eio has no isatty primitive. Use Unix.isatty on fd 0 directly
     (acceptable: not file IO, and Eio provides no alternative). *)
  let stdin_isatty ~env:_ = Unix.isatty Unix.stdin
end)

let () = Cli.run ()
```

Add `cstruct` to `bin/pera/dune` `libraries` (transitive via eio, but list it
explicitly so the build doesn't rely on transitive visibility).

**Verify:** `dune build bin/pera/main.exe` compiles cleanly.

---

### Stage 4.2 — Packaged models catalog + install + loader search path

**Create `share/pera/models.sexp`** with the exact content from the spec's
§Example config files — Packaged models catalog section.

**Create `share/pera/dune`** — verified install stanza (see "Verification"
below):

```
(install
 (package pera-cli)
 (section share)
 (files models.sexp))
```

This installs `share/pera/models.sexp` to `<prefix>/share/pera-cli/models.sexp`.
The package-name subdirectory is added automatically by dune. We do **not**
use `(section (site ...))` because `dune_site` is experimental. The loader
searches `share/pera-cli/` accordingly.

**Verification (done during planning):** a throwaway dune project confirmed
that `(install (package P) (section share) (files f))` installs `f` to
`<prefix>/share/P/f`. The `(site ...)` form requires `(using dune_site 0.1)`
and a `(sites ...)` declaration and is experimental — rejected.

**Loader search path (`lib/pera_cli/models_loader.ml`):**

The packaged file lives at different paths in dev vs installed layouts. Use a
multi-candidate search joined with `Fpath`, returning the first existing file:

```ocaml
let default_packaged_candidates () =
  let bin_dir = Fpath.dirname (Fpath.v Sys.executable_name) in
  [ Fpath.(bin_dir / "../share/pera-cli/models.sexp")      (* installed *)
  ; Fpath.(bin_dir / "../../share/pera/models.sexp")       (* dev: _build/default/bin/pera → _build/default/share/pera *)
  ; Fpath.(Xdg.data_dir xdg / "pera-cli" / "models.sexp")  (* XDG fallback *)
  ; Fpath.v "/usr/local/share/pera-cli/models.sexp"        (* hardcoded prefix *)
  ; Fpath.v "/usr/share/pera-cli/models.sexp" ]
  |> List.map Fpath.to_string

let find_packaged () =
  match List.find_opt Sys.file_exists (default_packaged_candidates ()) with
  | Some p -> Ok p
  | None -> Error "[pera] could not locate packaged models.sexp"
```

(Use `Xdg.data_dir (Xdg.create ~env:Sys.getenv_opt)` for the XDG candidate.
Add a `PERA_MODELS_PATH` env override at the front of the list for
developability.)

Also support a user overlay at `Xdg.config_dir / "pera" / "models.sexp"` —
`Models_loader.load ~packaged_path ~user_path` already handles the merge.

**Update `Config_resolver` / `Make.run`** to compute the packaged path via
`find_packaged` and the user path via `Xdg.config_dir / "pera" / "models.sexp"`
(if it exists), then call `Models_loader.load`.

**Verify:**
- `dune build` green.
- `_build/default/bin/pera/main.exe --help` exits 0.
- `dune install --prefix /tmp/pera_install` places the file at
  `/tmp/pera_install/share/pera-cli/models.sexp` (manual check).
- The dev binary finds the file via the `../../share/pera/` candidate.

---

### Stage 4.3 — Integration smoke test (via `run_with`)

**Create `bin/pera/test/dune`:**

```
(tests
 (name smoke_test)
 (libraries pera_cli pera_connector pera_core pera_core_test_util
            pera_env pera_tools pera_agent alcotest eio eio_main containers))
```

**Create `bin/pera/test/smoke_test.ml`:**

Test `Make.run_with` with a faux `stream_fn` by constructing
`resolve_inputs` directly (bypassing `Make.run`'s `Sys.argv`/file IO). The
functor's `Env` is a mock with canned `getenv_opt`, a `secure_random` stub,
and a `Local_env.create`-backed `ctx`. The test asserts that the renderer
emits the faux response text and `AE_agent_end`.

```ocaml
(* Sketch:
   1. Build a resolve_inputs fixture with a faux model + provider_spec whose
      api is "faux".
   2. Pass the faux stream_fn via [run_with ~stream_fn] (the optional
      parameter added to run_with) so the harness uses it directly, bypassing
      connector/registry construction.
   3. Capture stdout / subscribed events; assert "Hello from test" appears
      and AE_agent_end is emitted. *)
```

The `?stream_fn` parameter on `run_with` (already declared in `pera_cli.mli`)
is the smoke-test hook and a clean extension point for custom wiring. The test
passes `~stream_fn:(Faux_provider.stream_fn [...])`.

**Verify:** `dune test` green.

---

### Phase 4 review checklist

- [ ] `dune build` — clean
- [ ] `dune test` — all suites including smoke test pass
- [ ] `_build/default/bin/pera/main.exe --help` — exits 0, shows all flags
- [ ] `dune install --prefix /tmp/pera_install` — file at
      `share/pera-cli/models.sexp`
- [ ] Dev binary locates `models.sexp` via the `../../share/pera/` candidate
- [ ] `ocamlformat --check` — clean

---

## Phase 5 — Driver cleanup

**Policy:** err on the side of **deleting** the drivers. They are replaced in
full by the `pera` binary plus the Alcotest suites. The migration stages below
are about making sure no scenario is *lost* — but the bar is "the test suites
cover the critical scenarios", not "every driver scenario is reproduced 1:1".
If a driver scenario is not already covered by a test suite and is not on the
critical list, delete it rather than re-implementing it. The critical list is
driven by `.claude/plans/driver-coverage-gaps.json` — consult it per stage.

---

### Stage 5.1 — Migrate `loop_driver.ml` → `lib/pera_core/test/`

**Audit:** compare the 14 Faux_provider scenarios in `loop_driver.ml` against:
- `lib/pera_core/test/agent_loop_test.ml`
- `lib/pera_core/test/agent_loop_tools_test.ml`
- `lib/pera_core/test/agent_loop_cancel_test.ml`
and `driver-coverage-gaps.json`.

**Critical scenarios to ensure are covered** (add if missing; else delete):
- `thinking_blocks` — thinking content emitted correctly
- `prepare_next_turn_update` — messages/model/thinking_budget replaced (now
  uses `thinking_update` ADT from Stage 0.2a)
- `before_tool_call_deny` — deny result surfaces to model
- `before_tool_call_allow` — allow proceeds normally
- `after_tool_call_fires` — hook called after each tool

**After coverage is confirmed:** delete `bin/drivers/loop_driver.ml`. Remove
from `bin/drivers/dune`.

**Verify:** `dune build && dune test` green.

---

### Stage 5.2 — Migrate `env_driver.ml` → `lib/pera_env/test/`

**Audit:** compare 9 `env_driver.ml` scenarios against:
- `lib/pera_env/test/local_env_sh_test.ml`
- `lib/pera_env/test/local_env_fs_test.ml`
and `driver-coverage-gaps.json`.

Add missing *critical* scenarios only; delete the rest. Delete
`bin/drivers/env_driver.ml`.

**Verify:** `dune build && dune test` green.

---

### Stage 5.3 — Migrate `tool_driver.ml` → `lib/pera_tools/test/`

**Audit:** compare 9 `tool_driver.ml` scenarios against the four existing tool
test files and `driver-coverage-gaps.json`.

Critical: `read_truncation`, `read_missing_path_arg`. Add if missing; else
delete. Delete `bin/drivers/tool_driver.ml`.

**Verify:** `dune build && dune test` green.

---

### Stage 5.4 — Migrate `harness_driver.ml` + `session_driver.ml`

**`harness_driver.ml` → `lib/pera_agent/test/agent_harness_test.ml`:**
critical scenario `autonomous_compaction`. Add if missing; else delete.

**`session_driver.ml` → `lib/pera_harness/test/session_writer_test.ml`:**
critical scenarios `crash_resilience`, `model_change`. Add if missing; else
delete.

Move `session_jsonl_helpers.{ml,mli}` to `lib/pera_harness/test/` if the
target tests need them; otherwise inline. Delete
`bin/drivers/harness_driver.ml`, `bin/drivers/session_driver.ml`, and
`bin/drivers/session_jsonl_helpers.{ml,mli}`.

**Verify:** `dune build && dune test` green.

---

### Stage 5.5 — `compaction_driver` cleanup + delete conversation drivers

**`compaction_driver.ml`:** the `offline_faux` scenario must be covered by
`lib/pera_harness/test/compaction_test.ml` — add if missing. Delete the
`offline_faux` scenario from `compaction_driver.ml`; **keep** the `real_model`
scenario and its live infrastructure.

**Delete:**
- `bin/drivers/conversation_driver.ml`
- `bin/drivers/conversation_driver_helpers.{ml,mli}`

**Move `echo_tool` / `counter_tool` fixtures** (referenced by the deleted
`loop_driver`) into `lib/pera_core_test_util/` only if still needed by a
surviving test; otherwise delete with the driver. If moved, keep them in a
sub-module (`Faux_provider.Test_tools`) or an unexposed `test_tools.ml` so the
public `pera-core-test-util` .mli doesn't widen.

Remove all deleted files from `bin/drivers/dune`. Verify no remaining file
imports `Conversation_driver_helpers`.

**Verify:** `dune build && dune test` green.

---

### Phase 5 review checklist

- [ ] `dune build` — clean
- [ ] `dune test` — all suites pass; no regressions
- [ ] `ocamlformat --check` — clean
- [ ] `grep -r "conversation_driver\|loop_driver\|env_driver\|tool_driver\|harness_driver\|session_driver" bin/drivers/` — empty
- [ ] `grep -r "conversation_driver_helpers" lib/ bin/` — empty
- [ ] `live_driver.ml`, `provider_driver.ml`, `compaction_driver.ml`
  (real_model) still present and build

---

## Phase 6 — OAuth device flow (RFC 8628)

Native OAuth 2.0 Device Authorization Grant for subscription providers.
Currently the only providers in our connector suite that require OAuth (rather
than a simple PAT) are **GitHub Copilot** and **GitHub Models** — both use the
same GitHub device flow endpoint and client_id. Other "TOKEN"-named providers
(HuggingFace, DigitalOcean, Friendli) use manual PATs and are already handled
by `api_key_env`.

Implementation lives entirely in `lib/pera_cli/`. No new opam dependencies:
HTTP via existing `cohttp-eio`, JSON via `yojson`.

---

### Stage 6.1 — `oauth_flow` type in `models_config`

**Edit `lib/pera_cli/models_config.ml` and `.mli`:**

Add the `oauth_flow` record before `provider_spec`:

```ocaml
type oauth_flow = {
  device_auth_url : string;
  token_url       : string;
  client_id       : string;
  scope           : string list; [@sexp.default []]
}
[@@deriving sexp, show, eq]
```

Add `oauth : oauth_flow option [@sexp.option]` to `provider_spec` (between
`api_env` and `compat`).

`oauth_flow` has no custom sexp converters — ppx_sexp_conv handles all fields —
so no `models_config_test` additions are required for this type.

**Verify:** `dune build` clean.

---

### Stage 6.2 — `oauth_token.ml` — token cache and device flow

**Create `lib/pera_cli/oauth_token.mli`:**

```ocaml
type cached_token = {
  access_token  : string;
  refresh_token : string option;
  expires_at    : float;  (** Eio monotonic time — Eio.Time.now clock at expiry *)
}

type resolve_error =
  | Device_flow_cancelled
  | Device_flow_expired
  | Device_flow_http_error of string
  | Token_refresh_failed   of string

val token_path : xdg_state_home:string -> provider:string -> string
(** [$xdg_state_home/pera/tokens/<provider>.sexp] *)

val read_cache :
  fs:#Eio.Fs.dir ->
  path:string ->
  (cached_token option, string) result
(** Read and parse the token cache file via Eio FS. [Ok None] if absent. *)

val write_cache :
  fs:#Eio.Fs.dir ->
  path:string ->
  cached_token ->
  (unit, string) result
(** Write the token cache file via Eio FS with mode 0600. Creates parent dirs. *)

val is_valid : clock:#Eio.Time.clock -> cached_token -> margin_s:float -> bool
(** [is_valid ~clock t ~margin_s] is [true] if
    [t.expires_at > Eio.Time.now clock + margin_s]. *)

val refresh :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  flow:Models_config.oauth_flow ->
  refresh_token:string ->
  (cached_token, resolve_error) result
(** POST [grant_type=refresh_token] to [flow.token_url]. Returns new tokens. *)

val device_flow :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  flow:Models_config.oauth_flow ->
  print_prompt:(user_code:string -> verification_uri:string -> unit) ->
  (cached_token, resolve_error) result
(** Full RFC 8628 device flow. Calls [print_prompt] once with the user-facing
    code and URL, then polls [flow.token_url] until authorised, expired, or
    cancelled. Respects [slow_down] responses from GitHub. *)

val resolve :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  flow:Models_config.oauth_flow ->
  cache_path:string ->
  print_prompt:(user_code:string -> verification_uri:string -> unit) ->
  (string, resolve_error) result
(** High-level resolver. Returns a valid access token, following the full
    resolution sequence: read cache → refresh if expired → device flow.
    Persists the result to [cache_path] after each successful step. *)
```

**Implement `lib/pera_cli/oauth_token.ml`:**

All I/O through Eio — `Eio.Fs` for the token cache, `Eio.Stdenv.clock env` for
all timestamps. No `Unix` or `Sys` calls. HTTP via `cohttp-eio` (same pattern as
the connector layer). JSON via `yojson`.

Token expiry: GitHub returns `expires_in` (seconds). Store
`Eio.Time.now (Eio.Stdenv.clock env) +. float_of_int expires_in` as `expires_at`.
GitHub tokens expire after 8 hours; refresh tokens after 6 months.

Device flow polling loop:
```ocaml
let rec poll ~env ~sw ~token_url ~device_code ~interval ~deadline =
  let clock = Eio.Stdenv.clock env in
  if Eio.Time.now clock >= deadline then Error Device_flow_expired
  else begin
    Eio.Time.sleep clock (float_of_int interval);
    match post_token ~env ~sw token_url device_code with
    | Ok token  -> Ok token
    | Error `Slow_down             -> poll ... ~interval:(interval + 5) ...
    | Error `Authorization_pending -> poll ... ~interval ...
    | Error (`Http_error s)        -> Error (Device_flow_http_error s)
  end
```

**Tests (`lib/pera_cli/test/oauth_token_test.ml`):**

```ocaml
(* Test: is_valid returns true when expires_at is in the future (mock clock) *)
(* Test: is_valid returns false when expired within margin (mock clock) *)
(* Test: write_cache / read_cache round-trip via Eio mock FS *)
(* Test: read_cache returns None for missing file *)
(* Test: token_path constructs expected path *)
(* Test: resolve uses cached token when valid — no HTTP calls *)
(* Test: resolve calls refresh when expired + refresh_token present *)
(* Test: resolve triggers device_flow when no cache *)
```

Use mock clock (`Eio.Time.make_clock`) and mock FS for the FS/clock tests.
Use a function-injected HTTP mock for the HTTP-touching tests.

**Verify:** `dune test` green.

---

### Stage 6.3 — Wire OAuth into config resolver

**Edit `lib/pera_cli/config_resolver.ml`:**

Extend the `resolve_api_key` function (or equivalent, per Phase 2 output) to
follow the three-step resolution order:

```ocaml
let resolve_api_key ~env ~sw ~xdg_state_home ~getenv_opt ~provider_spec ~provider_auth =
  match provider_auth.Pera_config.api_key with
  | Some src -> Ok (resolve_key_source src)  (* step 1: explicit user config *)
  | None ->
    let from_env = List.find_map
      (fun v -> getenv_opt v)
      provider_spec.Models_config.api_key_env
    in
    match from_env with
    | Some key -> Ok key  (* step 2: env var *)
    | None ->
      match provider_spec.Models_config.oauth with
      | None -> Error (no_auth_error provider_spec.name)
      | Some flow ->   (* step 3: OAuth device flow *)
        let cache_path = Oauth_token.token_path
          ~xdg_state_home ~provider:provider_spec.name in
        Oauth_token.resolve ~env ~sw ~flow ~cache_path
          ~print_prompt:(fun ~user_code ~verification_uri ->
            Printf.eprintf
              "[pera] Open %s and enter code: %s\n%!" verification_uri user_code)
        |> Result.map_error (fun e -> Oauth_token.error_to_string e)
```

**Tests (`lib/pera_cli/test/config_loader_test.ml` — extend):**

```ocaml
(* Test: api_key in config takes priority over env var and oauth *)
(* Test: env var used when no api_key in config *)
(* Test: oauth resolve called when no api_key and env var absent *)
(* Test: error emitted when no api_key, no env var, no oauth *)
```

**Verify:** `dune test` green, `ocamlformat --check`, `semgrep` clean.

---

### Stage 6.4 — `pera login` / `pera logout` subcommands

**Edit `bin/pera/main.ml`:**

Add two subcommands using Cmdliner:

```
pera login <provider>   — trigger OAuth device flow, store token; exit
pera logout <provider>  — delete cached token file; exit
```

`login` reuses `Oauth_token.resolve` with `print_prompt` writing to stdout.
`logout` calls `Sys.remove` on the token path, silently succeeds if not
found.

**Tests:** smoke test in `bin/pera/` (manual/interactive — not automated).

---

### Phase 6 review checklist

- [ ] `dune build` — clean
- [ ] `dune test` — all suites pass
- [ ] `ocamlformat --check` — clean
- [ ] `semgrep` — clean
- [ ] No real network calls in tests (`oauth_token` HTTP is function-injected)
- [ ] Token cache file created with mode 0600 (test verifies)
- [ ] `resolve_api_key` follows the three-step priority order
- [ ] `Device_flow_cancelled` / `Device_flow_expired` produce actionable error messages
- [ ] `pera login github-copilot` triggers device flow end-to-end (manual smoke test)
- [ ] `pera logout github-copilot` removes the cached token (manual smoke test)

---

## Summary of phases

| Phase | Description | New packages | Key deliverables |
|---|---|---|---|
| 0 | Prerequisites | — | Connector rename, thinking refactor (0.2a) + feature (0.2b), tool refactor, harness config, connector ~api_key (0.5), env cwd (0.6) |
| 1 | Config types | `pera-cli` skeleton | models.sexp + config.sexp sexp types, loading, merging |
| 2 | Resolution layer | — | Env vars (injected), CLI args, pure config resolver, session path |
| 3 | pera-cli library | — | Shell tool builder, event renderer, input parsing, Make functor (run + run_with) |
| 4 | pera binary | `pera` executable | bin/pera/main.ml, packaged models.sexp + loader search, smoke test |
| 5 | Driver cleanup | — | Migrated critical scenarios, deleted obsolete drivers |
| 6 | OAuth device flow | — | oauth_token.ml, token cache, resolver wiring, pera login/logout |

Total stages: 29 (6 + 5 + 5 + 4 + 3 + 5 + 4 plus 6 phase reviews).
Each stage is scoped to fit within a single focused LLM session.

---

## Open implementation notes (to resolve during coding, not blocking)

- **Cmdliner argv injection:** `Cmdliner.Term.eval` reads `Sys.argv` directly.
  If true unit-testing of `Cli_args.parse` is desired, wrap the term in a
  function that sets `Sys.argv` in the test. The current plan tests only
  converters + `to_partial_config`, which is sufficient.
- **`run_with ?stream_fn`:** confirm the harness accepts an externally
  supplied `stream_fn` without going through the connector registry (it does
  — `config.stream_fn` is a field).