# M6 — Survivable agent (autonomous compaction, Level 3)

> Source: `SPECIFICATION.md` §3 (synthetic messages, sessions), §5 (between-turn hooks),
> §8 (compaction — full subsystem; M6 targets **Level 3, autonomous**), §11 (M6 milestone),
> §12 (`compaction_driver` + `harness_driver` *with compaction enabled*).
>
> **Milestone M6:** M5 plus compaction at Level 3 (autonomous). Sessions of any length
> terminate gracefully or compact themselves. Context overflow is not a failure mode for
> normal use.

This plan is written to be executed stage-by-stage by an implementer that follows
instructions literally. Each stage states the exact files, the exact interface, the
implementation shape, and the tests. Read the "Settled design decisions" first — they
resolve every ambiguity; do not revisit them without asking.

---

## Progress (as of 2026-06-09)

| Stage | Title | Status | Notes |
|---|---|---|---|
| 0 | Agent-core extensions | ✅ **DONE** | All refutation sites collapsed to `List.map Agent_types.to_provider_message`; `emit` added to `should_stop_ctx`; subscriber stub arms present in `agent_harness.ml`. |
| 1 | `Token_estimator` + `Model_window` | ✅ **DONE — deviation** | Both modules landed in `pera_core` (not `pera_harness`) per commit `3fcc8ae`. Rationale: pure functions over `pera_provider`/`pera_types`; no harness dependency; `pera_core` already has `yojson`. |
| 1.5 | `context_window` on `Types.model` (prerequisite) | ✅ **DONE** | Resolution of Open Question 3 (Option 1). `Pera_types.Types.model` now has `context_window : int`; `Model_window.for_model` is `fun m -> m.context_window`; api/id-prefix table deleted. All ~20 construction sites updated. Session-types JSON codec serialises `context_window` alongside `id`/`api`. `model_window_test.ml` rewritten with five cases (incl. variant disambiguation and small-OpenAI-compatible cases). Build + tests green. |
| 2 | `Session_writer.write_compaction` | ⬜ pending | `session_writer.mli` does not yet expose `write_compaction`. |
| 3 | `Compaction` module | ⬜ pending | No `lib/pera_harness/compaction.{ml,mli}` exists. |
| 4 | `Agent_harness` compaction wiring | ⬜ pending | `Agent_harness.config` has no `compaction` field; subscriber has stub arms only. |
| 5 | `compaction_driver` + `session_driver` scenario 6 | ⬜ pending | No `bin/drivers/compaction_driver.ml`. |
| 6 | `harness_driver` autonomous-compaction scenario | ⬜ pending | `harness_driver.ml` has the three M5 scenarios but no compaction scenario. |
| 7 | Docs + verification sweep | ⬜ pending | `AGENTS.md` / `USAGE.md` untouched. |

Build state at the time of this update: `dune build` and `dune runtest` both green on the
merged worktree (m6 + main).

---

## Settled design decisions

These are **decided**. They are the load-bearing choices for M6. Do not deviate.

1. **Synthetic compaction messages are a real `synthetic` constructor (spec-faithful).**
   The in-memory agent context represents a compaction summary as
   `Agent_types.Synthetic (Compaction_summary { summary })`, **not** as a plain `Real`
   user message. This matches SPECIFICATION.md §3 ("a `CompactionEntry` … corresponds to a
   synthetic user message") and §7 ("`convert_to_llm` … renders compaction summary messages
   (synthetic user messages produced by compaction) as ordinary user messages with explicit
   framing text"). The `agent_types.mli` forward-compat comment already anticipates this:
   *"New synthetic kinds (e.g. compaction summaries) will be added as constructors here at M6."*

2. **`convert_to_llm` callers collapse to `List.map Agent_types.to_provider_message`.**
   We add a single shared renderer `Agent_types.to_provider_message : agent_message ->
   Provider.message` (`Real m -> m`; `Synthetic s -> synthetic_to_message s`). Every
   *caller* of `convert_to_llm` (the `agent_loop_config` callback — in `agent_harness.ml`,
   every test/driver copy, and `agent_wrapper_test.ml`) passes `List.map
   Agent_types.to_provider_message` as its value. The `convert_to_llm` **field** in
   `agent_loop_config` is not removed — the loop remains generic. This turns the eight
   current `| Synthetic _ -> .` refutation sites into uniform, mechanical edits and removes
   all per-site rendering duplication. (All synthetics in M6 are LLM-visible, so nothing is
   dropped. A future *invisible* synthetic would change `to_provider_message` to return
   `option`; not needed now — note it in the `.mli`.)

3. **Framing constant lives in `pera_core`.** `Agent_types.compaction_framing =
   "Context from earlier conversation:\n\n"`. `synthetic_to_message (Compaction_summary
   {summary})` returns `UserMessage { role="user"; content=[UText (compaction_framing ^
   summary)] }`. Both the in-memory render path and the session-write path use this one
   function, so the LLM-visible text and the on-disk `MessageEntry` are byte-identical.

4. **Compaction triggers in `should_stop_after_turn`; the new context is installed in
   `prepare_next_turn`.** Per SPECIFICATION.md §5 ("Compaction triggers as a side effect of
   `should_stop_after_turn` … compact synchronously, update the context, and return
   `false`"). Because `should_stop_after_turn` cannot itself write `messages_ref`, the two
   harness hooks share a `pending : agent_message list option ref`: the `should_stop` hook
   does the work and stashes the compacted list; the `prepare_next_turn` hook pops it and
   returns `turn_update { messages = Some compacted; _ }`. The loop applies it (existing
   `apply_turn_update`).

5. **The loop exposes an event sink to the `should_stop` hook via a new ctx field
   `emit : agent_event -> unit`.** The loop populates it with its own `push_event
   out_stream`. This is the *only* loop change in M6 and it keeps the loop generic (it just
   hands the hook a way to push into the loop's own ordered stream). Compaction events
   therefore flow through the **same** event stream as `AE_turn_end`, so the actor's fan-out
   delivers them to subscribers **after** `AE_turn_end` and **before** the next turn — the
   ordering the session writer depends on. (Do **not** emit compaction events by calling
   subscribers directly from the hook: `AE_turn_end` is buffered but possibly not yet
   drained when the hook runs, so a direct call would race ahead of it.)

6. **Session writes stay in the subscriber (M5 invariant preserved).** The compaction hook
   emits events only; it never touches the `Session_writer`. The existing
   `session_subscriber` (in `Agent_harness`) grows three cases. On `AE_compaction_end` it
   writes, in order: `write_compaction` → `write_message` (the synthetic user message) →
   `write_leaf`. This matches SPECIFICATION.md §8 ("CompactionEntry appended … MessageEntry
   appended for the synthetic … leaf moves to the new last entry") and the "storage
   redundancy" note (synthetic stored as a real `MessageEntry` *and* the summary recorded in
   the `CompactionEntry`).

7. **`first_kept_entry_id` is the pre-compaction tip (documented approximation).** The
   `Session_writer` owns entry IDs; the harness does not see them. At `AE_compaction_end`
   the subscriber uses `Session_writer.current_parent_id` (the last content entry before
   compaction — i.e. the compaction entry's own parent) as `first_kept_entry_id`. This keeps
   the entry **well-formed and forward-compatible** (a valid UUID string is present). Exact
   tail-boundary tracking is a **v2 restore** concern and is explicitly out of scope; the
   drivers assert the field is a present, valid id, not that it points at the exact first
   kept message. Document this at the call site.

8. **No Level-4 robustness in M6.** Retry-on-overshoot, tighter-tail retries, and a
   configurable compaction *target model* are **M7 / Level 4** (SPECIFICATION.md §8
   "Architectural levels"). M6 does a **single** summarisation attempt. On failure it emits
   `AE_compaction_error`, leaves the context untouched, and returns `false` (the run
   continues uncompacted — the next call may overflow, which is the documented hard error).

9. **Compaction trigger is configurable for determinism.** `Agent_harness.config` gains
   `compaction : compaction_config option`. `None` = M5 behaviour (no hooks wired). `Some {
   trigger_tokens; tail_size }` enables autonomous compaction: compact when the estimated
   token count of `convert_to_llm context.messages` exceeds `trigger_tokens`. Production
   callers compute `trigger_tokens` with `Model_window.default_trigger_tokens model`
   (≈ 70 % of the model window); the `harness_driver` passes a small value so a scripted
   `Faux_provider` run trips it deterministically.

10. **Re-compaction guard.** `Compaction.compact` returns `Ok None` ("nothing to compact")
    when `List.length messages <= tail_size + 1` (empty middle). The hook treats `Ok None`
    as a silent no-op (no events, returns `false`). This prevents summarising-the-summary in
    pathological tiny-window configurations and makes the driver scenarios robust.

11. **No manual `/compact` CLI command in M6.** SPECIFICATION.md §10's CLI is not built
    yet (no CLI milestone). Level 2's "user-issued `/compact`" is validated by
    `compaction_driver` calling `Compaction.compact` directly (the same code path the
    autonomous hook uses). A `Agent_harness.compact` convenience entry point is deferred to
    the CLI milestone. State this in "What M6 does NOT include" so it is a scoped decision,
    not an omission.

12. **Token estimation is conservative and char-based (spec §8).** `Token_estimator`
    estimates `ceil(text_len / 3)` per rendered message plus a fixed per-message overhead,
    summed across the converted provider messages. It overestimates (triggers early) by
    design. A precise tokeniser is a later substitution; the seam is `Token_estimator`.

---

## Open questions

- **Q (resolved → decision 1):** `Real` user message vs. `Synthetic` constructor for the
  summary. Chosen: `Synthetic` (spec-faithful). The alternative (store as `Real`) was
  rejected because §3 and §7 explicitly describe synthetic messages and the architecture
  intends the `Synthetic` arm to grow here.
- **Q (resolved → decision 5):** how compaction events reach subscribers. Chosen: a
  `should_stop_ctx.emit` field routing through the loop's own stream (correct ordering).
- **Q3 (RESOLVED 2026-06-09 → Option 1):** `Model_window.for_model`
  currently keys context-window size by `model.id` prefix + `model.api`, returning
  `anthropic_window = 200_000` or `openai_window = 128_000`. This is **wrong** for the
  realistic deployment surface:
  - Claude 4.x families have **both 200K and 1M context-window variants**
    (e.g. `claude-opus-4-7` vs. `claude-opus-4-7[1m]`) — same `id` prefix, same `api`,
    different windows.
  - `api = "openai-completions"` covers anything that speaks the OpenAI Chat-Completions
    protocol: gpt-4o (128K), gpt-4 (8K/32K), local llama (4K/8K), DeepSeek (64K),
    Qwen (128K+), self-hosted vLLM (anything). A single 128K constant overshoots small
    local models (dangerous — won't trigger compaction until after overflow) and
    undershoots large ones.

  Three resolution shapes, in increasing invasiveness:

  1. **(Preferred) Add `context_window : int` (and optionally `output_window : int`) to
     `Pera_types.Types.model`.** The caller already chose the model; making the window a
     property of the chosen model record is the right ownership. `Model_window.for_model`
     becomes `fun (m : model) -> m.context_window`; the api/id-prefix table goes away.
     Construction sites (`live_driver`, `harness_driver`, test fixtures) gain one extra
     field — small fan-out (grep for `Types.{ id =`). Provider-list config (when we add
     per-provider model registries) supplies the field.
  2. **Add a `context_window` field to `Agent_harness.compaction_config` and drop
     `Model_window.default_trigger_tokens`.** Caller computes `trigger_tokens` directly;
     `Model_window` is reduced to a no-op or deleted. Simplest, but pushes the
     "what's this model's window" question onto every harness caller.
  3. **Keep `Model_window` as-is and document the override path.** `compaction_config`
     already takes `trigger_tokens` directly; `Model_window` is only used as a default.
     Cheap, but the default is wrong often enough that callers will get burned.

  **Recommendation:** Option 1. The `model` record already carries the API family; the
  context window is the same kind of metadata. Doing this **before Stage 4** keeps the
  Stage 4 caller code simple. If we defer, Stage 4 should pass `trigger_tokens` directly
  (Option 2) and never call `Model_window.default_trigger_tokens` from production code.

  **Decision (2026-06-09):** Option 1. Add `context_window : int` to
  `Pera_types.Types.model`. `Model_window.for_model` becomes `fun (m : Types.model) ->
  m.context_window`; the api/id-prefix table and `anthropic_window`/`openai_window`
  constants are deleted. All construction sites (`live_driver`, `harness_driver`, test
  fixtures, anywhere `Types.{ id = …; api = …; …}` literal appears) gain the new field.
  This is a **prerequisite Stage 1.5** that must land before Stage 4. Tests for
  `model_window_test.ml` update to construct models with explicit windows; the
  `test_unknown_defaults` case is removed (no default any more — the field is required).

If the user prefers the simpler `Real`-message approach for M6, only Stage 0 and the
`Compaction` constructor change; everything else is identical. Flag this before starting if
in doubt — but the default is `Synthetic`.

---

## Baseline

- Branch: `driver-improvements`. M5 (auditable agent) is **complete and committed**
  (`5484970 feat(harness_driver)`, `c92ac14 feat(session_driver)`, `32a0f12
  feat(agent_harness)` …). `dune build` and `dune runtest` are green. Run both before
  starting and record the result.
- Packages: `pera_types`, `pera_provider`, `pera_core`, `pera_core_test_util`, `pera_env`,
  `pera_harness`, `pera_tools`, `pera_agent`.
- Drivers present: `provider_driver`, `loop_driver`, `conversation_driver`, `env_driver`,
  `tool_driver`, `session_driver`, `harness_driver`, `live_driver`.

### What already exists (do not re-implement)

- **`Session_types.compaction_entry` + its JSON codec** — already defined and serialised
  (`session_types.ml`: `Compaction` arm emits `type:"compaction"`, `summary`,
  `first_kept_entry_id`). M6 only adds the *writer* method, not the type or codec.
- **`Agent_types.synthetic` exists as `type synthetic = |`** (uninhabited) with `Synthetic
  of synthetic` in `agent_message`. M6 inhabits it.
- **The between-turn hook plumbing** (`should_stop_after_turn`, `prepare_next_turn`,
  `apply_turn_update`, `turn_update`) is fully wired in `agent_loop.ml`. M6 uses it as-is
  except for adding the `emit` field to `should_stop_ctx`.
- **`Provider_adapter`** turns a `Provider_registry.t` into a real `stream_fn` (used by
  `live_driver`). `compaction_driver`'s real-model path reuses this.
- **`agent_event` derives `eq`/`show`** via `[@@deriving eq, show]`, but `pp_agent_event`
  is **hand-written and exhaustive** — adding variants requires extending it. Almost all
  test/driver matches on `agent_event` use a `| _ ->` catch-all and will **not** break; the
  only *exhaustive* consumer is `session_subscriber` in `agent_harness.ml` (and
  `pp_agent_event`).

### Sites that adding the `Compaction_summary` constructor will break (must all be fixed in Stage 0)

`agent_message_equal` and `pp_agent_message` (both hand-written, `Real`-only) **and** these
eight `| Synthetic _ -> .` / `| Some (Synthetic _) -> .` refutation sites:

- `lib/pera_core/test/agent_loop_helpers.ml:61`
- `lib/pera_agent/agent_harness.ml:37`
- `lib/pera_harness/test/agent_wrapper_test.ml:16`
- `bin/drivers/loop_driver.ml:74`
- `bin/drivers/conversation_driver_helpers.ml:101`
- `bin/drivers/conversation_driver_helpers.ml:152`
- `bin/drivers/conversation_driver_helpers.ml:169` (option-shaped: `| Some (Agent_types.Synthetic _) -> .`)
- (the eighth is the second match in `agent_loop_helpers`/`conversation_driver_helpers` if
  the compiler flags it — fix every non-exhaustive match the compiler reports)

Each becomes either `List.map Agent_types.to_provider_message` (preferred for the
`convert_to_llm` helpers) or, for the option-shaped site, `| Some (Synthetic s) -> Some
(Agent_types.synthetic_to_message s)`.

---

## Stage map

| Epoch | Stage | Title | Package | Depends |
|---|---|---|---|---|
| 0 | 0 | Agent-core extensions: inhabit `synthetic`, add compaction events, add `emit` | `pera_core` (+ all refutation sites) | — |
| 0 | 1 | `Token_estimator` + `Model_window` | `pera_harness` | 0 |
| 1 | 2 | `Session_writer.write_compaction` | `pera_harness` | 0 |
| 1 | 3 | `Compaction` module (split / summarise / render) | `pera_harness` | 1, 2 |
| 2 | 4 | `Agent_harness` compaction wiring (autonomous L3) | `pera_agent` | 3 |
| 3 | 5 | `compaction_driver` + `session_driver` compaction scenario | `bin/drivers` | 3 |
| 3 | 6 | `harness_driver` autonomous-compaction scenario | `bin/drivers` | 4 |
| 4 | 7 | Docs + full verification sweep | repo | 5, 6 |

Build stays green after **every** stage. Stages 0–3 add capability without changing M5
runtime behaviour (no hooks are wired until Stage 4).

---

## Epoch 0 — Foundations

### Stage 0 — Agent-core extensions  ✅ DONE

**Goal:** inhabit `synthetic`, add the shared renderer, add three compaction `agent_event`s,
add the `emit` field to `should_stop_ctx`, and fix every site the type changes break. No
behaviour change — `should_stop_after_turn` is still `None` everywhere, so nothing emits the
new events yet.

**Files to modify**

- `lib/pera_core/agent_types.mli`
- `lib/pera_core/agent_types.ml`
- `lib/pera_core/agent_loop.mli`
- `lib/pera_core/agent_loop.ml`
- `lib/pera_core/test/agent_loop_helpers.ml` (+ `.mli` doc)
- `lib/pera_agent/agent_harness.ml`
- `lib/pera_harness/test/agent_wrapper_test.ml`
- `bin/drivers/loop_driver.ml`
- `bin/drivers/conversation_driver_helpers.ml`

**Files to create**

- Preferred: extend `lib/pera_core/test/agent_types_test.ml` with the Stage 0 test cases
  (no dune change needed; the tests already belong to the `(tests ...)` stanza).
- Alternative: create `lib/pera_core/test/synthetic_test.ml` — but then **also modify
  `lib/pera_core/test/dune`**: add `synthetic_test` to both `(names ...)` and `(modules ...)`
  in the shared `(tests ...)` stanza, otherwise the file is silently ignored by the build.

#### `agent_types.mli` / `.ml` changes

```ocaml
(* mli *)
type synthetic = Compaction_summary of { summary : string }
val equal_synthetic : synthetic -> synthetic -> bool
val pp_synthetic : Format.formatter -> synthetic -> unit
val show_synthetic : synthetic -> string

val compaction_framing : string
(** "Context from earlier conversation:\n\n" — the user-role framing prepended to a
    compaction summary when it is rendered for the LLM. *)

val synthetic_to_message : synthetic -> Pera_provider.Provider.message
(** Render a synthetic message into the provider message the LLM sees. For
    [Compaction_summary {summary}] this is a user message whose single text block is
    [compaction_framing ^ summary]. *)

val to_provider_message : agent_message -> Pera_provider.Provider.message
(** [Real m -> m]; [Synthetic s -> synthetic_to_message s]. The canonical agent→provider
    message projection. NOTE: every synthetic in M6 is LLM-visible, so this is total. If a
    future *invisible* synthetic is added, change the return type to [option] and have
    [convert_to_llm] [filter_map] over it. *)
```

```ocaml
(* ml *)
type synthetic = Compaction_summary of { summary : string } [@@deriving eq, show]

let compaction_framing = "Context from earlier conversation:\n\n"

let synthetic_to_message = function
  | Compaction_summary { summary } ->
      Pera_provider.Provider.UserMessage
        Pera_types.Types.
          { role = "user"; content = [ UText (compaction_framing ^ summary) ] }

let to_provider_message = function
  | Real m -> m
  | Synthetic s -> synthetic_to_message s
```

Extend `agent_message_equal` and `pp_agent_message` (both currently `Real`-only):

```ocaml
let agent_message_equal m1 m2 =
  match (m1, m2) with
  | Real a, Real b -> Pera_provider.Provider.equal_message a b
  | Synthetic a, Synthetic b -> equal_synthetic a b
  | Real _, Synthetic _ | Synthetic _, Real _ -> false

let pp_agent_message ppf = function
  | Real msg -> Format.fprintf ppf "Real(%s)" (Pera_provider.Provider.show_message msg)
  | Synthetic s -> Format.fprintf ppf "Synthetic(%s)" (show_synthetic s)
```

Add three `agent_event` variants (place them after `AE_tool_execution_end`):

```ocaml
  | AE_compaction_start
      (** Autonomous compaction has begun (threshold crossed). *)
  | AE_compaction_end of { summary : string }
      (** Compaction succeeded; [summary] is the produced summary text. The harness
          session subscriber writes the Compaction entry, the synthetic user message, and a
          Leaf in response to this event. *)
  | AE_compaction_error of { message : string }
      (** Compaction failed; [message] describes the failure. The context is unchanged and
          the run continues uncompacted. *)
```

These have only `string`/no fields, so the derived `equal_agent_event` extends
automatically. **Extend the hand-written `pp_agent_event`** with the three cases (e.g.
`"[AE_compaction_start]"`, `"[AE_compaction_end] summary_len=%d"`, `"[AE_compaction_error]
%s"`). `show_agent_event` already delegates to `pp_agent_event`.

#### `should_stop_ctx.emit` (the only loop change)

In `agent_loop.mli` and `agent_loop.ml`, add to `should_stop_ctx`:

```ocaml
  emit : Agent_types.agent_event -> unit;
      (** Push an event into the loop's own event stream, in order, after this turn's
          AE_turn_end and before the next turn. Used by the harness compaction hook to emit
          AE_compaction_* events. *)
```

In `agent_loop.ml`, `run_inner.invoke_should_stop` constructs the ctx — add
`emit = (fun ev -> push_event out_stream ev);`. (`out_stream` is in scope.) Only the
`agent_loop.ml` construction site changes; hooks read the ctx, so existing test hooks are
unaffected.

#### Fix the refutation sites

- All `convert_to_llm` helpers (`agent_harness.ml`, `agent_loop_helpers.ml`,
  `conversation_driver_helpers.ml`, `loop_driver.ml`): replace the `List.filter_map (… |
  Synthetic _ -> .)` body with `List.map Agent_types.to_provider_message messages`.
- `agent_wrapper_test.ml:16`: same `List.map Agent_types.to_provider_message`.
- `conversation_driver_helpers.ml:169` (option-shaped): `| Some (Agent_types.Synthetic s)
  -> Some (Agent_types.synthetic_to_message s)`.
- Compile; fix any remaining non-exhaustive-match warnings the compiler reports the same way.

#### Fix `session_subscriber` in `agent_harness.ml`

Adding the three new `agent_event` constructors makes the exhaustive match in
`session_subscriber` non-exhaustive. Stage 4 adds the real implementation; Stage 0 must add
**stub no-op arms** so the build is warning-free:

```ocaml
| Pera_core.Agent_types.AE_compaction_start -> Ok ()
| Pera_core.Agent_types.AE_compaction_error _ -> Ok ()
| Pera_core.Agent_types.AE_compaction_end _ -> Ok ()
(* Stage 4 will replace this AE_compaction_end stub with the real writer sequence. *)
```

These stubs are temporary; they appear in `agent_harness.ml` until Stage 4 wires the real
behaviour. Without them Stage 0 produces non-exhaustive-match warnings in the most critical
production file.

#### Tests (Stage 0)

`lib/pera_core/test/synthetic_test.ml` (pure Alcotest, no Eio):

- `test_synthetic_to_message_uses_framing`: `synthetic_to_message (Compaction_summary
  {summary="S"})` is a `UserMessage` whose text equals `compaction_framing ^ "S"`.
- `test_to_provider_message_real_passthrough`: `to_provider_message (Real m) = m`.
- `test_to_provider_message_synthetic_renders`: equals `synthetic_to_message s`.
- `test_agent_message_equal_synthetic`: equal/unequal `Compaction_summary` pairs.
- `test_agent_message_equal_mixed_is_false`: `Real` vs `Synthetic` → false.
- `test_equal_agent_event_compaction`: `AE_compaction_end {summary="a"}` equals itself,
  differs from `{summary="b"}` and from `AE_compaction_start`.

**Acceptance:** `dune build` with **zero warnings** + **all existing M5 tests pass
unchanged**; the three new events and the `Compaction_summary` constructor exist;
`pp_agent_event` is exhaustive again; `session_subscriber` is exhaustive again (stub arms).

---

### Stage 1 — `Token_estimator` + `Model_window`  ✅ DONE (deviation: landed in `pera_core`)

**Goal:** the two pure observation pieces (Level-1 token awareness). No IO.

**Deviation from the original plan:** both modules were placed in `pera_core`, not
`pera_harness` (commit `3fcc8ae`). Both are pure functions over `pera_provider` /
`pera_types` with no harness dependency; `pera_core` already has `yojson`. Future stages
that reference them must use `Pera_core.Token_estimator` / `Pera_core.Model_window`
rather than `Pera_harness.…`.

**Files (actual locations)**

- `lib/pera_core/token_estimator.mli` / `.ml`
- `lib/pera_core/model_window.mli` / `.ml`
- `lib/pera_core/test/token_estimator_test.ml`
- `lib/pera_core/test/model_window_test.ml`
- `lib/pera_core/dune` — `token_estimator model_window` in `modules`
- `lib/pera_core/test/dune` — the two test modules

#### `Token_estimator`

```ocaml
(* mli *)
val estimate_text : string -> int
(** ceil(String.length / 3) — conservative (overestimates). *)

val estimate_message : Pera_provider.Provider.message -> int
(** Sum of estimate_text over every text-bearing part of the message, plus a fixed
    per-message overhead of 4 tokens. Renders: user UText; assistant AText + AThinking.text
    + AToolCall (name + Yojson.Safe.to_string arguments); tool_result content
    (Yojson.Safe.to_string). UImage contributes a flat 8-token placeholder. *)

val estimate_messages : Pera_provider.Provider.message list -> int
(** Sum of estimate_message. *)
```

Implementation notes: `open Containers`. `estimate_text s = (String.length s + 2) / 3`.
Pattern-match exhaustively on `Provider.message` and the content variants (no catch-alls —
the spec wants conservative coverage). Keep the per-message overhead as a named constant
`per_message_overhead = 4`.

#### `Model_window`

```ocaml
(* mli *)
val for_model : Pera_types.Types.model -> int
(** The model's input context window in tokens. Known ids → exact; otherwise a conservative
    default of 200_000. *)

val default_ratio : float
(** 0.70 — the fraction of the window at which compaction should trigger (spec §8). *)

val default_trigger_tokens : ?ratio:float -> Pera_types.Types.model -> int
(** [int_of_float (ratio *. float (for_model model))]. *)
```

Implementation: small table keyed by a prefix/`api` of `model.id`/`model.api`:
`"claude"`-prefixed ids or `api="anthropic"` → `200_000`; `api="openai-completions"` or
`"gpt"`-prefixed → `128_000`; default `200_000`. Name the constants
(`anthropic_window`, `openai_window`, `default_window`).

#### Tests (Stage 1)

`token_estimator_test.ml`:
- `test_estimate_text_is_ceil_div_3`: `estimate_text "abcd" = 2`; `estimate_text "" = 0`.
- `test_estimate_message_includes_overhead`: a one-char user message ≥ `per_message_overhead`.
- `test_estimate_messages_monotonic`: appending a message strictly increases the estimate.
- `test_estimate_counts_tool_call_arguments`: an assistant `AToolCall` with a long JSON
  argument estimates higher than the same message with empty args.

`model_window_test.ml`:
- `test_anthropic_window`: `for_model {id="claude-haiku-4-5-…"; api="anthropic"} = 200_000`.
- `test_openai_window`: `for_model {id="gpt-4o"; api="openai-completions"} = 128_000`.
- `test_unknown_defaults`: `for_model {id="weird"; api="weird"} = 200_000`.
- `test_default_trigger_tokens`: `default_trigger_tokens model = 140_000` for anthropic.

**Acceptance:** build + tests green; both modules pure (no Eio/IO).

---

## Epoch 1 — Compaction pipeline

### Stage 2 — `Session_writer.write_compaction`  ⬜ pending

**Goal:** the one missing writer method. The `Compaction` *entry type* and *codec* already
exist (`session_types.ml`); we only add the advancing writer.

**Files to modify**

- `lib/pera_harness/session_writer.mli` / `.ml`
- `lib/pera_harness/test/session_writer_test.ml`

#### Interface

```ocaml
val write_compaction :
  t ->
  summary:string ->
  first_kept_entry_id:Entry_id.t ->
  (unit, Pera_types.Types.file_error) result
(** Append a [compaction] entry parented at the current tip, then advance the tip to it.
    The synthetic summary message is written separately by the caller (a subsequent
    write_message), parenting to this entry. *)
```

Implementation mirrors `write_model_change` exactly (advancing): generate id, build
`Session_types.Compaction { id; parent_id = t.current_parent_id; timestamp; summary;
first_kept_entry_id }`, `append_line`, then `t.current_parent_id <- Some id`.

#### Tests (Stage 2)

- `test_write_compaction_emits_compaction_entry`: after `write_session_info` +
  `write_message m` + `write_compaction ~summary:"S" ~first_kept_entry_id:fk`, the third
  line has `type:"compaction"`, `summary:"S"`, `first_kept_entry_id:fk`, and
  `parent_id = id(m)`.
- `test_write_compaction_advances_tip`: a following `write_message synth` has
  `parent_id = id(compaction)`.
- `test_compaction_then_synthetic_then_leaf_chain`: sequence `session_info → user →
  assistant → compaction → synthetic(user) → leaf`; content chain (excluding leaf) is
  gap-free; leaf is childless (no entry references the leaf id).

**Acceptance:** build + tests; existing `session_writer_test` still green.

---

### Stage 3 — `Compaction` module  ⬜ pending

**Goal:** the pure-from-IO-except-via-`stream_fn` compaction algorithm. Per SPECIFICATION.md
§12, this module must be writable **without instantiating a full harness** — it takes a
message list and a `stream_fn` in, and gives a new message list + summary out. The
`compaction_driver` exercises exactly this surface.

**Files to create**

- `lib/pera_harness/compaction.mli` / `.ml`
- `lib/pera_harness/test/compaction_test.ml`

**Files to modify**

- `lib/pera_harness/dune` — add `compaction` to `modules`; ensure `pera_core` is in
  `libraries` (it already is, per M5 decision 2).
- `lib/pera_harness/test/dune` — add `compaction_test`; ensure `pera_core_test_util` is in
  test libraries (for `Faux_provider`).

#### Interface

```ocaml
type result = {
  new_messages : Pera_core.Agent_types.agent_message list;
      (** [ first ] @ [ Synthetic (Compaction_summary {summary}) ] @ tail. *)
  summary : string;
}

val summarise_prompt : string
(** The hardcoded compaction system prompt (spec §8). *)

val render_messages_to_text : Pera_provider.Provider.message list -> string
(** A plain-text transcript of the messages to summarise: one block per message, role-
    labelled, tool calls and results inlined as text. Robust for the summarisation call
    (avoids provider message-shape constraints like "tool_result must follow a tool_use"). *)

val compact :
  stream_fn:Pera_core.Agent_types.stream_fn ->
  model:Pera_types.Types.model ->
  options:Pera_provider.Provider.simple_stream_options ->
  messages:Pera_core.Agent_types.agent_message list ->
  tail_size:int ->
  sw:Eio.Switch.t ->
  (result option, string) result
(** Compact [messages]. Returns:
    - [Ok (Some result)] on success;
    - [Ok None] when there is nothing to compact ([List.length messages <= tail_size + 1],
      i.e. empty middle — the re-compaction guard);
    - [Error msg] when the summarisation LLM call fails or yields empty text. *)
```

#### Algorithm (`compact`)

1. Let `n = List.length messages`. If `n <= tail_size + 1` → `Ok None`.
2. `first = List.hd messages`. `tail = ` last `tail_size` messages.
   `middle = ` messages from index `1` to `n - tail_size - 1` inclusive (non-empty by step 1).
3. `rendered = render_messages_to_text (List.map Agent_types.to_provider_message middle)`.
4. Build the summarisation provider context:
   ```ocaml
   let user = Provider.UserMessage Types.{ role = "user";
     content = [ UText ("Conversation to summarise:\n\n" ^ rendered) ] } in
   let context = Provider.{ system = summarise_prompt; messages = [ user ];
                            tools = []; thinking = false } in
   ```
5. `let stream = stream_fn ~model ~context ~options ~sw in`
   Consume it with a single match on `Event_stream.iter`'s return value (which is the
   final result — no separate `Event_stream.result` call needed):
   ```ocaml
   match Event_stream.iter stream ~f:(fun _ -> ()) with
   | Error e -> Error e
   | Ok final ->
   ```
   Collect all `AText` blocks of `final.content`, concatenate → `summary`.
   If `summary = ""` → `Error "compaction produced empty summary"`.
   (`Event_stream.iter` returns `(assistant_message, string) result`; `e` is already a
   string. No `Printexc.to_string` needed.)
6. `new_messages = [first] @ [ Agent_types.Synthetic (Compaction_summary { summary }) ] @
   tail`. Return `Ok (Some { new_messages; summary })`.

`summarise_prompt` (concrete text — keep it close to this):

```
You are compacting a long coding-assistant conversation to fit a context window.
Produce a concise summary that PRESERVES:
- the original task / goal;
- every file path the agent has created or edited, each with a one-line note of what changed;
- outstanding decisions, open questions, and the current plan;
- the working understanding of the project (key facts, constraints).
DISCARD:
- file contents (they can be re-read);
- exploration that led nowhere;
- tool calls whose results were superseded by later work.
Output structured prose with short section headers. Do not address the user; write the
summary as notes.
```

#### Tests (Stage 3)

Use `Faux_provider.stream_fn_of_scripts` (no network). Build a `stream_fn` whose single
script is a `Turn` producing `AText "SUMMARY"` and a final `EndTurn` assistant message with
`content=[AText "SUMMARY"]`.

- `test_compact_success_shape`: with `messages` of length `tail_size + 3` and
  `tail_size = 2`, `compact` returns `Ok (Some r)` where `r.summary = "SUMMARY"`,
  `r.new_messages` has length `1 + 1 + tail_size`, the head equals the original first
  message, element 1 is `Synthetic (Compaction_summary {summary="SUMMARY"})`, and the tail
  equals the original last `tail_size` messages.
- `test_compact_renders_synthetic_as_user`: `to_provider_message (List.nth r.new_messages 1)`
  is a `UserMessage` whose text starts with `Agent_types.compaction_framing`.
- `test_compact_too_short_returns_none`: `messages` of length `tail_size + 1` → `Ok None`
  (and the `stream_fn` is **not** called — assert via a counter).
- `test_compact_stream_error_returns_error`: script an `Error` turn → `compact` returns
  `Error _`, and `new_messages` is **not** produced.
- `test_render_messages_to_text_includes_tool_results`: rendering a list containing a
  `ToolResultMessage` includes its content text.

**Acceptance:** build + tests; `Compaction` does not depend on `Agent_harness`,
`Session_writer`, or any harness state (proves the §12 seam is clean).

---

## Epoch 2 — Harness wiring (Level 3, autonomous)

### Stage 4 — `Agent_harness` compaction wiring  ⬜ pending

> Before starting, resolve Open Question 3 (model context windows). Stage 4 currently
> assumes `Pera_core.Model_window.default_trigger_tokens model` produces a sensible
> default, which is **only true** if Option 1 (`context_window` on `Types.model`) has
> been applied. If Option 1 is rejected, replace `Model_window.default_trigger_tokens`
> calls at the harness construction sites with explicit `trigger_tokens` values from
> the caller (live_driver / harness_driver / config plumbing).

**Goal:** wire autonomous compaction into the assembled harness. When `config.compaction =
Some cc`, install the `should_stop_after_turn` and `prepare_next_turn` hooks and grow the
session subscriber. When `None`, behaviour is exactly M5.

**Files to modify**

- `lib/pera_agent/agent_harness.mli` / `.ml`
- `lib/pera_agent/test/agent_harness_test.ml`
- `lib/pera_agent/dune` — ensure `pera_harness` is in `libraries` (it is) so
  `Token_estimator`, `Model_window`, `Compaction` are reachable.
- **Config construction sites** (add `compaction = None`): grep for
  `Agent_harness.config` record literals — the primary sites are in `bin/drivers/live_driver.ml`,
  `bin/drivers/harness_driver.ml`, and `lib/pera_agent/test/agent_harness_test.ml`. Line
  numbers shift as code evolves; trust the grep, not hard-coded line numbers.

#### Interface additions

```ocaml
type compaction_config = {
  trigger_tokens : int;
      (** Compact when estimate_messages (convert_to_llm context.messages) > this. *)
  tail_size : int;  (** Number of trailing messages kept verbatim (spec default 4). *)
}

type config = {
  cwd : string;
  model : Pera_types.Types.model;
  session_path : string;
  stream_fn : Pera_core.Agent_types.stream_fn;
  max_tokens : int;
  exec_env : (module Pera_env.Execution_env.S);
  compaction : compaction_config option;   (* NEW; None = no autonomous compaction *)
}
```

#### Internal wiring (`create`)

Add a shared ref before building `loop_config`:

```ocaml
let pending_compacted : Pera_core.Agent_types.agent_message list option ref = ref None in
```

Define the two hooks (only when `config.compaction = Some cc`):

```ocaml
let options = Provider.{ max_tokens = config.max_tokens; temperature = None } in

let should_stop_hook cc (ctx : _ Pera_core.Agent_loop.should_stop_ctx) =
  let provider_msgs = convert_to_llm ctx.messages in
  let est = Pera_harness.Token_estimator.estimate_messages provider_msgs in
  if est <= cc.trigger_tokens then false
  else begin
    ctx.emit Pera_core.Agent_types.AE_compaction_start;
    let outcome =
      Eio.Switch.run (fun sw ->
        Pera_harness.Compaction.compact
          ~stream_fn:config.stream_fn ~model:config.model ~options
          ~messages:ctx.messages ~tail_size:cc.tail_size ~sw)
    in
    (match outcome with
     | Ok (Some r) ->
         pending_compacted := Some r.new_messages;
         ctx.emit (Pera_core.Agent_types.AE_compaction_end { summary = r.summary })
     | Ok None -> ()   (* nothing to compact — silent no-op *)
     | Error msg ->
         ctx.emit (Pera_core.Agent_types.AE_compaction_error { message = msg }));
    false   (* never stop the run on account of compaction *)
  end
in

let prepare_hook (_ctx : _ Pera_core.Agent_loop.prepare_ctx) =
  match !pending_compacted with
  | None -> None
  | Some msgs ->
      pending_compacted := None;
      Some Pera_core.Agent_types.{ messages = Some msgs; model = None; thinking = None }
in
```

In `loop_config`, set:

```ocaml
should_stop_after_turn =
  (match config.compaction with None -> None | Some cc -> Some (should_stop_hook cc));
prepare_next_turn =
  (match config.compaction with None -> None | Some _ -> Some prepare_hook);
```

> **Ordering note:** the loop runs `should_stop` (Step 9) then `prepare_next_turn` (Step 10)
> only when `should_stop` returned `false`. Our hook always returns `false`, so
> `prepare_next_turn` always runs and installs the compacted context for the next turn. The
> compacted context becomes `messages_ref`, so it is also what `AE_agent_end` reports and
> what the wrapper's `current_messages` / next `send` build on. Correct.

> **Switch note:** `should_stop` runs in the loop fibre under the run switch. We wrap the
> summarisation in a child `Eio.Switch.run` so `compact` has a switch for the provider
> stream; cancellation of the outer switch still propagates to the child.
>
> **Buffer note:** while the loop fibre blocks inside `compact`, the actor fibre in
> `agent_wrapper.ml` can drain `out_stream` (capacity 32). At the time compaction fires,
> `out_stream` holds at most the events from the triggering turn (typically 3–8 events —
> `AE_turn_start`, streaming updates, `AE_message_end`, `AE_turn_end`). The
> `AE_compaction_start` and `AE_compaction_end` events are pushed after that and also sit in
> the buffer. Total buffered items stay well under 32, so there is no back-pressure deadlock.

#### Session subscriber growth

Add three cases (the match is exhaustive — the compiler will force this):

```ocaml
| AE_compaction_start -> Ok ()
| AE_compaction_error _ -> Ok ()   (* hook already emitted; nothing to persist *)
| AE_compaction_end { summary } ->
    (match Pera_harness.Session_writer.current_parent_id writer with
     | None -> Ok ()   (* no tip to anchor; should not happen mid-run *)
     | Some first_kept_entry_id ->
         let* () =
           Pera_harness.Session_writer.write_compaction writer ~summary
             ~first_kept_entry_id
         in
         let synth =
           Pera_core.Agent_types.synthetic_to_message
             (Pera_core.Agent_types.Compaction_summary { summary })
         in
         let* () = Pera_harness.Session_writer.write_message writer synth in
         Pera_harness.Session_writer.write_leaf writer)
```

> `first_kept_entry_id` is the pre-compaction tip (decision 7) — documented approximation.
> Add a one-line comment to that effect.

Also: on `AE_compaction_error`, print a stderr warning (spec §8: "Prints a warning line to
stderr") — do this in the existing `| Error e -> eprintf …` fall-through is not enough since
the subscriber returns `Ok ()`; add an explicit `Printf.eprintf "compaction failed: %s\n%!"
message` in the `AE_compaction_error` arm.

#### Tests (Stage 4) — `agent_harness_test.ml`

Drive with `Faux_provider`. Set `compaction = Some { trigger_tokens = <low>; tail_size = 2 }`.
Use a scripted sequence that accumulates enough messages to trip the threshold and provides
a summary turn (see Stage 6 for the exact script shape — reuse it here).

- `test_autonomous_compaction_writes_compaction_entry`: after a run that crosses the
  threshold, the session file contains exactly one `type:"compaction"` entry with a
  non-empty `summary`.
- `test_autonomous_compaction_writes_synthetic_message`: a `message` entry whose role is
  `user` and whose text begins with `compaction_framing` follows the compaction entry,
  parented to it.
- `test_autonomous_compaction_emits_events`: a subscriber observes `AE_compaction_start`
  then `AE_compaction_end`, ordered **after** the triggering `AE_turn_end` and **before** a
  later `AE_turn_end`.
- `test_autonomous_compaction_no_error_event`: no `AE_compaction_error` in the happy path;
  the run reaches `AE_agent_end`.
- `test_compaction_disabled_is_m5_behaviour`: with `compaction = None`, the session file has
  no `compaction` entry (regression guard for M5 parity).
- `test_compaction_failure_emits_error_and_continues`: script the summarisation turn as an
  `Error`; subscriber sees `AE_compaction_error`, the run still reaches `AE_agent_end`, and
  the session has **no** `compaction` entry.

**Acceptance:** build + tests; M5 `agent_harness_test` cases still pass (they now construct
`config` with `compaction = None`).

---

## Epoch 3 — Drivers

> This epoch is the milestone's evidence (SPECIFICATION.md §12: M6 = `compaction_driver` +
> `harness_driver` *with compaction*). Both drivers must be **complete and self-checking**:
> structured `[driver] scenario … PASS/FAIL: reason` output and a meaningful exit code. No
> stubbed scenarios, no "TODO" paths.

### Stage 5 — `compaction_driver` + `session_driver` compaction scenario  ⬜ pending

**Files to create**

- `bin/drivers/compaction_driver.ml`

**Files to modify**

- `bin/drivers/session_driver.ml` — add scenario 6 (compaction entry).
- `bin/drivers/dune` — add a `compaction_driver` executable stanza.

#### `compaction_driver`

Layer driver for `Compaction` (the §12 "compact called directly with synthetic message
lists" driver). Two scenarios, so it is useful **with and without** an API key:

**Scenario A — `offline_faux` (always runs).** Build a `stream_fn` via
`Faux_provider.stream_fn_of_scripts` that returns one `Turn` with
`content=[AText "OFFLINE SUMMARY"]`. Build a synthetic conversation of, say, 8
`agent_message`s (a user task, several assistant/tool-result pairs). Call
`Compaction.compact ~tail_size:3 …`. Assert:
- result is `Ok (Some r)`;
- `r.summary = "OFFLINE SUMMARY"`;
- `List.length r.new_messages = 1 + 1 + 3`;
- `to_provider_message (List.nth r.new_messages 1)` is a user message whose text starts with
  `compaction_framing`;
- the head and the last 3 messages are preserved verbatim.
Print `[compaction] offline_faux … PASS`.

**Scenario B — `real_model` (skips without `ANTHROPIC_API_KEY`).** Build a real `stream_fn`
the way `live_driver` does: a `Provider_registry.t` containing `Anthropic_provider`, then
`Provider_adapter.create ~registry ~env ~sw` and `Provider_adapter.stream_fn`. Construct a
representative long conversation (a coding task + a few file-edit turns described as text).
Call `Compaction.compact ~model:{id="claude-haiku-4-5-…"; api="anthropic"} …`. Assert
`Ok (Some r)`, `r.summary` non-empty; **print the summary** for human inspection (this driver
doubles as a prompt-tuning tool, per §12). Print `[compaction] real_model … PASS` or, when
the key is absent, `[compaction] real_model … SKIP: no ANTHROPIC_API_KEY`.

Exit `0` if every non-skipped scenario passes, else `1`.

Dune stanza:

```
(executable
 (name compaction_driver)
 (modules compaction_driver)
 (libraries pera_harness pera_core pera_core_test_util pera_provider pera_env pera_types
            eio eio_main eio_linux containers yojson unix))
```

(If `compaction_driver` shares helpers like `session_jsonl_helpers`, add it to `modules`;
otherwise keep it self-contained.)

#### `session_driver` scenario 6 — `compaction`

Append to the existing five scenarios. Drive `Session_writer` directly (no agent loop):
`write_session_info → write_message(user) → write_message(assistant) →
write_compaction ~summary:"S" ~first_kept_entry_id:<id of assistant> →
write_message(synthetic user) → write_leaf`. Verify:
- 6 lines; types `[session_info; message; message; compaction; message; leaf]`;
- the `compaction` entry has `summary:"S"` and a present `first_kept_entry_id`;
- content chain (excluding the leaf) is gap-free; the leaf is childless.

To learn the assistant entry's id for `first_kept_entry_id`, read it back from the file after
writing the assistant message, or expose it by reading `current_parent_id` **before**
`write_compaction` (it equals the assistant id at that point). Print `[session] compaction …
PASS`.

**Acceptance:** `session_driver` prints 6 PASS lines, exit 0; `compaction_driver` prints
`offline_faux PASS` and either `real_model PASS` or `real_model SKIP`, exit 0.

---

### Stage 6 — `harness_driver` autonomous-compaction scenario  ⬜ pending

**Files to modify**

- `bin/drivers/harness_driver.ml` — add scenario `autonomous_compaction`.

This is the M6 headline evidence: a full-stack `Agent_harness` run against `Faux_provider`
that crosses the compaction threshold mid-run and **continues without an error event**.

#### The script (study this carefully — call ordering is the subtle part)

`Faux_provider.stream_fn_of_scripts` plays scripts **in call order**, and the harness's
compaction hook makes an **extra** `stream_fn` call (the summarisation) *between* agent
turns. So a run that compacts once consumes scripts in this order:

1. **Turn 1** — assistant *tool call* (e.g. `bash` `echo a`), `stop_reason = ToolUse`. Make
   its assistant text content large (~1200 chars of filler in an `AText` block, plus the
   tool call) so the running estimate climbs.
2. **Turn 2** — assistant *tool call* (`bash` `echo b`), large text, `ToolUse`.
3. **Turn 3** — assistant *tool call* (`bash` `echo c`), large text, `ToolUse`. After this
   turn the accumulated context exceeds `trigger_tokens` → `should_stop` compacts.
4. **Summarisation call** — `should_stop` calls `stream_fn`; this consumes the next script:
   a plain `Turn` with `content=[AText "COMPACTED SUMMARY"]`, `EndTurn`. (This is **not** an
   agent turn; it is the compaction LLM call.)
5. **Turn 4** — assistant *text*, `EndTurn`. The inner loop continued because Turn 3 had a
   tool call; after compaction it runs this final turn and the run ends.

So `scripts = [tool1; tool2; tool3; summary; final_text]` (5 scripts). Use real tool calls
to `bash` so the harness's real `Local_env` executes them (the harness builds tools from
`exec_env`); `echo` output is deterministic. `tail_size = 2`.

**Tuning `trigger_tokens` (worked example — verify before committing):**

`Token_estimator.estimate_message` adds 4 tokens overhead per message plus `ceil(char_len/3)`
per text block. With ~1200-char filler per tool turn and a short `echo` tool result (~10
chars), a rough per-turn estimate is:

```
assistant (tool call + 1200-char AText): 4 + ceil(1200/3) + tool-call-name ≈ 4 + 400 + 4 = ~408 tokens
tool result (~10 chars):                 4 + ceil(10/3)                       ≈ 4 +   4   =   ~8 tokens
```

Running totals (user message ≈ 10 tokens, so start ≈ 10):
- After Turn 1: ≈ 10 + 408 + 8 = **426**
- After Turn 2: ≈ 426 + 408 + 8 = **842**
- After Turn 3: ≈ 842 + 408 + 8 = **1258**

Choose `trigger_tokens` in the range (842, 1258) — e.g. **1000**. After compaction,
`new_messages` = `[first_user, synthetic_summary, last_2_of_turn3]` — the summary text is
"COMPACTED SUMMARY" (17 chars ≈ 6 tokens + 4 = 10 tokens per message):
- Post-compaction estimate: ≈ 10 + 10 + 408 + 8 = **436** (well below 1000)

So with `trigger_tokens = 1000` and `tail_size = 2`, exactly one compaction fires and the
post-compaction context does not trigger a second. Verify by running and confirming exactly
one `AE_compaction_*` pair. If a second compaction fires, it would exhaust the script list
and raise `"Faux_provider: no more scripts"` — raise `trigger_tokens` if that happens.
The `Ok None` guard (decision 10) only prevents compaction when `n <= tail_size + 1 = 3`;
after first compaction `n = 4`, so the guard does **not** prevent a second attempt — only
correct `trigger_tokens` tuning does.

#### Assertions

Subscribe and collect events; parse the session file. Assert:
- the event stream contains exactly one `AE_compaction_start` and one `AE_compaction_end`,
  and **no** `AE_compaction_error`;
- `AE_compaction_start` appears **after** the third `AE_turn_end` and **before** the final
  `AE_turn_end` (ordering through the loop stream);
- the run reaches `AE_agent_end` (no terminal error);
- the session file contains exactly one `type:"compaction"` entry with a non-empty
  `summary`, immediately followed by a `message` (role `user`) whose text starts with
  `compaction_framing`, parented to the compaction entry;
- the content chain (excluding `leaf` entries) is gap-free; every `leaf` is childless;
- there are exactly two `leaf` entries for this single `send`: one written at compaction
  time and one at `AE_agent_end` (spec §3: "Compaction writes an additional Leaf").

Print `[harness] autonomous_compaction … PASS/FAIL: reason`. Keep the three existing
`harness_driver` scenarios. Exit 0 only if all pass.

**Acceptance:** `harness_driver` prints 4 PASS lines (3 existing + `autonomous_compaction`),
exit 0. The "session continues without an error event" property (SPECIFICATION.md §12) is
directly observable in the output.

---

## Epoch 4 — Verification & docs

### Stage 7 — Docs + full sweep  ⬜ pending

**Files to modify**

- `AGENTS.md` / `USAGE.md` — add `compaction_driver` to the driver list and a one-line
  "autonomous compaction (M6)" note; mention `Agent_harness.config.compaction`.
- `SPECIFICATION.md` — optional: bump the status line / note M6 is implemented. Do **not**
  rewrite §8; the implementation matches it.

**Verification (run and record):**

```
dune build
dune runtest
./_build/default/bin/drivers/session_driver.exe        # 6 PASS
./_build/default/bin/drivers/compaction_driver.exe      # offline PASS, real PASS|SKIP
./_build/default/bin/drivers/harness_driver.exe         # 4 PASS
ANTHROPIC_API_KEY=… ./_build/default/bin/drivers/compaction_driver.exe   # real_model PASS + printed summary
```

Confirm `loop_driver`, `conversation_driver`, `tool_driver`, `env_driver`, `live_driver`
still build and pass (they were touched only by the mechanical `convert_to_llm` edit in
Stage 0).

---

## Key risks

- **Refutation-site sprawl (Stage 0).** Inhabiting `synthetic` breaks every `| Synthetic _
  -> .`. Mitigation: the uniform `List.map Agent_types.to_provider_message` rewrite; compile
  and fix every reported non-exhaustive match. This is the riskiest stage; do it first and
  get the build green before proceeding.
- **`pp_agent_event` is hand-written and exhaustive.** Forgetting the three new arms is a
  compile error (good) — just remember it is separate from the derived `equal`.
- **Event ordering.** Compaction events MUST go through `ctx.emit` (the loop stream), never a
  direct subscriber call, or they will race ahead of the buffered `AE_turn_end`. The
  `harness_driver` ordering assertion is the guard.
- **Driver determinism (Stage 6).** The summarisation call consumes a script slot between
  agent turns; mis-counting scripts yields `"no more scripts"`. The fix is the script order
  in this plan and `trigger_tokens` tuned so **exactly one** compaction occurs. Keep
  `tail_size` small (2) so few turns are needed.
- **`Eio.Switch.run` inside a hook.** Confirm the summarisation's child switch composes with
  the loop's run switch (it does — structured concurrency); if a type error appears, thread
  the loop switch instead, but the child-switch form is preferred (keeps `should_stop_ctx`
  free of `sw`).

---

## What M6 does NOT include (scoped out — do not build)

- **Level 4 robustness** (retry-on-overshoot, tighter-tail retries, compaction target-model
  swap) — M7.
- **Manual `/compact` CLI command** and `Agent_harness.compact` — deferred to the CLI
  milestone; the Level-2 "compact on demand" property is validated by `compaction_driver`
  calling `Compaction.compact` directly (same code path).
- **Session restore / read side** (walking from a `Leaf` through `Compaction` entries) — v2.
  The write side is forward-compatible (decision 7).
- **Exact `first_kept_entry_id` tail-boundary tracking** — approximated by the pre-compaction
  tip (decision 7); v2 restore can tighten it.
- **A precise tokeniser** — `Token_estimator` is the conservative char-based seam; a real
  tokeniser is a later drop-in.
- **Streaming compaction**, **per-project/per-model compaction prompts** — §13 open
  questions, v2.

---

## How to generate the companion `m6-survivable-agent.json` (instructions for a new session)

> Paste this section's task into a fresh session once the markdown plan above is approved.
> The JSON is what `/orchestrate`'s `@executor` consumes stage-by-stage; the markdown is the
> human-readable source of truth. **The JSON must not invent anything — it is a faithful
> machine encoding of the stages above.**

**Task:** Produce `/.claude/plans/m6-survivable-agent.json` by translating
`.claude/plans/m6-survivable-agent.md` into the exact schema used by
`.claude/plans/m5-auditable-agent.json`. Do this:

1. **Read both files first:** `.claude/plans/m6-survivable-agent.md` (the content) and
   `.claude/plans/m5-auditable-agent.json` (the schema/shape to mirror). Match the M5 JSON's
   structure precisely — same keys, same nesting, same conventions.

2. **Top-level keys** (mirror M5): `plan_id` = `"m6-survivable-agent"`, `title`, `source`
   (cite `SPECIFICATION.md §3, §5, §8 (Level 3), §11 M6, §12`), `baseline`, `epochs`.

3. **`baseline` object** (mirror M5's): `build_passes: true`, `tests_pass: true`,
   `known_failures: []`, and a long `notes` string that enumerates the **Settled design
   decisions** (1–12) and the **breaking sites** from the markdown verbatim-in-substance.
   Before writing, **re-run `dune build` and `dune runtest`** and record the real results in
   `build_passes`/`tests_pass`.

4. **`epochs` array** — one object per epoch (0–4) with `epoch`, `title`, `status:
   "pending"`, `description`, and a `stages` array. **Map the markdown 1:1:**
   - Epoch 0 → stages 0, 1
   - Epoch 1 → stages 2, 3
   - Epoch 2 → stage 4
   - Epoch 3 → stages 5, 6
   - Epoch 4 → stage 7

5. **Each stage object** must have exactly these keys (copy M5's stage shape):
   `stage` (int), `title`, `status: "pending"`, `description`, `files_to_create` (array),
   `files_to_modify` (array), `files_to_delete` (array, usually `[]`), `depends_on` (array of
   stage numbers — use the "Depends" column of the Stage map table),
   `implementation_notes` (a single long string — fold the markdown stage's interface +
   algorithm + wiring snippets into it, preserving the code blocks as escaped text),
   `coding_guidelines_to_emphasize` (array — cite the relevant `docs/guidelines/*.md` as M5
   does: e.g. `module-boundaries.md`, `pera-specific.md` open Containers, `error-handling.md`
   Result-not-raise, `pattern-matching.md` exhaustive matches, `eio.md` switches/cancel,
   `test-patterns.md` for drivers), `test_requirements` (object with `existing_tests` array,
   `new_tests` array of named test cases copied from the markdown's "Tests" subsections,
   `test_command`, `notes`), and `acceptance_criteria` (array — copy the markdown's
   **Acceptance** line(s) per stage, expanded into checkable bullets).

6. **Fidelity rules:** Every file path, type signature, constant
   (`compaction_framing = "Context from earlier conversation:\n\n"`, `default_ratio = 0.70`,
   `anthropic_window = 200_000`, `openai_window = 128_000`, `per_message_overhead = 4`,
   `tail_size` default `4`), and the `summarise_prompt` text must match the markdown exactly.
   The `Faux_provider` script order for the `harness_driver` scenario
   (`[tool1; tool2; tool3; summary; final_text]`) and the "exactly one compaction" tuning
   note must appear in stage 6's `implementation_notes`.

7. **Validate the JSON** before finishing: `cat .claude/plans/m6-survivable-agent.json |
   python3 -m json.tool > /dev/null` (or `jq . <file> > /dev/null`). It must parse. Escape
   all newlines/quotes inside string values properly.

8. **Do not change any source code** in this task — it produces the plan file only. Report
   the stage count and confirm the file parses.

A faithful translation yields ~8 stage objects across 5 epochs, structurally identical to
`m5-auditable-agent.json`.
