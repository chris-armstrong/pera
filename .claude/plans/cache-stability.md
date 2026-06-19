# Cache-stability interface for Pera (Anthropic prompt caching)

> Stacks on PR #14 (`feat(pera_provider): surface cached_tokens from OpenAI usage`),
> which wires the OpenAI-shape `cache_read_tokens` field through the response
> interpreter. This plan covers the larger half of the work: the Anthropic
> request side (which currently emits zero `cache_control` markers and therefore
> never caches anything) and the interface guardrails that make stable toolsets
> the default.

## Why this plan exists

### Anthropic prompt caching is byte-level prefix matching

Anthropic's cache hashes the request prefix and looks for an identical hash on
subsequent requests. Anything that perturbs the serialized bytes — JSON key
order, whitespace, a timestamp in a tool description, a tool conditionally
appended this turn but not last turn — silently invalidates the cache and
re-writes at 1.25× the base input rate. There is no error; you just see
`cache_read_input_tokens = 0` in the usage block and pay full price.

### Pi-harness assumes the caller produces stable JSON

Pi-harness (the TypeScript reference Pera ports from) places three breakpoints
(system, last tool, last user message) and hopes the user's code produces
stable bytes. There's no enforcement: the registry uses insertion order, but
nothing stops a user from injecting `Date.now()` into a tool description or
re-shuffling schema properties between turns. Pi gets away with this because
its real users (Claude Code) are careful. A prototype-stage OCaml port has a
chance to make stability the default and instability the loud thing.

### What Pera does today

- `lib/pera_provider/anthropic_request.ml` emits zero `cache_control`. No
  Anthropic conversation is cached.
- `lib/pera_provider/anthropic_interpreter.ml:134-148` already reads
  `cache_read_input_tokens` and `cache_creation_input_tokens` from responses.
  The data sink exists; nothing fills it.
- `lib/pera_core/agent_types.ml:42` defines `'ctx tool` as a public record.
  Users can construct it directly with any `Json_schema.t` they want; nothing
  canonicalizes the serialized form.
- `lib/pera_provider/json_schema.ml` (`to_json`) emits `Assoc` fields in
  declaration order. Stable per-construction but not stable across two
  independently constructed schemas with the same fields in different orders.

PR #14 fixed the symmetric gap on the OpenAI path (`cached_tokens` now flows
through). This plan does the bigger Anthropic side and the interface work.

## Settled design decisions

These were resolved in conversation on 2026-06-19. Do not revisit.

1. **Canonical JSON serialization sorts every `Assoc` alphabetically,
   recursively.** Including top-level tool wrapping (`description`,
   `input_schema`, `name` in that order). Mechanically verifiable, no schema
   knowledge required.

2. **Dynamic-content linter is warn-only.** No `~strict_cache:true` fail-fast
   variant. Heuristic regex check at `Tool.create` and at the system-prompt
   builder boundary; emits `Logs.warn`. Off by `~quiet:true`.

3. **`cache_policy` has exactly three variants. No `Custom` escape hatch.**
   `None`, `Conversation` (pi's default: system + last tool + last user
   message), `SystemAndToolsOnly` (no message-history breakpoint, for
   one-shot batch agents). Add a fourth variant if and when a real use case
   demands it.

4. **TTL is an orthogonal `?ttl` parameter** at session/request construction,
   not folded into policy variants. Default `Five_minutes`. `One_hour`
   available for long-running agents. Same TTL applies to every breakpoint in
   the request.

5. **Migrate all existing tools** to the opaque `Tool.t` constructor in PR 2.
   No transitional period, no deprecated record-access path.

## What this plan does *not* cover

- **Min-prefix-token gating.** Worth doing (skip the marker if estimated
  prefix < model's threshold), but a runtime build-time check that doesn't
  shape the interface. Defer to a follow-up.
- **JSON Schema validation beyond canonicalization.** We're not building a
  schema validator. The existing `Json_schema.validate` is unchanged.
- **20-block lookback mitigation** (4th breakpoint on long tool chains).
  Real concern for tool-heavy loops; defer until a workload hits it.
- **`usage.cache_creation` 5m/1h breakdown** (`ephemeral_5m_input_tokens`
  / `ephemeral_1h_input_tokens`). Anthropic exposes this; pi reads only the
  rolled-up `cache_creation_input_tokens`. Same for Pera. Add later if
  pricing observability matters.
- **Cross-session cache key persistence.** Anthropic caches per-organization
  automatically.

## PR sequence

| PR | Scope | Estimated LoC | Behaviour change |
|---|---|---|---|
| 1 | `cache_policy` + `cache_ttl` types in `pera_types`, threaded through request options. No request body change. | ~60 | None — type plumbing only |
| 2 | Opaque `Tool.t`, alphabetical canonical `Json_schema.to_json`, migrate 4 tools + tests | ~150–200 | Tool wire-JSON byte order changes; semantically identical to providers |
| 3 | `anthropic_request.ml` emits `cache_control` per policy with `?ttl` | ~120 | **Anthropic conversations actually cache** |
| 4 | `Tool.create` dynamic-content warn linter + system-prompt equivalent | ~50 | Logs warnings only |
| 5 | Session-level fingerprint + "prefix changed" warning | ~70 | Logs warnings only |
| 6 | Surface `cache_read_tokens` / `cache_write_tokens` in status output | TBD | Display only |

PRs 1–3 are the meaningful slice. After PR 3, Anthropic caching works at
parity with pi-harness, and PR 2's canonicalization ensures users can't
accidentally bust it via re-ordered schemas. PRs 4–6 are quality-of-life that
catch the remaining classes of cache-busting bugs cheaply.

All PRs target the PR-#14 branch
(`worktree-bridge-cse_01Q7KUxnaVYkTKTAot8JGY2n`). They merge in order; later
PRs rebase on top of earlier merges.

---

## PR 1 — Cache-policy types

### Files
- `lib/pera_types/types.ml(i)` — add types
- `lib/pera_provider/provider.ml(i)` — extend `simple_stream_options` (or
  equivalent request-option carrier — confirm exact location at start of work)
- `lib/pera_provider/test/` — type-level test that variants round-trip
  through serialization where applicable

### Interface

```ocaml
(* pera_types/types.ml *)
type cache_ttl =
  | Five_minutes
  | One_hour
[@@deriving eq, show]

type cache_policy =
  | None
  | Conversation
  | SystemAndToolsOnly
[@@deriving eq, show]

(* Default for new code paths: cache_policy = None.
   Opt-in everywhere; no surprise cache writes. *)
```

The `simple_stream_options` record (or the equivalent that flows from harness
→ provider) gains:

```ocaml
{
  ...existing fields...;
  cache_policy : Types.cache_policy;  (* default None *)
  cache_ttl : Types.cache_ttl;        (* default Five_minutes *)
}
```

Threading only — no request body change in PR 1. Anthropic request builder
accepts the policy but ignores it.

### Tests
- `equal` / `show` derivations work for both new types.
- Default field values flow through harness construction without forcing every
  caller to supply them (use optional record-update pattern Pera already uses).

---

## PR 2 — Opaque `Tool.t` + canonical JSON serializer

### Files
- `lib/pera_core/agent_types.ml(i)` — make `'ctx tool` private; add `Tool`
  submodule with smart constructor and accessors
- `lib/pera_provider/json_schema.ml(i)` — `to_json` becomes canonical
  (alphabetical recursive `Assoc` sort)
- `lib/pera_tools/read_tool.ml` — migrate to `Tool.create`
- `lib/pera_tools/write_tool.ml` — migrate
- `lib/pera_tools/bash_tool.ml` — migrate
- `lib/pera_tools/grep_tool.ml` — migrate
- `lib/pera_core/agent_loop.ml` and any other call sites that access
  `tool.execute` / `tool.name` / `tool.schema` directly — use accessors
- `lib/pera_provider/test/json_schema_test.ml` (new or extend) — canonical
  byte tests
- `lib/pera_tools/test/*_test.ml` — update for opaque type

### Interface

```ocaml
(* pera_core/agent_types.mli *)
module Tool : sig
  type 'ctx t

  val create :
    name:string ->
    description:string ->
    schema:Pera_provider.Json_schema.t ->
    mode:[ `Sequential | `Parallel ] ->
    execute:
      (ctx:'ctx ->
       args:Yojson.Safe.t ->
       sw:Eio.Switch.t ->
       cancel:Eio.Cancel.t ->
       (tool_output, Pera_types.Types.tool_error) result) ->
    'ctx t

  val name : _ t -> string
  val description : _ t -> string
  val schema : _ t -> Pera_provider.Json_schema.t
  val mode : _ t -> [ `Sequential | `Parallel ]
  val execute :
    'ctx t ->
    ctx:'ctx ->
    args:Yojson.Safe.t ->
    sw:Eio.Switch.t ->
    cancel:Eio.Cancel.t ->
    (tool_output, Pera_types.Types.tool_error) result
end

(* Keep `type 'ctx tool = 'ctx Tool.t` as a transitional alias if needed,
   removed at the end of PR 2. *)
```

### Canonical serializer rules
- Every `Assoc` key list emitted in **alphabetical order**, recursively.
- `required : string list` for object schemas: emitted alphabetically (not
  declaration order).
- `properties` in `Object` schemas: alphabetical at serialization time. Source
  declaration order preserved in `Json_schema.t` itself (for readability) —
  sorting happens only in `to_json`.
- Numeric formatting: integers as JSON `Int`, floats as `Float`. No
  `Intlit` / string fallbacks from this code path. (yojson already does
  this; tests pin it.)
- Compact: callers use `Yojson.Safe.to_string`, never `pretty_to_string`,
  when building request bodies. Add a comment on the canonical serializer to
  this effect.

### Tests
- Two `Json_schema.t` values with the same fields in different declaration
  orders produce identical `to_json` bytes.
- Schema fingerprint stable across 100 random shuffles (qcheck-style if Pera
  already uses it; otherwise a hand-rolled fixed permutation set).
- All 4 existing tools' canonical bytes pinned with golden tests
  (`Alcotest.check string` with the exact expected JSON).
- Tool record access via accessor functions everywhere; no record literal in
  any user code after migration.

---

## PR 3 — Anthropic request: place `cache_control` per policy

### Files
- `lib/pera_provider/anthropic_request.ml(i)` — accept `cache_policy` and
  `cache_ttl`, emit markers
- `lib/pera_provider/test/anthropic_request_test.ml` — test each policy
  variant produces the expected breakpoint placement
- `lib/pera_provider/anthropic_provider.ml(i)` — thread policy from
  `simple_stream_options` (already populated by PR 1) into
  `anthropic_request`

### Breakpoint placement per variant

Following pi-harness (`vendor/pi/packages/ai/src/providers/anthropic.ts`),
adapted to Pera's structure:

| Variant | System block | Last tool | Last user message |
|---|---|---|---|
| `None` | — | — | — |
| `Conversation` | ✓ | ✓ | ✓ |
| `SystemAndToolsOnly` | ✓ | ✓ | — |

Each ✓ is one `cache_control: { type: "ephemeral", ttl: <ttl> }` marker.
Three slots maximum; one of Anthropic's four allowed breakpoints remains
unused for future use (e.g., the 20-block-lookback mitigation if it
materializes).

### Helper

```ocaml
(* anthropic_request.ml *)
let cache_marker ttl =
  match ttl with
  | Types.Five_minutes ->
      `Assoc [ ("type", `String "ephemeral") ]
  | Types.One_hour ->
      `Assoc [
        ("type", `String "ephemeral");
        ("ttl", `String "1h");
      ]
```

System block tagging: the last text block in the system list gets
`cache_control: cache_marker ttl` added to its `Assoc`.

Last-tool tagging: index = `List.length tools - 1`; only that tool's
top-level `Assoc` gets the marker.

Last-message tagging: only emitted when the last message is `role: "user"`
(this is always true at the moment of a turn-starting request; assert it).
If the message's `content` is a string, wrap into a single-element array of
`{type: text, text: ..., cache_control: ...}`. If already an array, append
`cache_control` to the last block.

### Tests

- For each policy variant, build a fixture request (system + 2 tools + 1
  user message) and assert the rendered JSON includes the right markers in
  the right places.
- Verify TTL: `Five_minutes` emits `{"type": "ephemeral"}` (no ttl field);
  `One_hour` emits `{"type": "ephemeral", "ttl": "1h"}`.
- Verify `None` emits no `cache_control` anywhere.
- Verify `SystemAndToolsOnly` does not put a marker on the last message.
- Mixed-TTL is not supported (we pick one TTL per request), so no test
  needed for it.

### Verification after merge

Run a real conversation turn against Anthropic, log the response usage:
`cache_creation_input_tokens` on turn 1, `cache_read_input_tokens > 0` on
turn 2 with the same system + tools. The interpreter already populates
these (`anthropic_interpreter.ml:134-148`).

---

## PR 4 — Construction-time dynamic-content linter

### Files
- New module `lib/pera_core/cache_lint.ml(i)` or inline helper in
  `agent_types.ml` (decide at impl time based on shared use with system-prompt
  builder)
- `Tool.create` calls the linter
- System-prompt builder (location TBD) calls the linter
- Tests

### Heuristic

A regex set run against tool `description` and the system prompt text:

| Pattern | Why |
|---|---|
| ISO 8601 timestamp: `\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}` | "Today is 2026-06-19T..." style timestamps |
| RFC 3339 date: `\b\d{4}-\d{2}-\d{2}\b` | "Built on 2026-06-19" |
| UUID v4: `\b[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b` | Session IDs leaking in |
| Long digit run (≥10 digits): `\b\d{10,}\b` | Epoch seconds / millis |

On match, `Logs.warn (fun k -> k "[cache] %s appears to contain dynamic
content (%s): %S" field_label pattern_name matched_substring)`.

### API

```ocaml
val warn_if_dynamic : ?quiet:bool -> field:string -> string -> unit
```

`?quiet:true` silences the linter (useful in tests that intentionally pass a
date string). Default false.

### Tests
- Each pattern triggers a warning on a known-bad input.
- `~quiet:true` suppresses warnings.
- Tool created with a clean description produces no warning.
- Tool created with a timestamped description produces one warning naming the
  pattern.

---

## PR 5 — Session-level fingerprint and "prefix changed" warning

### Files
- `lib/pera_harness/` (location TBD — wherever session is constructed)
- Tests

### Approach

At session creation:
1. Concatenate the canonical JSON of every registered tool + the system prompt
   bytes.
2. Hash with SHA-256 (or `Digest.string` for simplicity — collision risk
   irrelevant here since this is a stability check, not a security boundary).
3. Store fingerprint on the session.

Before each request:
1. Recompute fingerprint.
2. If unchanged: no-op.
3. If changed and `cache_policy <> None`: emit
   `Logs.warn (fun k -> k "[cache] prefix changed since last turn; previous
   cache writes invalidated")`. Include a one-line hint if cheap to compute
   (e.g., "tools differ" vs "system prompt differs").

### Why this matters

Without this, cache misses are silent. With it, a user editing a tool
description mid-session sees an immediate "you just invalidated your cache"
warning rather than discovering it via mysteriously higher token bills.

### Tests
- Fingerprint stable across two builds of the same tool set.
- Fingerprint changes when one tool's description changes by one character.
- Warning fires when fingerprint changes and policy is `Conversation`.
- No warning when policy is `None`.

---

## PR 6 — Surface cache_read / cache_write in status output

Display layer. Depends on what status surface Pera has at the time. Pi shows
session-cumulative `↑in ↓out R{cacheRead} W{cacheWrite}` in a TUI footer
(`packages/coding-agent/src/modes/interactive/components/footer.ts`).
Pera's equivalent is whatever the CLI / driver layer renders. Worth a UX
conversation before implementing.

Out of immediate scope; mentioned for completeness.

---

## Open questions for the implementer

1. **Where exactly does `cache_policy` enter request construction?**
   `simple_stream_options` is the most likely carrier, but confirm by reading
   `lib/pera_provider/provider.mli` and the harness wiring at start of PR 1.

2. **Is there a transitional alias `type 'ctx tool = 'ctx Tool.t` worth
   keeping?** Probably not — "Migrate all" was the decision, and the alias
   only helps if downstream code we don't control depends on the record
   shape. Inside this repo, single sweeping migration is cleaner.

3. **System-prompt construction location.** Find at start of PR 4. The
   linter needs to hook there too.

## Source references

- Anthropic prompt caching docs (current as of 2026-06):
  https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- Pi-harness Anthropic provider (reference implementation):
  `vendor/pi/packages/ai/src/providers/anthropic.ts:909,925,1136,1187`
- Pi-harness TTL gating: `vendor/pi/packages/ai/src/providers/anthropic.ts:44-67`
- PR #14 (OpenAI side, prerequisite): surfaces `cached_tokens` from the
  `prompt_tokens_details` field in usage responses.
