# OCaml Port of pi-agent-core — Architectural Specification

> Source: `github.com/earendil-works/pi` (MIT).
> Target: OCaml 5 + Eio.
> Status: design draft v0.4.

This document specifies the architecture of an OCaml port of the pi coding agent. Each section opens with what the component is and why it exists, then specifies the design and the load-bearing decisions. Implementation sequencing appears only where a checkpoint admits a property that earlier states cannot have.

---

## 0. What this builds

A coding agent is a loop that calls an LLM, looks at the response, runs any tools the LLM asked for, feeds the results back, and asks again until the LLM decides it's done. Everything else — the streaming UI, the session log, the context compression, the tool catalogue — is machinery around that loop.

The pi codebase factors this machinery into layers with deliberate seams. The agent loop itself is small and pure: it knows nothing about HTTP, filesystems, or providers. Around it sits the provider layer (talks to LLMs), the execution environment (talks to the OS), the session log (records what happened), and the compaction subsystem (keeps long conversations alive). Each layer has one job; each seam between layers is narrow.

This port preserves that shape. The OCaml version is functor-heavy where pi is interface-typed (most prominently the execution environment), value-based where pi is class-based (the agent wrapper, the event stream), and immutable where pi is mutable for snapshots (partial messages during streaming). These are the only deliberate divergences. Otherwise the architecture mirrors pi closely enough that test ports translate directly.

---

## 1. Scope

**In scope.** A headless coding agent. Two providers — Anthropic native API and the OpenAI chat-completions API, the latter configured for OpenCode Zen and OpenCode Go. A pluggable execution environment over filesystem and shell. Append-only session logging. Context compaction sufficient for long sessions. Four tools (read, write, bash, grep). Stdin/stdout CLI.

**Designed around** (postponed but the architecture must not preclude). Resuming or branching previously-logged sessions. OAuth-refreshed auth. Alternative execution environments (SSH, Irmin, sandbox). Image input. The `edit` tool. Auto-invoked skills. User-customisable prompt templates. Streaming compaction. MCP servers, extensions.

**Out of scope** (will not influence the design). TUI. HTTP proxy. Prompt-cache markers and vision content blocks. Branch summarisation (the abandoned-branch labelling subsystem).

---

## 2. Architecture

### The layers and what they do

```
┌───────────────────────────────────────────────────────┐
│  CLI                  stdin/stdout, slash commands    │
├───────────────────────────────────────────────────────┤
│  Tools                read, write, bash, grep         │
├───────────────────────────────────────────────────────┤
│  Harness              ExecutionEnv (functor),         │
│                       session log, compaction,        │
│                       prompt assembly, message conv   │
├───────────────────────────────────────────────────────┤
│  Agent core           turn lifecycle, hooks,          │
│                       tool execution semantics,       │
│                       event streams                   │
├───────────────────────────────────────────────────────┤
│  Provider layer       provider interface,             │
│                       SSE parsing, message types,     │
│                       JSON schema, auth               │
└───────────────────────────────────────────────────────┘
```

The **provider layer** translates between a unified message vocabulary and provider-specific HTTP APIs. Without it, every layer above would need provider-specific branches. It owns SSE parsing, request construction, response interpretation; it has no knowledge of agents, tools, or persistence.

The **agent core** is the orchestration loop — the actual "agent". It runs the canonical dance: call the LLM, look at the response, run any tools, feed the results back, ask again. The loop is pure with respect to IO; it never opens a file, never makes an HTTP call. It takes callbacks for everything external. That purity is what lets the same loop run in a CLI, a server, or a test harness without conditional compilation.

The **harness** is where system integration lives. It owns the execution environment (filesystem and shell), the session writer, the compaction policy, the prompt templates and skills catalogue. It binds the abstract loop to a real OS by populating the loop's hooks. The harness is the only layer that knows it's running on a real machine.

The **tools** are the agent's ability to do things in the world. Without them, the LLM can describe but not act. Each tool exposes a name, a JSON Schema for its arguments, and an execute function. The schema serves both as the LLM's menu (it tells the model what calls are available) and as the runtime validator on incoming calls.

The **CLI** is intentionally thin: it wires the harness to stdin/stdout, parses arguments, renders events to the terminal, and recognises a small set of slash commands.

Each layer depends only on those below. The agent core has no knowledge of HTTP; the harness has no knowledge of SSE; the tools have no knowledge of providers. Cross-layer communication is through narrow seams:

| From | To | What crosses |
|---|---|---|
| Agent core | Provider | `stream_fn` callback yielding an event stream; `convert_to_llm` callback |
| Harness | Agent core | Loop entry points; hook callbacks; event subscription |
| Tools | Harness | First-class `ExecutionEnv` module value |
| CLI | Harness | A `prompt`-style entry point; subscription for event rendering |

### Concurrency

Eio, with structured concurrency under switches. Long-lived components (the agent wrapper, the session writer, the SSE consumer) run as fibres under a parent switch supplied by the caller. Cancellation is `Eio.Cancel`, not a signal threaded through every function. The agent run takes an `Eio.Cancel.t`; cancelling aborts the in-flight LLM stream (HTTP connection closed) and any running tool fibres at their next async point.

### Error policy

Two regimes. IO operations return `Result` and never raise — backend failures are normalised into typed error codes (`NotFound`, `PermissionDenied`, `Timeout`, `Aborted`, etc.). This matches pi's discipline and the test suite depends on it. Programmer errors — calling `run_continue` from an assistant message, raising in a hook — raise; they are bugs, not recoverable conditions, and they should fail loudly.

Tool errors are caught by the loop and converted into tool-result messages with an `is_error` flag, so the LLM can react ("I tried but I got an error; let me try a different approach"). An unhandled exception inside a tool fibre is a programmer error and propagates out of `run`.

### State ownership during a run

The agent loop owns one `agent_context` record for the duration of a run. Its `messages` field grows as the conversation progresses; the loop replaces a "partial" assistant message in place at the end of the list as deltas arrive, then swaps it for the final message on completion. No other component holds a mutable handle on the context. The harness reads from it via subscriptions but never writes to it; writes go through the loop. This single-owner discipline is what makes session logging coherent: every state change in the context corresponds to a single event the harness can persist.

---

## 3. Data model

### Messages

The provider layer and the agent core have nearly-identical message types but they are not the same type. The provider's `message` is what an LLM consumes — user, assistant, tool result, each with a closed set of content variants. The agent core's `agent_message` is a superset that also permits *synthetic* messages: harness-injected user messages carrying compaction summaries, model-change markers, and so on. `convert_to_llm` flattens `agent_message list` into `message list` before each LLM call.

This split exists so the harness can introduce structure the LLM doesn't need to see. A `CompactionEntry` in the session log corresponds to a synthetic user message in the agent context; both reference the same summary text, but the LLM only ever sees the user message.

Content variants:

```
user_content       ::= UText | UImage
assistant_content  ::= Text | Thinking | ToolCall
tool_result_content::= text or JSON, with is_error flag
```

An assistant message records its provenance — `api`, `provider`, `model`, `stop_reason`, optional `error_message`, `usage` (token counts and dollar cost). Provenance matters because a session can switch models mid-run; compaction needs to attribute usage correctly and the session log needs to record which model produced each message.

### Tools

A tool is a value with three parts: a name, a JSON Schema for its arguments, and an `execute` function. The `execute` function takes an execution context (typically an `ExecutionEnv` module value), parsed arguments, and concurrency primitives (switch, cancel). It returns either a tool output (text or JSON) or a tool error.

```ocaml
type 'ctx tool = {
  name : string;
  description : string;
  schema : Json_schema.t;
  execute :
    ctx:'ctx ->
    args:Yojson.Safe.t ->
    sw:Eio.Switch.t ->
    cancel:Eio.Cancel.t ->
    (tool_output, tool_error) result;
}
```

The `'ctx` parameter is intentionally generic. Local-disk tools fix `ctx = (module Execution_env.S)`; a future Irmin-backed tool might fix it differently.

### Events

Two event vocabularies operate at different levels.

The provider layer emits `assistant_message_event`s — fine-grained state changes during a single LLM response. Each event marks a transition (a text block starting, a tool-call argument fragment arriving, the stream ending) and carries a *snapshot* of the assistant message as it stands. Consumers that want the final message wait for the terminating `done` or `error` event; consumers rendering live UI read each event's snapshot.

The agent core emits `agent_event`s — turn-level events plus tool-execution events plus compaction events. The agent core consumes provider events and re-emits them upward, mostly as `message_update` carrying both the latest snapshot and the underlying `assistant_message_event`. Simple consumers ignore the inner event and read the snapshot; sophisticated consumers (token-by-token telemetry, incremental highlighting) read the inner event.

Both vocabularies are closed sums. Adding a variant is a breaking change for consumers. This is deliberate — an open vocabulary makes exhaustive matching impossible, and the consumer set is small enough that breakage is manageable.

### Sessions

The session log is an append-only sequence of typed entries, each carrying an `id`, an optional `parent_id`, and a timestamp. Entry types include `Message`, `Compaction` (with summary and cut-point reference), `ModelChange`, `ThinkingLevelChange`, `Label`, `Leaf`, and opaque `SessionInfo`.

Entries form a tree, not a list — the `parent_id` makes that explicit. Linear conversations are a degenerate tree where every entry's parent is the entry just before. Compaction makes the tree non-trivial: a `Compaction` entry's parent is the last message of the head; the synthetic user message that follows is parented to the compaction entry. The head messages remain in the file, no longer on the active branch from the leaf, but available for replay, audit, or branching.

This is why the format must be a tree from day one. Even if v1 never reads the file back, future restore code must walk from a `Leaf` through the tree to recover the active conversation. A flat-list format would force a destructive rewrite on every compaction.

**Two senses of "leaf."** The word is used two ways and they must not be conflated. *The leaf* (lowercase, "current leaf") is a *position* — the tip of the active branch, i.e. wherever the writer's `current_parent_id` points. A `Leaf` *entry* (capitalised, an entry type) is a *persisted, childless marker* appended at that tip to record "a resumable tip was here." **Invariant: a `Leaf` entry never has children.** Content entries (`Message`, `Compaction`, the synthetic compaction `Message`) always chain off the previous *content* entry, never off a `Leaf` entry. Concretely, appending a `Leaf` records its `parent_id` as the current tip but does *not* advance the tip; the next content entry parents to the same content entry the `Leaf` did. Restore walks back from the *most recent* `Leaf`; earlier `Leaf` entries are inert markers of superseded tips and are skipped. This is what makes "walk from a `Leaf`" unambiguous, and it is consistent with compaction (§8), where the `Compaction` entry is parented to the last *message* of the head — never to a `Leaf` entry.

**When a `Leaf` is written.** A `Leaf` marks a stable, resumable tip. The agent reaches such a tip when a run goes idle — at `agent_end`, the point between sends from which a session would actually be resumed (never mid-turn, never mid-tool-execution). So one `Leaf` is written per completed run (per `send`). Compaction (§8) writes an additional `Leaf` at the new compacted tip, because compaction also produces a stable resumable point mid-run. Restore must tolerate a session whose final entry is not a `Leaf` (a crash between the last content entry and its `Leaf`): it treats the deepest reachable content entry as the tip.

Entry IDs are standard, non-truncated UUIDv7 strings (the full 36-character representation). UUIDv7's timestamp prefix means lexicographic id order matches creation order across processes. The full representation is used rather than a truncated form: it guarantees uniqueness without an allocation-time collision check, which truncation to 8 characters would have required. Clock non-monotonicity within a millisecond is not a practical concern for session ordering and is documented at the generator.

### Errors

Three error families. `file_error` (code, path, message) — every filesystem call returns this on failure. `execution_error` (code, message) — shell execution failures. `tool_error` (message, is_user_error) — tool execution failures; the boolean distinguishes "the LLM passed bad arguments" from "the tool itself failed". Codes are closed sums so handler code can pattern-match without a catchall.

---

## 4. The provider layer

### Role

Every LLM provider has its own incompatible HTTP API. Anthropic wants one JSON shape, OpenAI a different one. The provider layer's job is to make all of this look the same from above. It accepts the unified message vocabulary, picks the right provider for the model, builds the right request, parses the response back into the unified event stream. Without it, every other layer would need provider-specific branches.

Streaming is part of the same job. LLMs produce text chunk by chunk; an LLM call is a long-lived HTTP response. Showing output as it arrives is the difference between "feels alive" and "feels broken", and observing intermediate state is the only way to cancel cleanly, render progress, or update a UI in real time.

### Provider interface

A provider is a module satisfying `Provider.S`:

```ocaml
module type S = sig
  val name : string
  val stream_simple :
    env:Eio_unix.Stdenv.base ->
    model:Types.model ->
    context:context ->
    options:simple_stream_options ->
    sw:Eio.Switch.t ->
    (Types.assistant_message_event, Types.assistant_message) Event_stream.t
end
```

`context` carries the system prompt, the message list (already in provider-native shape after `convert_to_llm`), the tool list, and reasoning settings. `stream_simple` is the only required entry point: it returns an event stream that yields `assistant_message_event`s and eventually resolves to a final `assistant_message`.

The `~env` parameter carries the Eio environment needed to open network connections. This is a constraint imposed by piaf (the HTTP client library). The environment does not cross the `Provider.S` seam in terms of semantics — providers use it only to initiate HTTP connections. A future `Http_client` abstraction module would wrap piaf behind an interface, shrinking the footprint of `~env` to a narrower type; for now the full Eio base environment is passed through.

Providers are looked up by `model.api`. The registry is built explicitly at startup as a `Provider_registry.t` — no global state, no side-effecting `register-builtins.ts`-style imports. This costs one line at startup and gains testability and predictable construction order.

### The event stream primitive

The same generic type `('event, 'result) Event_stream.t` is reused at three levels of the stack.

Inside a provider parser, it carries `(assistant_message_event, assistant_message) t` — the parser pushes events; the result resolves with the final message on `done` or `error`.

As the provider's external interface, it returns from `stream_simple` — same type, same semantics.

Inside the agent core, it carries `(agent_event, agent_message list) t` — the loop pushes events; the result resolves with new messages on `agent_end`.

One primitive at three levels means one cancellation story, one backpressure story, one consumer pattern. Implementation is a thin layer over `Eio.Stream.t` for the buffer plus an `Eio.Promise.t` for the result. The buffer is bounded (capacity 32 by default) so a stalled consumer eventually backpressures the producer.

### SSE — what's on the wire

The protocol is simple. The agent POSTs to the provider with `Accept: text/event-stream`. The response body streams over time as plain text events separated by blank lines:

```
event: message_start
data: {"type":"message_start","message":{...}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: message_stop
data: {"type":"message_stop"}
```

That's the whole wire protocol. No framing, no length prefix — events end at a blank line. The simplicity is a feature: it's just HTTP, so any proxy that understands HTTP understands SSE. The cost is that the parser has to handle chunk boundaries — TCP can split a single event across multiple network reads, so the parser buffers incomplete lines until the next chunk arrives.

Providers do not agree on what events they emit on top of this wire format. Anthropic sends a structured lifecycle: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`. The model can interleave text, thinking, and tool calls — each becomes its own content block. Tool-call arguments arrive as a stream of JSON fragments to be concatenated and parsed at block stop.

OpenAI's chat completions send something flatter: `data: {"choices":[{"delta":{"content":"Hello"}}]}` per chunk, with no explicit content-block lifecycle. The parser infers "started a text block" by noticing the first `content` field. Tool calls have an `index` so fragments can be correlated. Reasoning content appears in a separate field — `reasoning_content` for most providers, `reasoning` for OpenCode Go, etc.

### SSE parsing — two layers

The port separates chunk parsing (provider-agnostic) from event interpretation (provider-specific).

**Chunk parser.** Consumes byte chunks, emits framed events `{event_type, data, id}`. Handles `\n\n` delimiters, multi-line `data:` continuations, and incomplete events buffered across chunk boundaries. One implementation, shared.

**Provider interpreter.** Consumes framed events, emits `assistant_message_event`s. Each provider has its own state machine over its own event vocabulary. Adding a third provider means writing a new interpreter; the chunk parser is reused.

This is the only place where provider differences appear above the wire format. Everything else above the provider layer sees the same `assistant_message_event` vocabulary regardless of which model the user picked.

### Partial messages — the snapshot decision

The pi TS code mutates one shared `partial: AssistantMessage` reference across events; every event's `partial` field is the same object observed at successive points in time. The OCaml port diverges: each event carries an immutable `assistant_message` snapshot.

You could design the event stream three ways:

1. **Emit deltas only.** Each event says "add 'Hello' to text block 0". Subscribers maintain their own assembled message by applying deltas. Stream is small; every consumer reimplements assembly.
2. **Emit snapshots only.** Each event carries the full message-so-far. Subscribers replace their snapshot. Bigger payloads but consumers are trivial.
3. **Emit both.** Each event carries the delta *and* a snapshot. Cheap consumers read the snapshot; sophisticated consumers read the delta.

Pi does (3) but with a twist: the snapshot is a *reference* to one mutable object that the parser keeps mutating. A subscriber that wants to record state at event time must clone, because subsequent events mutate the same object. The TS code handles this in one place (the agent loop shallow-clones before re-emission upward) but the trap exists for any other consumer.

The OCaml port does (3) too, but with an immutable snapshot. The interpreter holds in-progress state internally — a builder with a `Buffer.t` per active text block, the partial list of completed blocks, accumulated usage — and constructs a fresh `assistant_message` value at each emission. Consumers can store any `event.partial` value safely; it will not change. The cost is more allocation; the saving is removing a class of bug. Text deltas still accumulate efficiently in a `Buffer.t` (mutable internally); the snapshot is constructed from it without quadratic concatenation.

### Auth resolution

Two patterns matter. A static API key is set once and used forever. A short-lived OAuth token can expire mid-session — the agent might be in the middle of a tool execution when its token expires, and the next LLM call needs a fresh one. GitHub Copilot and OpenAI Codex use the latter. The agent core supports both shapes from day one even though v1 only uses static keys:

```ocaml
type api_key_resolver =
  | Static of string
  | Dynamic of (provider:string -> string option)
```

The provider resolves a key for each LLM call. The agent core threads an optional `get_api_key` hook through the loop config so applications can inject a fresh key per-call without the provider knowing about OAuth.

### Anthropic and OpenAI-completions

**Anthropic.** Native API at `/v1/messages`. SSE events as above. Tool calls arrive as JSON fragments in `content_block_delta` for `tool_use` blocks; the interpreter concatenates by block index and parses JSON at `content_block_stop`. Skipped in v1: prompt caching, vision, ping events (ignored).

**OpenAI-completions.** A single provider implementation targeting any endpoint speaking the chat completions API. Per-endpoint differences (which field carries reasoning content, whether tool-result messages require a `name` field, max-tokens field name, etc.) are encoded in a `compat` record selected by base URL. OpenCode Zen and OpenCode Go differ in base URL and in one field name — both configured by `compat`, not by separate provider modules. New endpoints with similar quirks are accommodated by adding flags; provider code is shared.

---

## 5. The agent core

### Role

This is the orchestration loop, and it's the actual "agent". Its job is the canonical dance: call the LLM, look at the response, run any tools it asked for, feed the results back, ask again until done.

The loop is deliberately pure with respect to IO. It has no file handles, no HTTP client, no clock. It takes callbacks for everything external — a `stream_fn` that calls into the provider, a tool list whose `execute` functions are callbacks, hook callbacks for policy. Mutation is scoped to one `current_context` record that lives for the duration of a run. This purity is what lets the same loop run in a CLI, a server, or a test harness with completely different hooks.

### Turns

A turn is one cycle of that dance: one LLM response, plus the execution of any tool calls it produced, plus the appending of their results. A turn starts when the loop begins streaming the next assistant message; it ends when tool results (if any) have been appended.

The turn is the unit of policy. Almost everything interesting happens at turn boundaries — that's when the harness compacts, when the application decides whether to stop, when a CLI flushes a session entry, when a follow-up message gets injected. Defining the turn explicitly means policies attach at known moments instead of guessing where to interrupt mid-stream.

### Control flow — outer and inner loops

Two nested loops. They exist because there are two different "user input arriving" lifecycle events.

The **inner loop** processes turns while there are tool calls to chase or pending steering messages. Each iteration:

1. If steering messages were captured before this iteration, inject them as user messages before the LLM call. (Steering messages are user input arriving *during* a run — e.g. the CLI's input handler captures something while the agent is mid-stream.)
2. Stream the assistant response. The loop consumes the provider's event stream, replacing the last entry in `context.messages` from partial to final as it goes.
3. If the stop reason is error or aborted, terminate the run.
4. If the response contains tool calls, execute them; append their results to the context.
5. Emit `turn_end`.
6. Run `prepare_next_turn` hook: it may swap context, model, or thinking level.
7. Run `should_stop_after_turn` hook: if `true`, terminate.
8. Capture any new steering messages for the next iteration.

The inner loop exits when the model has no more tool calls and no steering messages have arrived.

The **outer loop** runs when the inner exits. It checks for *follow-up* messages — user input arriving *after* the agent decided to stop but before the program exits. If any are present, they become the next iteration's pending messages and the inner loop restarts. If none, the run ends.

The distinction: steering is "the user is talking *during* the run"; follow-up is "the user is talking *between* runs but in the same session". They are read from different queues and emitted to different events.

### Hooks — the policy vocabulary

Hooks are how the loop stays generic while still being customisable. At each meaningful moment the loop calls a function the application provided. If the function returns new state, the loop adopts it.

| Hook | When called | Returns |
|---|---|---|
| `transform_context` | Before each LLM call | Modified message list |
| `get_api_key` | Before each LLM call | Fresh API key, or `None` to use static |
| `before_tool_call` | Before executing each tool call | `Allow` or `Deny string` |
| `after_tool_call` | After each tool execution | unit (side-effect only) |
| `should_stop_after_turn` | After each turn ends | `bool` |
| `prepare_next_turn` | Between turns | Optional snapshot swap (context, model, thinking) |
| `get_steering_messages` | At inner-loop iteration start | New user messages to inject |
| `get_follow_up_messages` | At outer-loop iteration start | New user messages to continue past stop |

The harness populates several. Compaction triggers as a side effect of `should_stop_after_turn`: when the context exceeds threshold, compact synchronously, update the context, and return `false` (don't stop — continue with the compressed context). Session writes happen through `after_tool_call` and through every event delivered to the harness's subscriber. Permission gating lives in `before_tool_call`: an interactive CLI prompts a human, a CI agent allows everything, a sandbox refuses `bash` outright.

`prepare_next_turn` and `should_stop_after_turn` together cover all between-turn behaviour. The first is for mutating state; the second is for terminating. They could be merged into one hook returning `[\`Continue of snapshot | \`Stop]`. Pi keeps them separate; the OCaml port follows for test-port parity. A v2 refactor could merge them.

Hooks may not raise. Doing so propagates out of `run`, which is treated as a programmer error.

### Tool execution — ordering matters

The agent loop owns tool execution because tool execution semantics are part of the loop's contract. Two modes: `Sequential` (default for tools that mutate state, like `bash`) and `Parallel` (default for read-only tools like `read` and `grep`). Mode is set per-loop with per-tool overrides.

In parallel mode, each tool call in the assistant message runs in its own fibre under a sub-switch. Results are collected as fibres complete; events `tool_execution_start` and `tool_execution_end` fire in real (concurrent) order.

But the `tool_result_content list` appended to the message history is sorted by the original tool-call index — *not* by completion order. This is the subtle rule and it's not optional. LLM tool-call/tool-result correlation is positional in some providers and id-based in others; in both cases, the model expects results to track the order in which it issued calls. A results list out of order against the message list breaks the next LLM call. Concurrency is for execution; bookkeeping stays ordered.

Tool errors are caught and converted to error tool-result messages so the LLM can react. `before_tool_call` returning `Deny msg` short-circuits execution: the loop synthesises an error result with the given message and skips the actual call. Schema validation failures do the same — args are checked against the tool's schema before `execute` is called.

### Cancellation

The run takes an optional `Eio.Cancel.t`. Cancellation propagates:

- During an LLM stream: the HTTP client closes the connection. The provider emits an `AME_error` event with `Aborted`. The loop emits `turn_end` with empty tool results and `agent_end`, then returns.
- During tool execution: the sub-switch is cancelled; running fibres receive cancellation at the next async point. Whatever results completed are still appended in source order, then the run terminates as above.
- Between turns: cancellation is observed at the next hook call boundary.

There is no mid-event cancellation observation — cancellation during event consumption is checked between events. The model is: cancellation is *eventually* observed at the next async point.

---

## 6. The agent wrapper

### Role

The bare loop is a function: you call it, you give it hooks and a sink for events, it runs to completion. That's enough for many applications, but it has gaps that become problems as the system grows.

The agent wrapper fills those gaps. It is a thin layer over the loop providing three things:

**Subscription.** Multiple consumers can listen to events. The loop emits to a single sink; the wrapper fans out. Subscribers can be added and removed at any time. The harness's session writer is one subscriber; the CLI's renderer is another; future UI layers are additional subscribers. Without the wrapper, the harness either subscribes to the loop and forwards (coupling) or implements its own subscription internally (duplication).

**Serialised sends.** Runs are processed one at a time. The wrapper is an actor: `create` forks a long-lived fibre that owns the loop, and `send` enqueues a run onto a capacity-1 mailbox and awaits its completion. A second `send` issued while one is running does not raise and does not interleave — it blocks until the actor takes it, then runs after the first completes. This guarantees events from distinct runs never interleave into the same subscribers (which no consumer is designed to handle) while letting callers queue work without coordinating themselves. (Pi raises on a concurrent `send`; the OCaml port serialises instead, because the actor mailbox makes queueing the natural and safer default. The reply promise is always resolved — via `Fun.protect` and `Eio.Cancel.protect` — so a caller never blocks forever, even if the run raises or is cancelled.)

**Observable state.** `is_streaming`, `pending_tool_calls`, `context` — accessors that UI code can poll without subscribing to every event. Useful for status lines, progress indicators, and "what tools is the agent currently running" displays.

State held by the wrapper: subscriber list, a flag for whether a run is active, the set of in-flight tool calls (updated from event observation), and a reference to the current context (handed off to the loop on `send`). All state is owned by the wrapper; the loop borrows it for the duration of `send`.

Reason for including it in v1: the harness needs subscription anyway. Building subscription into the harness directly works but couples future UI to the harness. The wrapper is the natural seam.

---

## 7. The harness

### Role

Everything above is portable. The agent loop doesn't know if it's running on a laptop or a serverless platform; the provider layer doesn't care which OS the process is on. The harness is where that abstraction ends. It binds the agent to a real operating system, a real disk, a real shell. If you wanted the agent in a browser worker or against a remote machine, you'd replace the harness and leave the layers above alone.

The harness owns:

- The execution environment (filesystem and shell, as an abstraction).
- The session writer.
- The compaction subsystem.
- Prompt assembly (system prompt + skills catalogue + tool descriptions).
- Skills loading.
- Message conversion between `agent_message` (with synthetic entries) and `message` (what the LLM consumes).

It populates the loop's hooks to wire all of this together.

### Execution environment

The execution environment abstracts the OS. Its central design choice is that "talking to the operating system" should go through one interface so the backend can be swapped. You might be agenting against the local disk, a remote machine over SSH, a sandboxed container, or a virtual filesystem like Irmin. Funneling all OS-shaped operations through one abstraction means swapping the backend swaps reality for the whole agent at once.

The interface is a module type:

```ocaml
module type S = sig
  module Fs : FILESYSTEM
  module Sh : SHELL
end
```

`FILESYSTEM` defines `read_text_file`, `write_file`, `append_file`, `list_dir`, `file_info`, `exists`, `create_dir`, `absolute_path`, `join_path`, `canonical_path` — all returning `Result`. `SHELL` defines `exec` taking a command, optional cwd and env, timeout, streaming output callbacks, and a switch/cancel pair, returning `(exec_result, execution_error) result`.

Tools and harness internals take an `(module Execution_env.S)` first-class module value. Swapping the environment is a one-line change at the call site: `Local_env.create` returns one impl, a future `Ssh_env.create` returns another.

**A note on consistency.** If `Fs` and `Sh` see different worlds — `Fs` is Irmin-backed but `Sh` is real `bash` — then a file the agent writes through `Fs` is invisible to a subsequent `Sh.exec`. This is a real correctness issue for hybrid environments. The interface does not enforce consistency; it is an obligation on implementations. For `Local_env` it is trivial (both halves see the same disk). For `Irmin_env` (future), `Fs` writes must flush to disk before any `Sh.exec`, or shell commands will observe stale state.

The design avoids hiding this issue (e.g., by making `Sh.exec` always observe `Fs` state via some sync mechanism) because hiding it would be misleading in environments where consistency is impossible (a sandbox running on a remote machine). Better to surface the obligation than to provide a leaky abstraction.

**Why one seam instead of two.** Pi's coding tools have their own per-tool ops interfaces (`ReadOperations`, `BashOperations`, etc.) in addition to the harness's `ExecutionEnv`. The two seams don't share — tools use one, the harness uses the other. This is awkward; you can swap one without the other and get inconsistencies. The OCaml port collapses to a single seam. Every tool takes the same `ExecutionEnv` module value the harness uses, so swapping the env swaps reality for tools and harness together.

### Session storage

Everything the agent does — every message, every model change, every tool run, every compaction — gets appended to a JSONL file as it happens. Two reasons. **Replay**: resume tomorrow exactly where you left off, or run a recorded session through a new model for comparison. **Audit**: what did the agent actually do, especially when something went wrong?

Pi stores this as a tree rather than a flat log because compaction creates branches — from a given point, "I'm now using the summary; the original messages are still here on a side branch if you want them." That lets you label points, jump back, and try alternative continuations from the same state.

For v1, "session logging in scope, persistence later" means: write JSONL on every event with the tree structure intact, but defer the tree-walking and resume logic. The file is well-formed and the format is forward-compatible with future restore code.

Writes are durable — each `append_entry` writes the line and `fsync`s before returning. A process crash mid-write may leave a partial line, which a future reader rejects; otherwise the file is well-formed up to the last completed entry.

Reads (for restore) are stubbed in v1. The data structure is in place; the walking algorithm is not. When restore lands, it walks from a `Leaf` entry back through parents, recovering the active branch. Encountering a `Compaction` entry means "replace head with the summary user message and continue from the compaction's child."

### Prompt assembly and skills

Both skills and prompt templates are ways to inject reusable text into a conversation. Skills are markdown files with frontmatter; when invoked (or auto-triggered from context), the body gets added to the system prompt or the next user message. Prompt templates are parameterised fragments — they're how slash commands like `/review` expand into longer instructions. Both exist because people don't want to retype "you are an OCaml expert who prefers functional style" every conversation, and they want to share snippets across teams and projects.

In v1 the system prompt is a composed string built once at agent start from three sources: a hardcoded base prompt, a list of available skills (loaded from a directory) appended as a brief catalog, and tool descriptions formatted automatically from the tool list. The composition does not change mid-run; if skills change, the system prompt does not update. This is a v2 concern.

Skills are loaded but not auto-invoked in v1. They're available as a catalogue; invocation is explicit (the CLI sees `/review-pr arg1 arg2` and constructs a user message embedding the skill body with arg interpolation). Auto-invocation by content classification is deferred. The architecture permits it: a future hook on `transform_context` could inspect incoming user messages and prepend matching skill bodies, but v1 has no such hook.

Prompt templates are hardcoded constants in v1 (most importantly the compaction prompt). The refactor to a template subsystem with frontmatter, parameters, and named slash commands is a v2 concern.

### Message conversion

`convert_to_llm : agent_message list -> message list` is the harness's primary input to the loop. It:

- Drops synthetic harness-only messages with no LLM equivalent (none in v1, but the shape exists).
- Renders compaction summary messages (synthetic user messages produced by compaction) as ordinary user messages with explicit framing text.
- Per-provider, transforms thinking content to text-with-delimiters where the provider does not natively support thinking blocks.
- Converts tool results to the format the provider expects.

---

## 8. Compaction

### Why a subsystem

A conversation with a coding agent grows monotonically. Every user turn, every assistant response, every tool result gets appended to the message list, and that list is sent in full to the model on every subsequent call. The model has a fixed input window — 200k tokens for Claude Sonnet, smaller for many others. After enough turns, the conversation no longer fits, and the agent dies on a `context_length_exceeded` error mid-session.

You could do three things about this:

1. **Truncate from the start.** Drop the oldest messages. Simple, but catastrophic — you lose the original task definition, which is exactly the thing you most need to remember.
2. **Summarise.** Ask the LLM to compress the early part of the conversation into a paragraph that retains the essentials, then continue with the summary in place of the originals.
3. **Selectively prune.** Identify low-value content (file dumps that have since been edited, tool outputs that have been superseded) and remove just those parts.

Pi does (2), with a touch of (3) — the summary prompt explicitly asks the model to preserve recent edits, current file state, and outstanding decisions, and to discard repeated reads of the same file or now-irrelevant exploration.

Compaction is its own subsystem rather than a flag on the loop because it makes three independent decisions: *when* to do it, *what* to keep verbatim and what to compress, and *how* to render the summary back into the message stream. Each is a real policy choice and different applications want different defaults.

### When to compact

The trigger is token-based with a configurable threshold (default: when the next request would exceed roughly 70% of the model's context window). The check happens at turn boundaries — never mid-stream, never mid-tool-execution. Compaction itself requires an LLM call and you don't want to interrupt one to start another.

Token counts are *estimated*, not measured. The estimator is character-count-based with multipliers — roughly chars/4 for prose, chars/3 for code-heavy content. It is conservative — it overestimates slightly so the threshold triggers earlier than strictly necessary. The cost of triggering too early is one extra LLM call; the cost of triggering too late is a hard failure. Conservative is safe. The architecture permits a precise tokeniser to be substituted later; for v1 the heuristic is sufficient.

The threshold is a percentage of the model's window, not an absolute number. Switching models mid-session (cheaper model for routine work, smarter model for hard problems) changes the threshold automatically.

Compaction can also be triggered manually — the CLI's `/compact` command forces an immediate compaction. The manual trigger and the threshold check funnel into the same code path.

### What to keep and what to compress

```
[task definition][old turns ...][tail (last N turns, kept verbatim)]
       ↓
[task definition][summary of old turns][tail (last N turns, kept verbatim)]
```

The task definition — the first user message — is *always* preserved verbatim. Losing it loses the agent's reason for existing. The tail (the last N turns, default 4) is preserved verbatim because the model's working memory of "what I'm doing right now" lives there. Everything between gets fed to a separate LLM call with a summarisation prompt, and the result replaces those messages.

The summarisation prompt instructs the model to preserve file paths the agent has touched and a one-line description of what changed in each; preserve outstanding decisions; preserve the working understanding of the project; discard file contents (they can be re-read); discard exploration that didn't lead anywhere; discard tool calls whose results were immediately superseded; produce output in a structured format with section headers. In v1 the prompt is a hardcoded constant; later it migrates to the template subsystem.

### How the summary is rendered back

The naive thing would be to delete the old messages and insert a synthetic *assistant* message containing the summary. That doesn't work in practice — the model is trained to expect the conversation to be a coherent dialogue, and a wall-of-text summary masquerading as an assistant message confuses it.

Instead, pi (and this port) renders the summary as a synthetic *user* message with text like `"Context from earlier conversation:\n\n" ^ summary`. That framing reads to the model as "the user is telling me what we discussed before", which it handles cleanly.

Integration with the agent context after a successful compaction:

- The in-memory `context.messages` is replaced with `[ first_message; synthetic_message ] @ kept_messages`.
- A `CompactionEntry` is appended to the session log with `parent_id` = current leaf, carrying the summary text and the `first_kept_entry_id`.
- A `MessageEntry` is appended for the synthetic user message, parented to the compaction entry.
- The leaf moves to the new last entry.

The original head messages remain in the session file. They are no longer on the active branch (which walks from leaf back through the compaction), but they remain available for replay, audit, or branching.

**Storage redundancy.** The synthetic message is stored as a real `MessageEntry` *alongside* the `CompactionEntry` which separately records the summary text. Both are written. This redundancy is deliberate: it means a session log is self-contained from a replay perspective (no need to reconstruct the synthetic message from the compaction metadata); the cost is one extra line per compaction.

### Failure handling

If summarisation fails (network error, model error, decode failure), the harness:

- Emits a `compaction_error` event to subscribers.
- Prints a warning line to stderr.
- Does *not* modify `context.messages`.
- Does *not* write session entries.

The next turn proceeds with the uncompacted context. If that turn's LLM call exceeds the model window, the call returns `context_length_exceeded`; the loop terminates with `stop_reason = Error`. This is the hard error: only an actual overflow stops the agent, not a compaction attempt failure.

**Atomicity.** The `CompactionEntry` is written only after the summarisation LLM call returns successfully. A crash during summarisation leaves the file at its pre-compaction state. On restore (v2), the session reopens cleanly; the next turn triggers compaction again, paying the LLM cost a second time. Acceptable.

**Overshoot.** Models sometimes produce summaries that are too long — the summary plus the tail still exceeds the budget. The system retries with a tighter tail; up to 3 attempts. If all fail, the compaction is abandoned (warning emitted) and the next LLM call may overflow as above.

### Architectural levels

Compaction is not all-or-nothing. The system can be useful at intermediate levels of completeness. Each level is a coherent architectural state; the system might ship at L2 and still be useful for many workflows.

**Level 1 — Token awareness.** The system can estimate context size and compare to model window. It can warn when approaching the limit but takes no action. **Property:** the context-size budget is observable.

**Level 2 — Synchronous compaction.** The system can compress its history on demand. A user-issued `/compact` triggers immediate compaction. **Property:** the user can recover from approaching-overflow without losing the session. The summarisation pipeline, the synthetic message rendering, the session log integration are all in place.

**Level 3 — Autonomous compaction.** The system triggers compaction itself at a configurable threshold during the turn cycle. **Property:** long sessions reliably survive. The agent is autonomous-on-context.

**Level 4 — Robust compaction.** Failures during compaction are recovered from (retry-on-overshoot, configurable target model). **Property:** compaction is a stable subsystem rather than a best-effort step.

Levels 1 and 2 require no hook into the loop's control flow — they are observation and user-triggered actions. Level 3 introduces the between-turns hook coupling. Level 4 is purely about the compaction subsystem's internal robustness. A system at Level 2 is useful but requires the user to manage their own context; Level 3 is the minimum for unattended long-running operation; Level 4 is the minimum for production-quality operational tolerance.

---

## 9. Tools

### Role

Tools are the agent's ability to do things in the world. Without them, the LLM can describe but not act. Each tool exposes a name, a JSON Schema describing its arguments, and an executor. The LLM sees a menu of capabilities; when it picks one, the loop validates the arguments against the schema and calls the executor.

The schema does double duty — the LLM uses it to construct valid calls, and the loop uses it as a defensive check on what comes back. Schema validation failures become tool errors with `is_user_error = true`, surfaced to the LLM so it can correct itself.

### Tool as a value

Each tool is constructed by a function that takes an execution environment and returns a configured tool. The tool list passed to the loop config is built by the harness from the configured environment and tool set.

```ocaml
val read  : (module Execution_env.S) -> local_tool
val write : (module Execution_env.S) -> local_tool
val bash  : (module Execution_env.S) -> local_tool
val grep  : (module Execution_env.S) -> local_tool

val default : (module Execution_env.S) -> local_tool list
```

This shape means new tool implementations against different environments compose without modifying the tool definition itself. A future `Ssh_env.create` value can be threaded through the same `read`, `write`, etc. constructors, as long as the env satisfies `Execution_env.S`.

### Runtime schema

Tool schemas are constructed as values. The subset matches TypeBox (which pi uses): `object`, `string`, `number`, `integer`, `boolean`, `array`, `optional`, `enum`, `const`, `any_of`. Each constructor takes optional metadata (description, min/max constraints).

```ocaml
let read_schema = Json_schema.obj ~required:["path"] [
  "path",   Json_schema.string ~description:"Path to read." ();
  "offset", Json_schema.optional (Json_schema.integer ());
  "limit",  Json_schema.optional (Json_schema.integer ());
]
```

The schema is used in two places: it renders to a JSON Schema draft-07 fragment for transmission to the LLM, and it validates incoming tool-call arguments before `execute` is called.

No GADTs, no ppx in v1. The reason is that the schema is data, not types. Tool authors define schemas at runtime, and the schema is also serialised to JSON. A type-level encoding would require the author to mirror schema definitions in both OCaml types and JSON, with a derivation between them. The runtime-data approach has one declaration. The cost is that tool arguments are `Yojson.Safe.t` rather than a typed record; tool authors decode manually. For four tools this is fine; for hundreds it would be tedious and `ppx_deriving_jsonschema` would be worth revisiting.

### The four tools

- **read**: read a file. Args: path, optional offset, optional limit. Output: file contents up to 256 KB / 2000 lines, with a truncation footer if either limit is hit. Mode: Parallel.
- **write**: write a file. Args: path, content. Creates parent directories. Overwrites. Output: bytes written. Mode: Sequential — concurrent writes to the same path race.
- **bash**: execute a shell command. Args: command, optional timeout. Output: stdout, stderr, exit code, truncated. Streams chunks to `AE_tool_execution_update` events. Mode: Sequential always — shell state matters.
- **grep**: search for a pattern. Args: pattern, optional path, optional include glob. Uses `ripgrep` via `Sh.exec` if available; falls back to OCaml `Re` library otherwise. Output: matches as `path:line:content`, capped at 100. Mode: Parallel.

Mode defaults are part of the tool definition; the loop config can override per tool, but the default is what makes sense for the tool's semantics.

---

## 10. CLI

The CLI is intentionally thin. It parses arguments (model, provider, system prompt, cwd, session directory, threshold, tail size). It resolves the API key (flag, file, env var, in that order). It constructs a `Local_env` from `Eio.Stdenv`. It constructs an `Agent_harness` and subscribes to its events. It renders events to stdout (text deltas inline, tool calls as condensed lines, status events as inline status, compaction events as warnings). It reads stdin line-by-line and recognises `/compact`, `/quit`, `/info`; all other input is sent to the agent as a user message.

The CLI holds no state of its own beyond the agent harness handle and the stdin/stdout streams. Slash commands beyond the three above are a v2 concern (they require the prompt-template subsystem).

---

## 11. Architectural milestones

These describe what coherent system exists at each checkpoint and what property it has. They are gates beyond which a different kind of validation becomes possible, not implementation steps. Each milestone is concretely demonstrated by one or more *layer drivers* (§12) — small programs that exercise the layer in question and produce observable evidence the property holds.

### M1 — Streaming completion

The provider layer in isolation. One-shot streamed completion against Anthropic. No agentic behaviour, no tools, no harness.

M1 delivers:
- `pera_types`: the unified data model (`assistant_message_event`, `assistant_message`, `stop_reason`, `usage`, `provenance`, `tool_call`, content variants)
- `Json_schema`: runtime schema DSL with Anthropic tool-arg coercions
- `Json_repair`: port of pi's `repairJson` — fixes malformed JSON in streaming tool-call argument fragments
- `Sse_parser`: provider-agnostic Layer A — framed event extraction across chunk boundaries (stateful, buffers incomplete lines)
- `Anthropic_interpreter`: Layer B state machine — framed SSE events → `assistant_message_event` list, immutable partial snapshots per event
- `Event_stream`: generic `('event, 'result) t` Eio bounded-stream primitive with backpressure
- `Anthropic_provider`: piaf HTTP client wired through the two-layer SSE pipeline; satisfies `Provider.S`
- `provider_driver`: manual validation binary; skips with `"skipped: no API key"` when `ANTHROPIC_API_KEY` is unset

**Property:** the unified event vocabulary maps correctly to the Anthropic wire format. SSE chunk parsing handles real-world byte boundaries. The `assistant_message_event` vocabulary is adequate for the Anthropic API.

**What this validates:** the provider-as-functor design works. The two-layer SSE architecture (chunk parser + provider interpreter) is sound. Immutable partial snapshots are cheap enough to produce per-event.

**Deferred from M1.** The OpenAI-completions provider (targeting OpenCode Zen, OpenCode Go, and compatible endpoints) uses a different SSE wire format and requires its own interpreter; it is not part of this milestone. It will be introduced at M3 when the loop is wired to a real provider and multiple providers need exercising together.

### M2 — Loop verified

The agent loop wired to a scriptable faux provider; no real network. The full turn-and-hook surface is exercised.

**Property:** turn semantics are correct independent of any provider. Tool execution ordering is correct in parallel and sequential modes. Hook contract behaves as specified. Cancellation propagates as specified.

**What this validates:** the loop's purity-from-IO design lets it be tested deterministically. The hook surface is sufficient for the policies the harness will need.

### M3 — Real conversation

M2 plus a real provider connection. The agent holds multi-turn conversations with a real LLM. Still no tools.

**Property:** the seam between the agent core and the provider works end-to-end over a network. Latency, backpressure, and partial-message handling under real conditions are sound.

**What this validates:** the EventStream primitive's behaviour under realistic timing. The partial-message snapshot decision is comfortable to consume.

### M4 — Acting agent

M3 plus tools plus the execution environment. The agent can read, write, run shell, grep.

**Property:** the agent can do bounded coding work (write a file, build a project, fix a small bug). The execution environment abstracts the OS cleanly enough that tests can use a fake env.

**What this validates:** the ExecutionEnv functor design is workable. Tools-as-values composes correctly. The single-owner discipline for `agent_context` survives contact with real tool side effects.

### M5 — Auditable agent

M4 plus session logging. Every event that the agent emits is durable to disk in the JSONL tree format.

**Property:** every state change is observable after the fact. The session file is well-formed and the format is forward-compatible with future restore code.

**What this validates:** the session-as-tree design works for the write side. The harness's role as the sole observer of agent state is enforced consistently.

### M6 — Survivable agent

M5 plus compaction at Level 3 (autonomous). Sessions of any length terminate gracefully or compact themselves.

**Property:** long-running operation is reliable. Context overflow is not a failure mode for normal use.

**What this validates:** the between-turns hook coupling works for compaction. The synthetic-message rendering produces summaries the model handles well. The token estimator is conservative enough.

### M7 — Operable agent

M6 plus compaction Level 4 plus skills loading plus configuration surface (compaction model swap, tail size, threshold). The CLI is feature-complete enough for steady use.

**Property:** the agent is operationally tunable without code changes. Failure recovery during compaction is automatic.

**What this validates:** the compaction subsystem is stable under stress. The configuration surface is adequate for ops.

---

## 12. Layer drivers

### Why they exist

A strictly layered architecture creates a validation problem: how do you know each layer works *before* integrating with the layers above? End-to-end tests are valuable but they fail in ambiguous ways — a broken provider, a broken loop, and a broken harness all manifest as "the agent didn't do what I expected".

A **layer driver** is a small persistent program that exercises one layer through its real public interface, in isolation, with hand-crafted inputs. Drivers serve three roles at once:

- **Validation:** this layer works on its own with realistic inputs.
- **Examples:** here's how to use this layer from outside; reading the driver shows the consumer's view of the layer.
- **Integration probes:** if a driver becomes hard to write, or stops working when a different layer changes, the seam between layers is leaking.

A driver is distinct from a unit test. Unit tests check internal behaviour of a module and are deliberately decoupled from the full public interface; a driver exercises the public interface as an external consumer would. A driver is also distinct from an end-to-end test — those exercise the whole stack. A driver sits in the middle: one layer, in isolation, against its real seam.

A failing driver is more informative than a failing end-to-end run. "The provider driver works but the loop driver fails" points directly at the loop. "The harness driver works against `Faux_provider` but fails against the real Anthropic provider" points at the provider/loop seam. Drivers turn diffuse integration failures into precise diagnoses.

### Shape of a driver

A driver is a small program (typically 50–200 lines) that:

- Lives in the codebase as a persistent artifact (`bin/drivers/<layer>_driver.ml` or similar).
- Takes its inputs from argv, stdin, or hardcoded scenarios; not from a test framework.
- Prints structured human-readable output.
- Returns a meaningful exit code.

Drivers can be invoked manually for exploratory debugging or wrapped by automated tests that capture their output and assert against it. Both modes are valid: the former matters for "does this work?" questions during development, the latter for regression catching once the answer is "yes".

### The catalogue

| Driver | Layer | Exercises | What you learn |
|---|---|---|---|
| `provider_driver` | Provider | A real provider doing a streamed completion against a real LLM | The provider, SSE parser, and event vocabulary work end-to-end against a real wire format. Smoke-tests new models. |
| `loop_driver` | Agent core | The loop driven by `Faux_provider` against scripted scenarios | Turn semantics, hook ordering, and tool execution ordering hold. No network or filesystem required. |
| `env_driver` | Harness (env) | `Local_env`'s filesystem and shell operations one at a time | Error normalisation works; platform-specific surprises (macOS bash vs Linux bash, symlink handling, timeouts) surface. |
| `session_driver` | Harness (session) | Appending a representative sequence of entries: header, messages, compaction, synthetic, leaf | JSONL is well-formed; tree structure is visually inspectable; fsync ordering survives a kill -9. |
| `tool_driver` | Tools | Each tool called with sample args against a real env | Tools behave correctly independent of any LLM. Schema validation, truncation, output formatting. |
| `compaction_driver` | Compaction | `compact` called directly with synthetic message lists and a real model | The compaction prompt produces useful summaries on representative inputs; useful for prompt tuning. |
| `harness_driver` | Harness (assembled) | The whole harness wired to `Faux_provider`, with scripted scenarios including compaction triggers | The harness wires its dependencies correctly; the session log reflects the events; compaction triggers at the right point. |

### Faux_provider

`Faux_provider` is the load-bearing piece of driver infrastructure. It is a `Provider.S` implementation that emits a programmed sequence of `assistant_message_event`s on demand:

```ocaml
val script :
  events:assistant_message_event list ->
  final:assistant_message ->
  (module Provider.S)
```

Used by `loop_driver`, `harness_driver`, and the loop's unit tests. The scenarios it drives include: turn termination on stop, parallel tool calls, sequential tool calls, tool calls returning errors, mid-stream cancellation, thinking blocks, steering-message injection, follow-up-message handling. Each scenario corresponds to a documented expected event sequence.

`Faux_provider` is not itself a driver; it is a library component. But it is what makes everything above the provider layer testable without network IO.

### Drivers and milestones

Each architectural milestone in §11 corresponds to one or more drivers passing:

| Milestone | Drivers |
|---|---|
| M1 — Streaming completion | `provider_driver` against real Anthropic LLM |
| M2 — Loop verified | `loop_driver` (uses `Faux_provider`) |
| M3 — Real conversation | `provider_driver` + `loop_driver` wired against real providers (Anthropic + OpenAI-completions) |
| M4 — Acting agent | `env_driver` + `tool_driver` + M3 drivers |
| M5 — Auditable agent | `session_driver` + `harness_driver` (without compaction) |
| M6 — Survivable agent | `compaction_driver` + `harness_driver` (with compaction enabled) |
| M7 — Operable agent | All drivers against the configured production setup |

A milestone passes when its drivers pass *and* the property the milestone claims is observable in the driver outputs. "The agent can do bounded coding work" (M4) is observable by running `tool_driver` against `read`/`write`/`bash`/`grep` on a temp directory and verifying the files end up as expected. "Long-running operation is reliable" (M6) is observable by running `harness_driver` through a scenario that crosses the compaction threshold and verifying the session continues without an error event.

### Drivers as integration probes — what failure tells you

When writing a driver is unexpectedly hard, the seam is probably wrong. Concrete examples of the diagnostic the failure provides:

- **`loop_driver` requires knowing the on-wire LLM format to script a scenario.** The agent core's seam with the provider is leaking — scenarios should be expressible at the `assistant_message_event` level, not the wire level. Fix: tighten the provider abstraction.
- **`tool_driver` needs to construct an `agent_context` to test a tool.** The tool's seam with the loop is leaking — tools should be callable through `execute` alone, given only the execution env and arguments. Fix: review tool dependencies; remove the implicit loop coupling.
- **`harness_driver` requires mocking HTTP.** The harness is reaching past the loop to the provider. Fix: ensure the harness only sees the loop's `stream_fn` callback, which can be supplied by `Faux_provider`.
- **`env_driver` needs to construct file paths matching a specific harness convention.** The harness is making assumptions about path formats rather than going through the env's `absolute_path` / `join_path`. Fix: route path construction through the env.
- **`compaction_driver` cannot be written without instantiating a full harness.** Compaction has hidden dependencies on session state or hooks. Fix: extract the pure compaction algorithm so it takes message-list-in, summary-out, and lift the integration concerns into a separate harness binding.

These failure modes are how layering discipline is enforced. Without drivers they would surface only when a real integration is attempted, often weeks after the abstraction broke.

### Drivers and the test pyramid

Drivers do not replace unit tests, end-to-end tests, or property tests; they sit alongside them.

- **Unit tests** check internal behaviour (e.g. the SSE chunk parser correctly handles split events; the JSON Schema validator rejects malformed input). They are fast, numerous, and decoupled from public interfaces.
- **Drivers** check that a layer holds together through its public interface. They are slower, fewer (one or two per layer), and explicitly coupled to public interfaces.
- **End-to-end tests** exercise the full stack against a real LLM. They are slowest, fewest, and gate releases.

A change that breaks a driver should rarely break unit tests (the unit-level surface didn't change) and shouldn't necessarily reach end-to-end before being noticed. That separation of failure signal is what makes drivers worth maintaining.

---

## 13. Open design questions

These are design-level. Each affects the architecture's shape and should be settled before commitments harden.

1. **The `prepare_next_turn` / `should_stop_after_turn` split.** Pi separates these; the port follows for parity. They could be merged into one hook returning `[\`Continue of snapshot option | \`Stop]`. The merged form is more honest about what `should_stop_after_turn` does (its closure can have side effects), but the split form makes the side-effect-free predicate obvious. Recommend: keep the split; document the side-effect-via-closure pattern.

2. **The Agent wrapper's status.** Spec includes it; the alternative is to fold subscription into the harness directly. The wrapper makes future UI layers cleaner and gives single-flight enforcement. Folding into the harness means one fewer abstraction but couples future UI to the harness. Recommend: keep the wrapper.

3. **Compaction prompt evolution.** The hardcoded prompt is adequate for v1. A v2 might want per-project prompts, per-model prompts, or user-overridable prompts. The migration path is the template subsystem. The question is whether the v1 prompt is structured enough to migrate cleanly — i.e., whether its purpose can be expressed as template metadata. Current prompt is plain text; migration is straightforward.

4. **Synthetic-message framing.** The user-role compaction message is framed as `"Context from earlier conversation:\n\n"`. Alternative framings perform differently with different models. The choice is partly empirical. The spec picks one; the architecture permits the framing to be a property of the compaction prompt template (so it varies with the prompt), but v1 hardcodes both.

5. **Tool execution mode defaults.** `bash` is Sequential; others Parallel. `write` is Parallel by default in pi, but two writes to the same path race — the spec sets `write` to Sequential. The deeper question is whether per-tool-call resource declarations (this `write` touches `/foo`, this one `/bar`, so parallel is safe) would be worth the complexity. Recommend: not in v1; per-tool default is good enough.

6. **Cancellation granularity within tool execution.** A long-running `bash` invocation receives cancellation at the next async point — possibly a long time if blocked on a subprocess. The Eio answer is to wrap the process in a cancellable wait. The spec does that for `bash`; other tools are short enough that next-async-point is fine.

7. **The session file's relationship to the working directory.** Sessions are tied to a cwd recorded in the header. What happens if the user changes cwd mid-session (via a `bash` `cd`)? Pi's behaviour: the session continues; the recorded cwd is stale. The spec inherits this. A cleaner design would record cwd changes as session entries, but that requires intercepting shell cwd changes (impossible in general). Recommend: accept staleness; cwd metadata documents the session's start, not a live property.

8. **OpenCode vs OpenCode Zen as separate providers.** The compatibility-record approach treats them as configurations of one provider. The alternative — separate modules — would be cleaner for code search but duplicates near-identical code. Recommend: the compat-record approach.

9. **Immutability consistency.** The spec argues immutable snapshots are cleaner than the TS approach for `AssistantMessageEvent`. The same question applies to `agent_event.message_update`. Recommend: stay consistent — immutable everywhere. The cost is allocation; the benefit is no snapshot-clone trap.

10. **The `parent_session` header field.** Records an optional parent session id, supporting "fork this session into a new file." v1 does not implement forking. Question: include the field if unused? Recommend: include; the format is forward-compatible and the cost is one optional field.

11. **The `Http_client` abstraction.** `Anthropic_provider` currently calls piaf directly (`Piaf.Body.fold_string`, `Piaf.Error.to_string`). These calls are confined to the Anthropic provider module and do not leak through `Provider.S`, but swapping HTTP clients would require touching the provider internals. An `Http_client` module type with `type body`, `fold_body_string`, and `error_to_string` would insulate providers from the HTTP library choice. The question is whether this abstraction is worth its weight: there is only one plausible HTTP client for Eio (piaf), and the coupling is well-bounded. Recommend: introduce `Http_client` before M3 when the OpenAI-completions provider is added — two providers sharing one HTTP adapter justifies the abstraction; one provider does not.

---

*End of architectural specification v0.5.*
