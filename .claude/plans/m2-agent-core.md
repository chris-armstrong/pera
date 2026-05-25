# M2 — Loop verified (agent core)

> **Plan ID:** `m2-agent-core` · **Source:** SPECIFICATION.md §5 (the agent core), §3 (agent_message / agent_event data model), §12 (loop_driver + Faux_provider).
>
> Milestone M2: the agent loop wired to a scriptable faux provider; **no real network**. Exercises the full turn-and-hook surface, tool-execution ordering, and cancellation. The §6 Agent wrapper is explicitly **out of scope** for M2 (deferred to the harness, M5).
>
> _This is the human-readable rendering of `.claude/plans/m2-agent-core.json` (the machine-readable plan `/orchestrate` consumes). If they ever disagree, the JSON is the source of truth._

---

## Settled design decisions

These were agreed with the user before/during planning. **Do not revisit without asking.**

| # | Decision | Why |
|---|----------|-----|
| 1 | **Scope: bare loop only** — loop + hooks + tool execution + `Faux_provider` + `loop_driver`. | The §6 Agent wrapper (subscription fan-out, single-flight, observable state) is deferred to the harness (M5). Matches the §12 driver table. |
| 2 | **Tool results: add a third `ToolResultMessage` variant** to `Provider.message` (pi-faithful: `UserMessage \| AssistantMessage \| ToolResultMessage`), and teach `anthropic_request` to render it. | The loop must feed tool results back through `convert_to_llm`. Anthropic requires consecutive tool-result messages to be **coalesced** into a single user-role message with multiple `tool_result` blocks (ref `vendor/pi/.../anthropic.ts:1100-1133`). `build_request_body`'s 1:1 `List.map` becomes a grouping fold. |
| 3 | **Extract `Http_client` in M2** (Stage 1). | Resolves the noted issue from the PR #2 review on `anthropic_provider.ml:119` (piaf body/error types leaking). Wraps piaf behind `type body` / `fold_body_string` / `type error` / `error_to_string`. |
| 4 | **Loop↔provider seam = `stream_fn` closure** (`model/context/options/sw -> Event_stream.t`), **not** a `Provider.S` module. | Keeps the loop pure-from-IO and free of `~env`. `Faux_provider` satisfies `Provider.S` **and** exposes an adapter producing a `stream_fn`; the harness/driver binds `~env` into the closure. |
| 5 | **`agent_message = Real of Provider.message \| Synthetic of synthetic`** with empty `synthetic = \|` (uninhabited in v1). | Honors spec §3 ("superset… permits synthetic messages"; "not the same type") + the closed-sum discipline of §3 Events; makes M6 compaction **additive** (add a `synthetic` ctor + render per §8) rather than an alias→variant refactor. Diverges only from pi's *open* declaration-merging mechanism, which OCaml can't express. Accepted cost: wrap/unwrap boilerplate. |
| 6 | **Agent-core types live in `pera_core`, not `pera_types`.** | Forced: `agent_message` references `Provider.message` (pera_provider) → can't sit in pera_types without a dep cycle; `tool.execute` needs Eio (pera_types has no eio dep); placing them in pera_provider would invert §2 layering (core is *above* provider). Mirrors pi's `pi-ai`/`pi-agent` split. |

---

## Baseline

- **`dune build`:** passes · **`dune runtest`:** passes · **Known failures:** none.
- M1 (provider layer) is merged to `main` at `091379d`. Libraries present: `pera_types` (data model), `pera_provider` (`Provider.S`, `Event_stream`, SSE parser/interpreter, `Json_schema`, `Json_repair`, `Anthropic_provider`, `anthropic_request`, `provider_driver`). **No `pera_core` library exists yet** — it is created in this milestone.

### Reuse audit

| Module | Decision |
|--------|----------|
| `Event_stream` (pera_provider) | **Reuse as-is** — §4 says the same `('event,'result) t` carries `(agent_event, agent_message list)` inside the loop. |
| `Provider.message` / `context` / `simple_stream_options` | **Reuse**; extend `message` with `ToolResultMessage` (Stage 2). |
| `assistant_message_event`, `assistant_message`, `tool_call`, `tool_result_content`, `stop_reason`, `model`, `tool_error` (pera_types) | **Reuse** — the loop builds history and events from these. |
| `Json_schema.validate` (pera_provider) | **Reuse** for tool-argument validation before `execute` (Stage 6). |
| `Json_repair` | Not needed at this layer. |
| `agent_message`, `agent_event`, `'ctx tool`, `tool_output`, `agent_loop_config`, hooks, `run`, `Faux_provider`, `loop_driver` | **All new** (pera_core). |

**Ported from pi:** loop control flow + tests from `vendor/pi/packages/agent/src/agent-loop.ts` and `.../test/agent-loop.test.ts`; type shapes from `.../agent/src/types.ts` (`AgentEvent` 403-418, `AgentLoopConfig` 135-277). The `Agent` class (`agent.ts`) and `agent.test.ts` are §6 wrapper material — **not** ported in M2.

**Layering note:** `agent_message`/`agent_event` reference `Provider.message` (pera_provider, not pera_types) and `'ctx tool` references `Eio.Switch`/`Eio.Cancel`, so the agent-core types must live in `pera_core` (depends on pera_provider), not `pera_types`.

---

## Stage map

| Epoch | Stage | Title | Creates | Modifies | Depends on |
|:---:|:---:|------|:---:|:---:|:---:|
| 1 | 1 | Extract `Http_client` abstraction | 3 | 3 | — |
| 1 | 2 | `ToolResultMessage` variant + tool-result serialisation | 0 | 4 | — |
| 2 | 3 | `pera_core` scaffold + agent data model types | 5 | 1 | 2 |
| 2 | 4 | `Faux_provider` test double | 3 | 1 | 3 |
| 2 | 5 | Agent loop control flow (turns, streaming, hooks) | 3 | 1 | 4 |
| 2 | 6 | Tool execution (sequential + parallel, ordering, validation, hooks) | 1 | 2 | 5 |
| 2 | 7 | Cancellation propagation | 1 | 2 | 6 |
| 2 | 8 | `loop_driver` — M2 acceptance proof | 1 | 1 | 7 |

---

# Epoch 1 — Provider-layer prerequisites for the loop

Two `pera_provider` changes the loop depends on, both flagged as noted issues. Stage 1 (independent of the loop) extracts the `Http_client` abstraction; Stage 2 adds the `ToolResultMessage` variant so the loop can feed tool results back. Both compile and keep existing provider tests green.

## Stage 1 — Extract `Http_client` abstraction in pera_provider

Introduce a thin `Http_client` module that wraps piaf, so the Anthropic provider no longer references `Piaf.Body` / `Piaf.Error` directly. **Behaviour-preserving.**

- **Create:** `lib/pera_provider/http_client.mli`, `http_client.ml`, `test/http_client_test.ml`
- **Modify:** `lib/pera_provider/anthropic_provider.ml`, `lib/pera_provider/dune`, `lib/pera_provider/test/dune`
- **Depends on:** —

**Implementation notes.** Read `anthropic_provider.ml` first to see which piaf surfaces it uses (`Piaf.Body.*`, `Piaf.Error.*`, the request/post call, the streaming body fold). Define `Http_client.mli` to expose only what the provider needs, hiding piaf. Suggested surface:

- `type error`
- `val error_to_string : error -> string`
- a `post_stream` / `stream_response` taking `~env ~sw`, url, headers, body string, and `~on_chunk:(string -> unit)`, returning `(unit, error) result`; it folds the response body string-by-string into `on_chunk` (this is where the current `Piaf.Body.fold_string` / `Piaf.Error.to_string` usage moves).

Keep the signature minimal — no Piaf types in the `.mli`. Move piaf-specific code into `http_client.ml` and rewrite the provider to call `Http_client`. Do **not** change external behaviour, the SSE pipeline, or `Provider.S`. `open Containers`; IO returns `Result`, never raises (pera-specific §6). This is the abstraction the OpenAI-completions provider shares at M3.

**Guidelines to emphasize:** module-boundaries (.mli hides piaf), abstractions (one narrow seam), error-handling (`error_to_string` total, never raise on network), pera-specific §5 (`~sw`).

**Tests.**
- _Existing:_ all M1 provider tests must stay green (this is a behaviour-preserving refactor).
- _New —_ `test_error_to_string_is_total_and_nonempty`: drive `post_stream` against an invalid URL (e.g. `http://127.0.0.1:1/`) under `Eio_main.run` and assert the result is `Error` with a non-empty `error_to_string` (or, if `error` has public constructors, exercise each). Asserts `error_to_string` never raises and is non-empty for a real transport failure.
- _Command:_ `dune runtest lib/pera_provider`
- _Note:_ primarily a refactor; its safety net is the existing M1 suite + `dune build` of `provider_driver`. The live-network success path is the same acknowledged exception M1 stage 8 carries (manual via `provider_driver`, not CI).

**Acceptance:** build succeeds incl. `provider_driver`; `anthropic_provider.ml` has **no** `Piaf.*` references; `http_client.mli` exposes no piaf types; existing provider tests pass; `provider_driver` still streams (manual, with key).

## Stage 2 — `ToolResultMessage` variant + Anthropic tool-result serialisation

Add the third message variant so tool results can live in history and be sent back; extend the request builder to render them, **coalescing** consecutive ones into a single user message.

- **Create:** —
- **Modify:** `lib/pera_provider/provider.mli`, `anthropic_request.ml`, `anthropic_request.mli`, `test/anthropic_request_test.ml`
- **Depends on:** —

**Implementation notes.** In `provider.mli`, extend the variant to:

```ocaml
type message =
  | UserMessage of Types.user_message
  | AssistantMessage of Types.assistant_message
  | ToolResultMessage of Types.tool_result_content
```

(`Types.tool_result_content` already exists: `{ tool_call_id; content : Yojson.Safe.t; is_error : bool }`.) This makes every existing match on `Provider.message` non-exhaustive — fix them (notably `anthropic_request.message_to_json`) so the build stays green.

In `anthropic_request.ml`, a single `ToolResultMessage` renders to an Anthropic user message whose content is one `tool_result` block: `{ type: "tool_result", tool_use_id, content, is_error }`. **Critical:** consecutive `ToolResultMessage`s must coalesce into **one** user message carrying all their `tool_result` blocks (Anthropic rejects tool_result blocks split across separate user messages when they answer one assistant turn's parallel calls). The current `List.map message_to_json context.messages` can't coalesce — replace with a grouping fold (on a run of `ToolResultMessage`s, emit one user message with the collected blocks). Ref `vendor/pi/packages/ai/src/providers/anthropic.ts:1100-1133` for the exact algorithm. Update `anthropic_request.mli` only if a new public function is introduced (e.g. exposing `messages_to_json : Provider.message list -> Yojson.Safe.t list` — preferred if it aids testing). `open Containers`; match the variant (no `=`).

**Guidelines to emphasize:** pattern-matching (exhaustive 3-way match, no catch-all), type-safety (typed `tool_result_content`), naming (name the grouping step), pera-specific.

**Tests** (`test/anthropic_request_test.ml`, command `dune runtest lib/pera_provider`):
- `test_single_tool_result_renders_as_user_message` — a `ToolResultMessage` → user-role message with one `tool_result` block (tool_use_id, content, is_error).
- `test_consecutive_tool_results_coalesce_into_one_user_message` — two consecutive → **one** user message with two blocks, in source order.
- `test_tool_result_is_error_flag_propagates` — `is_error=true` renders `is_error: true`.
- `test_tool_results_between_other_messages_do_not_over_merge` — a tool-result run bounded by assistant/user messages coalesces only the contiguous results, preserving order.
- _Existing:_ user/assistant/tools/thinking cases still pass.

**Acceptance:** build succeeds; `Provider.message` has three variants with exhaustive matches; single result → user message with a block; consecutive results coalesce preserving order; `is_error` propagates; existing tests pass.

---

# Epoch 2 — Agent core loop (pera_core)

Build `pera_core`: agent data model → `Faux_provider` → loop control flow → tool execution → cancellation → `loop_driver`. At the end, the loop runs deterministically against scripted scenarios with **no network or filesystem**, proving the M2 property: turn semantics, hook contract, tool-execution ordering, and cancellation are correct independent of any provider.

## Stage 3 — `pera_core` scaffold + agent data model types

Create the library/opam package and define the agent-core data model. Pure types plus the type-level shape; no loop logic yet.

- **Create:** `lib/pera_core/dune`, `agent_types.mli`, `agent_types.ml`, `test/dune`, `test/agent_types_test.ml`
- **Modify:** `dune-project`
- **Depends on:** 2

**Implementation notes.**

`dune-project`: add a `(package (name pera-core) …)` stanza — depends `ocaml (>= 5.4)`, `pera-types (= :version)`, `pera-provider (= :version)`, `containers (>= 3.0)`, `yojson (>= 2.0)`, `eio`/`eio_main`/`eio_linux (>= 1.0)`, with-test `qcheck-core`/`qcheck-alcotest` + `alcotest`. `generate_opam_files` is on — don't hand-write `pera-core.opam`. `lib/pera_core/dune`: `(library (name pera_core) (public_name pera-core) (libraries pera_types pera_provider containers yojson eio eio_main eio_linux))`.

Define in `agent_types.mli`:

```ocaml
(* (1) agent_message — §3 superset. SETTLED encoding (see decision 5). *)
type synthetic = |   (* no synthetic kinds in v1; compaction summaries / model-change markers added at M6 *)
type agent_message = Real of Provider.message | Synthetic of synthetic
(* convert_to_llm: `Real m -> [m] | Synthetic _ -> .` (refutation). Do NOT
   substitute a plain alias or an independent mirror. *)

(* (2) tool output *)
type tool_output = Tool_text of string | Tool_json of Yojson.Safe.t

(* (3) 'ctx tool (§3) *)
type 'ctx tool = {
  name : string;
  description : string;
  schema : Json_schema.t;
  mode : [ `Sequential | `Parallel ];   (* per-tool default; read/grep Parallel, write/bash Sequential *)
  execute :
    ctx:'ctx -> args:Yojson.Safe.t ->
    sw:Eio.Switch.t -> cancel:Eio.Cancel.t ->
    (tool_output, Types.tool_error) result;
}

(* (4) agent_event — port of types.ts AgentEvent 403-418 *)
type agent_event =
  | AE_agent_start
  | AE_agent_end of { messages : agent_message list }
  | AE_turn_start
  | AE_turn_end of { message : agent_message; tool_results : Types.tool_result_content list }
  | AE_message_start of { message : agent_message }
  | AE_message_update of { message : agent_message; event : Types.assistant_message_event }
  | AE_message_end of { message : agent_message }
  | AE_tool_execution_start of { tool_call_id : string; tool_name : string; args : Yojson.Safe.t }
  | AE_tool_execution_update of { tool_call_id : string; tool_name : string; partial : Yojson.Safe.t }
  | AE_tool_execution_end of { tool_call_id : string; tool_name : string; result : Yojson.Safe.t; is_error : bool }

(* (5) hook result *)
type before_tool_call_result = Allow | Deny of string

(* (6) prepare_next_turn return — port of AgentLoopTurnUpdate; None = unchanged *)
type turn_update = { messages : agent_message list option; model : Types.model option; thinking : bool option }
```

Provide a helper converting `tool_output` → `Types.tool_result_content` given a `tool_call_id` and `is_error` (`Tool_text s` → `` content = `String s ``; `Tool_json j` → `content = j`). Keep types in the `.mli`; `.ml` just realises them. `open Containers`. Expose an `equal`/`pp` for `agent_event` (Alcotest testable) for later stages.

**Guidelines to emphasize:** module-boundaries (.mli first), type-safety (closed variants, no stringly event kinds), pattern-matching (empty `synthetic` enables refutation), pera-specific.

**Tests** (`test/agent_types_test.ml`, command `dune runtest lib/pera_core`):
- `test_tool_output_text_converts_to_tool_result_content` — `Tool_text "ok"` → `` { tool_call_id; content = `String "ok"; is_error = false } ``.
- `test_tool_output_json_converts_preserving_value` — `Tool_json (`Assoc …)` preserves the value.
- `test_agent_event_testable_distinguishes_variants` — `equal AE_turn_start AE_agent_start = false`; `equal AE_turn_start AE_turn_start = true`.

**Acceptance:** build succeeds and `pera-core.opam` generated; all six type groups defined; `agent_event` has all 10 variants; an Alcotest testable available; tests pass.

## Stage 4 — `Faux_provider` test double

The load-bearing driver/test infra (§12): emits a programmed `assistant_message_event` sequence then resolves to a scripted final `assistant_message`, no network. Satisfies `Provider.S` **and** exposes a `stream_fn` adapter; records the contexts it was called with.

- **Create:** `lib/pera_core/faux_provider.mli`, `faux_provider.ml`, `test/faux_provider_test.ml`
- **Modify:** `lib/pera_core/dune`
- **Depends on:** 3

**Implementation notes.** Public surface:

- `type turn_script = { events : Types.assistant_message_event list; final : Types.assistant_message }`
- `val stream_fn_of_scripts : turn_script list -> stream_fn` where `stream_fn` is the loop's seam type: `model:Types.model -> context:Provider.context -> options:Provider.simple_stream_options -> sw:Eio.Switch.t -> (Types.assistant_message_event, Types.assistant_message) Event_stream.t`. Each successive loop call (turn) consumes the next `turn_script` — this lets one scenario script a multi-turn conversation (turn 1 issues tool calls, turn 2 ends). Advance through scripts via a ref/queue captured in the closure.
- The `stream_fn` forks a producer fibre under `~sw` that pushes the script's events into an `Event_stream` (capacity 32), then `close final` (or `close_error` for an error script). Mirror `anthropic_provider.ml`'s fork/close pattern.
- **Recording:** capture each received `Provider.context` into a list accessible to tests (assert what `convert_to_llm` produced and that steering/follow-up messages were injected).
- `val as_provider : turn_script list -> (module Provider.S)` (its `stream_simple` takes `~env` and ignores it) — demonstrates the §12 `Provider.S` adapter relationship. The loop itself only uses `stream_fn`; `as_provider` proves `Faux_provider` **is** a `Provider.S`.
- For cancellation tests (Stage 7), support a script whose producer **blocks** before `AME_done` — a `~pause:(unit -> unit)` callback invoked between events is sufficient for the test to cancel mid-stream.

`open Containers`; fibres under `~sw`. Define the `stream_fn` type alias in one place (`agent_types` is a reasonable home).

**Guidelines to emphasize:** test-patterns §4 (named scripted scenarios), pera-specific §5 (producer fibre under switch, bounded stream), module-boundaries (.mli hides internals), abstractions (one clear constructor).

**Tests** (`test/faux_provider_test.ml`, command `dune runtest lib/pera_core`):
- `test_script_emits_events_then_resolves_final` — events match the script; `result = Ok final`.
- `test_multi_turn_scripts_advance_per_call` — call 1 yields script[0]'s final; call 2 yields script[1]'s.
- `test_recorded_context_is_observable` — the recording accessor returns a context whose messages match what was passed.
- `test_error_script_closes_stream_with_error` — `result = Error _`.

**Acceptance:** build succeeds; `stream_fn_of_scripts` matches the seam type; multi-turn scripts advance per call; `as_provider` satisfies `Provider.S`; contexts recorded; tests pass.

## Stage 5 — Agent loop control flow (turns, streaming, between-turn hooks)

Implement control flow **without tool execution yet**: outer/inner loops, streaming an assistant response (partial→final), turn lifecycle events, and the between-turn / per-call hooks. Scenarios here are text-only and terminate on `EndTurn`; the tool path lands in Stage 6.

- **Create:** `lib/pera_core/agent_loop.mli`, `agent_loop.ml`, `test/agent_loop_test.ml`
- **Modify:** `lib/pera_core/dune`
- **Depends on:** 4

**Implementation notes.** Port `agent-loop.ts` (outer loop 169-266, inner loop 174-254) and config from `types.ts` (`AgentLoopConfig` 135-277).

```ocaml
type 'ctx agent_loop_config = {
  model : Types.model;
  system : string;
  options : Provider.simple_stream_options;
  stream_fn : (* the seam type from Stage 4 *);
  convert_to_llm : agent_message list -> Provider.message list;
  tool_ctx : 'ctx;
  tools : 'ctx Agent_types.tool list;
  tool_execution : [ `Sequential | `Parallel ];   (* default `Parallel *)
  transform_context : (agent_message list -> agent_message list) option;
  get_api_key : (provider:string -> string option) option;
  before_tool_call : (before_tool_call_ctx -> Agent_types.before_tool_call_result) option;  (* wired in Stage 6 *)
  after_tool_call : (after_tool_call_ctx -> unit) option;                                    (* wired in Stage 6 *)
  should_stop_after_turn : (should_stop_ctx -> bool) option;
  prepare_next_turn : (prepare_ctx -> Agent_types.turn_update option) option;
  get_steering_messages : (unit -> agent_message list) option;
  get_follow_up_messages : (unit -> agent_message list) option;
}

val run :
  'ctx agent_loop_config -> messages:agent_message list -> sw:Eio.Switch.t ->
  (agent_event, agent_message list) Event_stream.t
```

Declare the `before_/after_tool_call` hook field **types** now (even though execution lands in Stage 6) so the config type is stable across stages. `should_stop_ctx`/`prepare_ctx` carry at least the latest assistant message, the turn's tool_results, and the current message list (mirror pi's `ShouldStopAfterTurnContext`/`PrepareNextTurnContext`).

`run` forks a fibre under `~sw` driving the loop and pushing `agent_event`s into the returned `Event_stream`; the stream resolves (`close`) with the final `agent_message list` on `agent_end` (same fork-and-return shape as `Anthropic_provider.stream_simple` / `Faux_provider`).

**Control flow (§5):**
- Emit `AE_agent_start` once.
- **Outer loop:** run the inner loop; on exit, call `get_follow_up_messages`; if it returns messages they become the next pending messages and the inner loop restarts; else emit `AE_agent_end {messages}` and close.
- **Inner loop** (while there are tool calls to chase OR pending steering/initial messages):
  1. If pending messages (initial prompt, steering, or follow-up), append them as `Real (Provider.UserMessage …)`.
  2. Emit `AE_turn_start`. Build the provider context: apply `transform_context` (if set), run `convert_to_llm`, set `context = { system; messages; tools = schemas-from-config-tools; thinking }`. Resolve `get_api_key` (if set) — unused with Faux but **must be called** (the contract). Call `stream_fn`.
  3. Consume the provider `Event_stream`: append a placeholder partial assistant message as the last entry; for each `AME_*`, replace it with the event's `partial` snapshot and emit `AE_message_update {message; event}`. Emit `AE_message_start` at the first event, `AE_message_end` at the terminal event. On `AME_done`, swap in the final message; on `AME_error`, treat as a terminal assistant message with `stop_reason` Error/Aborted.
  4. If `stop_reason` is `Error`/`Aborted`: emit `AE_turn_end {message; tool_results=[]}` and terminate the whole run (`AE_agent_end`, close).
  5. _(Stage 6 inserts tool execution here.)_ This stage: text-only / `EndTurn` → `tool_results = []`. Emit `AE_turn_end {message; tool_results}`.
  6. Call `should_stop_after_turn` (if set); if true, exit inner loop (the outer loop checks follow-ups; `should_stop` true terminates unless follow-ups exist).
  7. Call `prepare_next_turn` (if set); apply any `turn_update` (swap messages/model/thinking).
  8. Call `get_steering_messages` (if set); captured messages become pending for the next iteration.
  9. Continue only if there are pending steering messages or tool calls; text-only `EndTurn` with no steering exits.

**Keep the loop pure-from-IO:** no piaf, files, or clock — everything external is a config callback. **Hooks may not raise** (raising propagates out of `run` — programmer error, §5). Use `let*`/`Result` combinators over `match` on option/result (pera-specific §3). Mutation confined to the one context value for the run's duration.

**Guidelines to emphasize:** nesting-and-control-flow (extract `stream_one_turn`/`run_inner` to keep nesting shallow), module-boundaries, pera-specific §5, pattern-matching (exhaustive on `stop_reason`, no sentinel fallbacks), naming.

**Tests** (`test/agent_loop_test.ml`, command `dune runtest lib/pera_core`) — text-only Faux scripts:
- `test_single_text_turn_emits_lifecycle_and_final_messages` — verify the event order (`agent_start, turn_start, message_start, message_update*, message_end, turn_end, agent_end`) and final `[user; assistant]`.
- `test_transform_context_applied_before_convert_to_llm` (port pi 186-237) — assert via the recorded context that the provider saw the transformed list.
- `test_get_api_key_called_before_each_llm_call` — counter equals number of turns.
- `test_should_stop_after_turn_true_terminates_run` (port pi ~970-1050) — exactly one `turn_end` before `agent_end`.
- `test_prepare_next_turn_swaps_model` (port pi 1052-1182) — second recorded call used the swapped model id.
- `test_steering_message_injected_on_next_iteration` (port pi 581-626) — steering message present in the next recorded context.
- `test_follow_up_message_restarts_inner_loop` (port pi ~1000-1047) — two `turn_start`s, `agent_end` after the second.
- `test_error_stop_reason_terminates_run` — no second `turn_start`; `agent_end`; final assistant `stop_reason = Error`.

**Acceptance:** build succeeds; `run` returns an `(agent_event, agent_message list) Event_stream` and forks under `~sw`; text-turn lifecycle order correct; each hook behaves per its ported pi test; Error/Aborted terminates; loop references no piaf/file/clock APIs; tests pass.

## Stage 6 — Tool execution (sequential + parallel, ordering, validation, hooks)

Wire tool execution into the inner loop. Schema validation before `execute`, `before_tool_call` (Allow/Deny) and `after_tool_call` hooks, sequential and parallel modes with the **source-order result rule**, and tool-error→tool-result conversion. The heart of the "tool execution ordering is correct" property.

- **Create:** `lib/pera_core/test/agent_loop_tools_test.ml`
- **Modify:** `lib/pera_core/agent_loop.ml`, `agent_loop.mli`
- **Depends on:** 5

**Implementation notes.** Port `agent-loop.ts` `executeToolCalls` (373-388), `…Sequential` (395-449), `…Parallel` (451-516), `prepareToolCall` (562-626), `executePreparedToolCall` (628-663). When the final assistant message contains `AToolCall` blocks (`stop_reason ToolUse`), execute them.

**Mode selection (pi 373-388):** default = `config.tool_execution`; if **any** called tool has `mode = `Sequential`, force the whole batch sequential.

**Per tool (prepare then execute):**
1. Look up by name; unknown tool → error `tool_result` (`is_error=true`, `is_user_error=true`), skip execute.
2. Validate args against `Json_schema` (pera_provider). On `Error` → error `tool_result` (user error); **do not** call execute (§9, §5).
3. Call `before_tool_call` (if set). `Deny msg` → error `tool_result` carrying `msg`, skip execute (§5). `Allow` → proceed.
4. Emit `AE_tool_execution_start {tool_call_id; tool_name; args}`.
5. Call `execute ~ctx:config.tool_ctx ~args ~sw ~cancel`. **Catch any exception** → error `tool_result` (`is_error=true`, `is_user_error=false`) so the LLM can react (§5).
6. Convert `(tool_output, tool_error) result` → `Types.tool_result_content` via the Stage 3 helper.
7. Call `after_tool_call` (if set) — side-effect only.
8. Emit `AE_tool_execution_end {tool_call_id; tool_name; result; is_error}`.

**Sequential (pi 395-449):** prepare+execute+finalise each call in source order; emit `tool_execution_end` immediately after each; results appended in call order.

**Parallel (pi 451-516):** run each allowed call in its own fibre under a **sub-switch**. Emit `tool_execution_start/end` in **real completion order**. **But** the `tool_result_content list` appended to history **must be sorted by original tool-call index, not completion order** (§5 — the load-bearing rule). Collect results into a structure indexed by source position, then read out in source order.

After execution: append the ordered `tool_result_content` list as `Real (Provider.ToolResultMessage …)` entries in source order (Stage 2's coalescing handles wire merging). Emit `AE_turn_end {message; tool_results}`. The inner loop then continues (there were tool calls) and streams the next assistant turn with the results in context.

Define `before_tool_call_ctx` (assistant message, tool_call id/name/arguments, validated args → `before_tool_call_result`) and `after_tool_call_ctx` (result, is_error) in `agent_loop.mli` or `agent_types`. To make parallel-vs-sequential **observable** (pi's `parallelObserved` flag, test 452-545), provide test tools that block on a shared signal to force interleaving. `open Containers`; fibres under switches.

**Guidelines to emphasize:** pera-specific §5 (sub-switch for parallel fibres, `Eio.Cancel`), nesting-and-control-flow (extract `prepare_tool_call`/`execute_one`/`collect_ordered`), error-handling (exceptions caught→error results, never escape except true programmer errors), pattern-matching (Allow/Deny, tool_output exhaustive), type-safety (results indexed by source order via a typed structure).

**Tests** (`test/agent_loop_tools_test.ml`, command `dune runtest lib/pera_core`):
- `test_single_tool_call_executes_and_feeds_result_back` — start/end fire; result appended; turn 2's recorded context contains it.
- `test_parallel_tool_results_appended_in_source_order` (port pi 452-545) — second call completes first (blocking signals); `tool_execution_end` order = `[call2; call1]`, appended results = `[call1; call2]`.
- `test_sequential_mode_runs_in_source_order` (port pi 547-651) — both execution and result order in source order, no interleaving.
- `test_per_tool_sequential_forces_batch_sequential` (port pi 653+) — Parallel default but one tool `mode=Sequential` → no concurrent overlap.
- `test_schema_validation_failure_becomes_error_result_without_execute` (port pi 310-370) — execute call count = 0; `is_error = true`.
- `test_before_tool_call_deny_short_circuits_with_error_result` (port pi 372-449) — `Deny "nope"`; execute skipped; result mentions "nope".
- `test_tool_raising_is_caught_as_error_result` — exception caught → `is_error` result; run reaches `agent_end` without raising out of `run`.
- `test_after_tool_call_hook_invoked_per_result` (port pi 1184-1270) — count = number of executed tools.
- _Existing:_ Stage 5 text-turn tests still pass.

**Acceptance:** build succeeds; parallel = completion-order events + source-order results; sequential + per-tool override = no interleaving; validation failure and Deny skip execute and produce error results; tool exceptions surfaced as error results without crashing; `after_tool_call` once per executed tool; Stage 5 tests pass.

## Stage 7 — Cancellation propagation

Implement and verify cancellation per §5: during an LLM stream, during tool execution, and between turns. Cancellation is observed at the **next async point**; there is no mid-event cancellation.

- **Create:** `lib/pera_core/test/agent_loop_cancel_test.ml`
- **Modify:** `lib/pera_core/agent_loop.ml`, `agent_loop.mli`
- **Depends on:** 6

**Implementation notes.** `run` already executes under `~sw`. Decide and document the entry point: either `run` takes an extra `?cancel:Eio.Cancel.t` (**preferred** — explicit, matches §5 "The run takes an `Eio.Cancel.t`") or cancellation is via cancelling `~sw`. If adding `?cancel`, wrap the loop body in `Eio.Cancel.sub` or check at the documented boundaries.

Behaviours:
- **During an LLM stream:** cancelling aborts the provider stream. With Faux, simulate by cancelling while the producer is paused mid-script (Stage 4 `~pause`). The loop observes it (provider closes with error / `AME_error` Aborted), emits `AE_turn_end` with empty tool_results, then `AE_agent_end`, then returns. Final assistant `stop_reason = Aborted`.
- **During tool execution:** the parallel sub-switch is cancelled; running fibres receive cancellation at their next async point. Results completed **before** cancellation are still appended in source order, then the run terminates as above (§5).
- **Between turns:** observed at the next hook-call boundary; the loop stops before starting a new turn.

The model is "eventually observed at the next async point" — tests must drive an async point (a fibre yield / a blocked tool) then cancel. Synchronise cancel with loop progress via `Eio.Condition`/`Promise` — **no busy-wait, no sleeps** (foreground sleeps are unavailable). Update `agent_loop.mli` if `run` gains `?cancel`. `open Containers`; `Eio.Cancel`, not custom flags.

**Guidelines to emphasize:** pera-specific §5 (`Eio.Cancel`, structured concurrency), error-handling (Aborted is a typed `stop_reason`, not an exception out of `run`), test-patterns (synchronise via `Eio.Condition`/`Promise`), nesting-and-control-flow (cancellation checks at documented boundaries).

**Tests** (`test/agent_loop_cancel_test.ml`, command `dune runtest lib/pera_core`):
- `test_cancellation_during_stream_emits_aborted_and_ends` — cancel while paused mid-stream → `turn_end` (empty) + `agent_end`; assistant `stop_reason = Aborted`.
- `test_cancellation_during_parallel_tools_appends_completed_in_source_order` — one completes, one blocked; cancel → completed result appended source-ordered; run reaches `agent_end`; no crash.
- `test_cancellation_between_turns_stops_before_next_turn` — cancel after a `turn_end` but before the next stream begins → no new `turn_start` after the cancel.
- _Existing:_ Stage 5 + 6 tests still pass.

**Acceptance:** build succeeds; cancel during stream → Aborted + `turn_end` (empty) + `agent_end`; cancel during parallel tools → completed results source-ordered then terminate; cancel between turns → stops before next turn; no path raises out of `run`; tests pass.

## Stage 8 — `loop_driver` — M2 acceptance proof

Build the `loop_driver` binary (§12): drives the loop with `Faux_provider` through named scenarios, printing the `agent_event` sequence and final messages with meaningful exit codes. The artifact that **observably** demonstrates the M2 property, no network/filesystem.

- **Create:** `bin/drivers/loop_driver.ml`
- **Modify:** `bin/drivers/dune`
- **Depends on:** 7

**Implementation notes.** Mirror `provider_driver.ml`'s shape and the test-patterns §7 driver pattern. Select a scenario by argv (default: run all). Each scenario constructs a `Faux_provider` script + an `agent_loop_config` (with simple in-driver tools — e.g. an echo tool and a counter tool, `ctx` = a small record or `unit`), calls `Agent_loop.run` under `Eio_main.run` + `Eio.Switch.run`, consumes the `(agent_event, agent_message list) Event_stream` via `Event_stream.iter` printing each event as a structured line (use a `to_string`/`pp` for `agent_event`), and on result prints the final messages.

Scenarios (each maps to a documented §12 `Faux_provider` outcome): single text turn; parallel tool calls (show completion-order events vs source-order results); sequential tool calls; tool returning an error; mid-stream cancellation; steering-message injection; follow-up-message handling. Exit `0` if all selected scenarios produced their expected event shapes; `1` otherwise (light assertions + report mismatches). Add to `bin/drivers/dune` (`(libraries pera_core pera_provider pera_types eio_main containers)`). The driver is **manual** — **not** added to any `dune runtest` alias (same policy as `provider_driver`). `open Containers`.

**Guidelines to emphasize:** test-patterns §7 (exercise the public interface, structured output, meaningful exit code), naming (name each scenario + expected outcome), pera-specific §5 (`Eio_main.run` + `Switch.run`), module-boundaries (uses only pera_core's public API — a hard-to-write driver signals a leaky seam).

**Tests:** none automated for the driver — like `provider_driver` (M1 stage 8), it's a manual acceptance artifact excluded from `dune runtest`; its scenarios are already covered by Stage 5-7 unit tests. _Command:_ `dune build`. _Optional follow-up:_ a thin test running `loop_driver` and asserting exit 0 + expected stdout (drivers "can be wrapped by automated tests" per §12).

**Acceptance:** build succeeds incl. `loop_driver`; binary at `_build/default/bin/drivers/loop_driver.exe`; running it prints the event sequence + final messages per scenario and exits 0 on match; uses only pera_core's public interface; `dune runtest` still passes (driver excluded). **M2 property observable:** the parallel-tools scenario shows `tool_execution_end` in completion order and `tool_results` in source order; the cancellation scenario shows a clean Aborted termination.

---

## How to run

```
/orchestrate .claude/plans/m2-agent-core.json
```

`/orchestrate` plans→executes→reviews→commits each stage in dependency order, running the three reviewers in parallel and committing only when all pass.
