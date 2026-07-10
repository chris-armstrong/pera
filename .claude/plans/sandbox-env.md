# Sandbox Execution Environment — Planning Document

**Status**: Stage 0 (persistent shell) plan finalized — ready for implementation.
Phase 1 (OS sandbox) and Phase 2 (path remapping) remain research-level and are
kept below as reference; they are not being executed yet.
**Date**: 2026-07-01 (revised 2026-07-03, restructured 2026-07-05)
**Branch**: bridge-cse_01MY3dfGCqYK38hRssgyFdfV

---

## Goal

Add a sandbox execution environment: a long-running shell process (inside a namespace
container or OS sandbox) whose state (cwd, env vars, shell functions) is preserved across
tool calls. This differs from the current `Local_env`, which spawns a fresh `/bin/sh -c`
process per call.

### Key requirements

1. **Shell state preserved** — `cd`, `export`, `alias`, etc. survive across consecutive
   bash tool calls within a session. (Persistent shell is the **default**, even without
   sandboxing.)
2. **Filesystem isolation** — the sandboxed shell gets a fresh home directory; it cannot
   write to the real `$HOME` unless explicitly permitted. *(Phase 1.)*
3. **Containment by default** — the writable surface defaults to the current git checkout
   root. Applies to both the shell and the `read`/`write`/`grep` tools. *(Phase 1.)*
4. **Configurable environment** — env var passthrough / startup script. *(Stage 0 ships the
   startup-script/env-passthrough plumbing point; secret-aware handling is Phase 1.)*
5. **macOS + Linux support** — different isolation backends, same `Execution_env.S`
   interface; user-facing switch is a plain on/off. *(Phase 1.)*
6. **Hard-fail on misconfiguration** — no silent fallback to no-sandbox. *(Phase 1.)*

### Phasing

- **Stage 0 (this plan, ships first)**: persistent shell as the default execution env
  (`/bin/bash` only, no OS sandbox); `is_stateful` flag on `SHELL`; cwd-override fix in
  tools; post-command state snapshot for crash recovery; SIGINT+grace timeout;
  restart-notice surfaced to the agent. Zero new OS dependencies.
- **Phase 1 (after Stage 0)**: refactor `Execution_env.S` construction so `Fs` is
  substitutable without changing the interface; ship an identity `Fs` (host paths, no
  remapping) with a containment gate; `--sandbox`/`--no-sandbox`; OS backends (bwrap on
  Linux, sandbox-exec on macOS); hard-fail on missing backend.
- **Phase 2 (later, additive)**: path remapping (`workdir_mount = At sandbox_path`) via a
  drop-in `Path_mapping_fs` wrapper.

Phase 1 and Phase 2 design notes, the industry/technology survey, and the secret-injection
design are preserved in full under **[Reference: Phase 1+ design](#reference-phase-1-design-not-in-scope-for-stage-0)**
at the bottom of this document — nothing from the earlier research was dropped, it's just
out of the way of the part that's actually being built now.

---

## Current architecture context (verified against the tree, 2026-07-05)

### `Execution_env.S` (`lib/pera_env/execution_env.mli`)

```ocaml
type exec_result = { stdout : string; stderr : string; exit_code : int }

module type SHELL = sig
  val exec :
    command:string ->
    ?cwd:string ->
    ?env:(string * string) list ->
    ?timeout:float ->
    ?on_stdout:(string -> unit) ->
    ?on_stderr:(string -> unit) ->
    sw:Eio.Switch.t ->
    cancel:Eio.Cancel.t ->
    (exec_result, Pera_types.Types.execution_error) result

  val find_executable : name:string -> string option
end

module type S = sig
  val cwd : string
  module Fs : FILESYSTEM
  module Sh : SHELL
end
```

Two things worth calling out because they change the shape of Stage 0 versus the earlier
draft of this plan:

- **`on_stdout`/`on_stderr` streaming callbacks already exist** in the signature today.
  `Local_env.Sh.exec` (`lib/pera_env/local_env.ml:109-176`) already spawns the child with
  two pipes and reads them **concurrently** via `Eio.Fiber.all`, calling the callbacks per
  chunk as it goes. The three-fd sentinel protocol below is additive to this, not a new
  pattern — it reuses the same "one fiber per fd" shape.
- **`exec_result` has no timestamped/tagged chunk list today.** Adding one (for
  wall-clock-order reconstruction across stdout/stderr) is a breaking change to a shared
  record type. The blast radius is small and fully enumerated in Stage 0 below.

### Critical current issue: cwd is not preserved

`bash_tool.ml:57` passes `?cwd:(Some E.cwd : string option)` on every call.
`grep_tool.ml:107-116` resolves a cwd then passes it via `~cwd` on every call. Both override
cwd on *every* `Sh.exec` call — even with a persistent shell, the cwd would never actually
move. The fix is **removal**: when `E.Sh.is_stateful`, don't pass `?cwd` at all, and let the
shell own its own cwd.

### Where env is created

`pera_cli/pera_cli.ml`, function `resolve_exec_env` (`pera_cli.ml:249`), builds the
`(module Execution_env.S)` passed into `Agent_harness.config.exec_env`. This is the
injection point for swapping `Local_env` for a persistent-shell-backed env.

### `Agent_harness` / `Agent_wrapper` layering (relevant to the restart-notice design below)

Package dependency graph (from `AGENTS.md`, confirmed against `dune` files):

```
pera_types (no internal deps)
pera_provider, pera_env  (→ pera_types)
pera_core                (→ pera_types, pera_provider — NOT pera_env)
pera_tools               (→ pera_types, pera_env, pera_core, pera_provider)
pera_agent, pera_cli     (→ everything)
```

`pera_core` does **not** depend on `pera_env`, and `agent_event` is defined in
`lib/pera_core/agent_types.mli` (not `pera_types`, contrary to an earlier draft of this
plan). This matters: a `Persistent_shell` value living in `pera_env` cannot construct or
emit an `Agent_types.agent_event` itself — that type isn't visible from `pera_env`.
`Agent_harness.subscribe` (`lib/pera_agent/agent_harness.mli:63`) is also one-directional:
it lets external code *observe* events the loop already emitted; there is no
`publish`/`inject` entry point to push a synthetic event into the fan-out from outside a
running turn. See **Stage 1** below for the corrected design (tool-output notice instead of
a new `agent_event` variant).

---

## Settled design decisions (Stage 0 scope)

1. **Persistent shell is the default**, on by default even without OS sandboxing.
   `--no-persistent-shell` opts out to today's stateless `/bin/sh -c`-per-call model, for
   debugging/CI. (Flag name corrected to match the existing negative-flag convention —
   see `--no-compact` in `cli_args.ml` — rather than a `--persistent-shell=false` form.)
2. **cwd/env override removal now.** `bash_tool.ml` / `grep_tool.ml` stop passing `?cwd`
   when `E.Sh.is_stateful`. Not deferred — this is the entire point of Stage 0.
3. **State-capture mechanism: a real bash subprocess**, controlled via a three-channel
   sentinel protocol (stdout/stderr/state, harness-side timestamps), not an embedded shell
   interpreter library or platform-specific introspection. Two alternatives were evaluated
   and rejected:
   - **[merry](https://tangled.org/patrick.sirref.org/merry)** (OCaml shell library,
     introspectable state) — rejected: no working job control (`fg`/`bg`/`jobs` are
     reserved words with no implementation), `&` background jobs are explicitly
     disabled/broken per its own TODO, and its POSIX reference implementation was deleted
     from its tree the day before this evaluation (single-maintainer, pre-alpha, `dune
     build` fails out of the box). Job control is a hard minimum for a shell substitute.
   - **Platform-specific introspection** (`/proc/<pid>/environ`, bash loadable builtins via
     `enable -f`) — rejected: pera's cross-platform bar is macOS + Linux, and both
     alternatives are Linux-only or require maintaining a compiled shim per OS/arch (plus
     macOS notarization concerns) for a benefit — avoiding one `declare -px` round-trip —
     that the fd-3 side channel already gets for free as pure Eio pipe plumbing on both
     OSes.
4. **No `2>&1` stream merging.** Three independent channels (stdout fd 1, stderr fd 2,
   private state fd 3), each with its own sentinel. A real interactive shell already keeps
   stdout/stderr distinct — `2>&1` would have been the artificial addition, not the
   default. Merging at the shell level throws away the stream tag before the harness ever
   sees two streams and forecloses separating them later. True interleaving is
   reconstructed harness-side via per-line timestamps, which is strictly better than the
   shell-side merge (which was also only an approximation of interleaving).
5. **Shell selection**: `/bin/bash` first, falling back to `/bin/sh` if bash is absent.
6. **Snapshot/replay is filtered and non-authoritative for secrets** even in Stage 0: the
   snapshot captures *all* exported vars for now (no allowlist enforcement — there's no
   security boundary to protect before `--sandbox` exists), but it is stored **host-side,
   in pera-cli memory only** — never as a file the agent's `read` tool could reach. This
   guards against the worst outcome (a sandboxed agent reading its own leaked STS/OAuth
   tokens back out of a snapshot file) even before Phase 1's allowlist lands.
7. **`source` invocations are never replayed**, only recorded-as-absent. Replaying a
   sourced script has unpredictable side effects (venv creation, network calls, interactive
   auth) — the agent is notified of the restart and re-sources manually.
8. **Crash notification is a tool-output notice, not a new `agent_event`.** See Stage 1 for
   why (layering) and the corrected mechanism.
9. **Shell lifecycle is scoped to the CLI process, not the session.** The persistent shell
   is created once when the CLI process starts and closed when it exits — it is bound to
   the top-level `Eio.Switch.t` the CLI already owns, the same one everything else in the
   process's lifetime is scoped to. There is no independent "keep the shell alive in the
   background after the CLI exits" mode. Restarting `pera` against the *same* session file
   always starts a **fresh, empty shell** (no cwd, no exported vars, no functions) — Stage
   0 does not attempt to reattach to, or reconstruct, a previous process's shell. Session
   **resume** (loading a prior session's conversation into a new CLI invocation) does not
   exist yet; when it ships, it will go through this same "fresh shell" path, since there
   is no live process to reattach to across invocations. Whether resume should *also*
   replay the last-known snapshot (the same mechanism Stage 1 builds for crash recovery,
   just triggered by "new process, old session" instead of "shell died mid-process") is an
   open question to revisit once resume itself is designed — see the note under Stage 1
   and in "What Stage 0 does NOT include" below. Nothing in Stage 0 blocks that choice
   either way: the snapshot already lives host-side in pera-cli memory, not tied to the
   shell process, so it's available to whatever resume path is eventually built, but Stage
   0 does not persist it to disk or wire it up.

---

## Stage map

| Epoch | Stage | Title | Package | Depends |
|---|---|---|---|---|
| 0 | 0 | Persistent shell core: spawn + three-channel sentinel protocol | `pera_env` | — |
| 0 | 1 | Timeout, crash detection, state snapshot/restart, agent notification | `pera_env` | 0 |
| 0 | 2 | Tool & config wiring: `is_stateful`, `bash_tool`/`grep_tool` cwd fix, config + CLI flag | `pera_env`, `pera_tools`, `pera_cli` | 1 |
| 0 | 3 | Integration test suite for shell persistence | `pera_env` (test) | 0, 1, 2 |
| 1 | 4 | `Fs` substitution + containment gate + `Sandbox_env` (bwrap / sandbox-exec) | `pera_env`, `pera_cli` | 0–3 |
| 2 | 5 | Path remapping (`Path_map` + `Path_mapping_fs`) | `pera_env` | 4 |

Build stays green after every stage. Stages 0–2 add capability with no behaviour change
until `--no-persistent-shell` is *not* passed (i.e. Stage 2 flips the actual default).
Epoch 0 (stages 0–3) is the fully detailed plan below; Epochs 1–2 remain at survey/design
depth in the reference section until they're scheduled.

---

## Epoch 0 — Persistent shell

### Stage 0 — Persistent shell core: spawn + sentinel protocol

**Goal:** a `Persistent_shell.t` that spawns one long-lived `/bin/bash` (fallback
`/bin/sh`) wired to three pipes, and an `exec` that runs one command to completion using
the per-fd sentinel protocol. No crash recovery, no timeout handling, no tool wiring yet —
just prove the protocol round-trips correctly under concurrency.

**Files to create**

- `lib/pera_env/persistent_shell.mli`
- `lib/pera_env/persistent_shell.ml`

**Files to modify**

- `lib/pera_env/dune` — add `persistent_shell` to `(modules ...)`
- `lib/pera_env/execution_env.mli` / `.ml` — extend `exec_result` (see below)

#### `exec_result` extension

```ocaml
type output_stream = Stdout | Stderr

type output_chunk = {
  stream : output_stream;
  timestamp : float;  (* Eio.Time.now, read-time not produce-time — see limitation below *)
  line : string;
}

type exec_result = {
  stdout : string;         (* flattened, unchanged — back-compat *)
  stderr : string;         (* flattened, unchanged — back-compat *)
  exit_code : int;
  chunks : output_chunk list;  (* ordered per stream; merge-sort by timestamp for interleaving *)
}
```

This is an additive field on a shared record, which means it breaks every **construction**
site (field access and pattern matches with `; _` are unaffected). Full enumerated blast
radius (verified via `grep -rl exit_code lib/ bin/`):

| File | What changes |
|---|---|
| `lib/pera_env/execution_env.ml` / `.mli` | Type definition — add `output_stream`, `output_chunk`, `chunks` field |
| `lib/pera_env/local_env.ml:161-168` | The one production construction site — add `chunks = [ { stream = Stdout; timestamp = <now>; line = Buffer.contents stdout_buf } ; { stream = Stderr; ... } ]` (or simpler: `chunks = []`, since `Local_env` has never supported interleaving reconstruction and nothing consumes `chunks` yet — decide based on whether Stage 3 tests want `Local_env` coverage of the merge-sort helper) |
| `lib/pera_env/test/local_env_sh_test.ml:36` | Test helper constructs an `exec_result` — add the field |
| `lib/pera_cli/pera_cli.ml`, `lib/pera_cli/shell_tool_builder.ml`, `lib/pera_tools/{bash,grep}_tool.ml` | Read-only consumers (`.stdout`/`.stderr`/`.exit_code`) — unaffected |

Decision needed before implementation: does `Local_env` populate `chunks` for real (so the
merge-sort helper has two real implementations to test against) or leave it `[]` (since
`Local_env` is non-stateful and being phased toward parity anyway)? Recommendation: populate
it — it's nearly free (the buffers already exist) and gives Stage 3's interleaving test a
non-persistent-shell baseline to compare against.

#### `Persistent_shell` interface

```ocaml
(** A long-lived shell process that preserves state (cwd, env, functions,
    aliases, options) between [exec] calls. *)

type t

val create :
  proc_mgr:Eio.Process.mgr ->
  clock:Eio.Time.clock ->
  sw:Eio.Switch.t ->
  env:string array ->  (* env vars for the shell process itself *)
  cwd:string ->        (* initial working directory *)
  t
(** Spawns [/bin/bash] (falling back to [/bin/sh] if absent), wired to three
    pipes (stdout, stderr, a private state channel on fd 3). Blocks briefly on
    a startup sentinel to confirm the shell is ready before returning. The
    shell process's lifetime is tied to [sw]: register [close] via
    [Eio.Switch.on_release sw] (or an equivalent finally/cleanup) so the shell
    is torn down when [sw] — the CLI's top-level switch — finishes, i.e. when
    the CLI process exits. There is no path that keeps the shell alive past
    that; a later invocation of [pera], even against the same session file,
    calls [create] again and gets a brand-new, empty shell. *)

val exec :
  t ->
  command:string ->
  ?on_stdout:(string -> unit) ->
  ?on_stderr:(string -> unit) ->
  sw:Eio.Switch.t ->
  cancel:Eio.Cancel.t ->
  (Execution_env.exec_result, Pera_types.Types.execution_error) result
(** Sends [command] to the persistent shell and reads back the result. Spawns
    two reader fibers (stdout, stderr) each waiting on its own per-call
    sentinel, plus a third fiber draining the fd-3 state channel (see Stage
    1). Every line is timestamped as it is read. No [?cwd]/[?env] params —
    unlike [Local_env.Sh.exec], a stateful shell owns its own cwd/env; see
    Stage 2 for how callers adapt. *)

val close : t -> unit
(** Sends ["exit"] to the shell and waits for it to terminate. *)
```

Note `exec` above intentionally drops `?cwd`/`?env`/`?timeout` relative to the `SHELL.exec`
signature — timeout is added in Stage 1 (it's entangled with crash detection), and
`?cwd`/`?env` are permanently absent because a stateful shell doesn't accept per-call
overrides (Stage 2 wires `Sh.exec` to just ignore/warn if a caller ever passes them, via
`is_stateful`).

#### Protocol

Per `exec` call:

1. Generate a unique sentinel: `SENTINEL = "PERA_DONE_" ^ uuidv4_hex ()`.
2. Write to the shell's stdin:
   ```
   ( <user_command> )
   printf '\n' 1>&1; printf '\n' 1>&2
   echo "$? $SENTINEL" 1>&1
   echo "$SENTINEL" 1>&2
   ```
3. Read stdout and stderr **concurrently** (`Eio.Fiber.all`, one fiber per fd), each
   line-by-line until its own sentinel line arrives (`"<exit_code> <SENTINEL>"` on stdout,
   bare `"<SENTINEL>"` on stderr). Bash only reaches the `echo ... $SENTINEL` lines after
   the subshell and everything it forked has fully exited, and pipe writes/reads are
   ordered per fd — so seeing a fd's sentinel guarantees that fd's output for this command
   is fully drained. No merge is needed to know completion.
4. Each line is timestamped independently (`Eio.Time.now clock`) as it's read.
5. Strip the sentinel lines; return `exec_result` with flattened `stdout`/`stderr` (for
   compatibility) plus the ordered `chunks` list.

Wrapping in `( ... )` makes the subshell's exit code reflect `<user_command>` specifically
(not the trailing `echo`s). The UUID sentinel makes collisions with command output
astronomically unlikely on either stream.

**Known limitation (accepted, documented, not new):** many programs fully block-buffer
stdio when fd 1/2 is a pipe rather than a tty, so a captured timestamp means "when the
harness received the flushed chunk," not the instant it was produced. True of today's
`Local_env` pipe capture too. Not solved in Stage 0 (pty allocation via `openpty` is a
Phase 1 candidate — see the reflection under Stage 3 on why this is more than a
timestamp-fidelity footnote).

**Streaming note:** `?on_stdout`/`?on_stderr` are threaded through from day one (they
already exist on `SHELL.exec` and `Local_env` already calls them per-chunk) — Stage 0
should call them per non-sentinel line as it's read, not only accumulate into buffers. This
isn't deferred functionality, it's the natural shape of the per-fd reader loop.

#### Tests (Stage 0)

New `lib/pera_env/test/persistent_shell_test.ml` (alcotest, needs `Eio_main.run` /
`Eio_mock` fixtures — mirrors `local_env_sh_test.ml`'s harness):

- Basic round-trip: `echo hello` → stdout captured, exit 0.
- Exit code propagation: `exit 7` inside `( ... )` → `exit_code = 7`.
- stdout/stderr both populated, correctly tagged, from a single command
  (`echo out; echo err 1>&2`).
- cwd persists across two `exec` calls (`cd /tmp` then `pwd`) — this is the core Stage-0
  win; it can't be fully exercised until Stage 2 removes the tool-level override, but the
  `Persistent_shell` unit itself should prove it here.
- `export FOO=bar` in one call, `echo $FOO` in the next — env persists.
- Sentinel collision resistance: command that `echo`s a string matching the
  `PERA_DONE_*` pattern shape but with a different UUID — must not terminate the read
  early.
- Multi-MB output on one fd while the other fd is idle — no pipe backpressure deadlock
  (validates the concurrent-reader design, not just the happy path).

---

### Stage 1 — Timeout, crash detection, snapshot/restart, agent notification

**Goal:** make the shell resilient — SIGINT+grace timeouts, detect an unexpected shell
exit, restart it, replay as much state as safely possible, and surface the fact of the
restart to the agent through the conversation (not just to a host-side observer).

**Files to modify**

- `lib/pera_env/persistent_shell.{ml,mli}` — add `?timeout`, crash detection, snapshot,
  restart, and an `on_restart` callback param
- `lib/pera_types/types.ml` / `.mli` — **no change** (corrected from the earlier draft —
  see below)

#### Timeout: SIGINT + grace

On timeout expiry:

1. Send **SIGINT** to the shell's process group (stops the running subprocess; the shell
   itself typically survives).
2. Continue reading **both** sentinel loops (stdout and stderr) for a **5s grace period**.
3. If both sentinels arrive within grace → return the (interrupted) result normally.
4. If either is still missing when grace expires → send **SIGKILL** to the shell process
   and enter the crash-restart path below.

Waiting on *both* fds (not just one) matters now that stdout/stderr aren't merged: a
command can finish writing to one stream well before the other. A timeout does not
necessarily kill the shell — SIGINT may stop only the running child while bash itself
stays alive and stateful.

#### State snapshot: out-of-band, same round-trip, fd 3

Rather than a second stdin/stdout exchange after every command (doubling latency), the
snapshot rides the private state channel opened at spawn time, appended to the *same*
wrapper send as the command:

```bash
{ declare -px ; declare -f ; alias -p ; shopt -p ; set +o ; pwd ; echo "$SENTINEL" ; } 1>&3
```

Snapshot set and rationale:

- `declare -px` — exported env vars
- `declare -f` — shell functions
- `alias -p` — aliases (not covered by `declare` — needed for coherence)
- `shopt -p` — shell options (e.g. `globstar`, `nullglob`)
- `set +o` — `set` options
- `pwd` — cwd, replayed as `cd`

The fd-3 reader is its own fiber and does **not** gate the tool call's return to the
caller — the result comes back as soon as the stdout/stderr sentinels land; the snapshot
updates shortly after, once its own sentinel lands on fd 3. **The captured snapshot is
held in pera-cli memory only** (never written to a file inside any agent-readable view) —
this is the Stage-0-relevant slice of the credential-leak mitigation from the original
research (full mitigation, including allowlisting, is Phase 1, since there's no sandbox
boundary yet to protect against). For Stage 0, the snapshot captures *all* exported vars
unfiltered; that's fine as a fidelity trade-off precisely because it never touches disk or
an agent-visible path.

**What the snapshot does NOT cover (documented gap, kept simple by design):**

- Traps (`trap`), background jobs, the directory stack (`pushd`/`popd`), `PIPESTATUS`,
  `BASH_REMATCH`.
- `source` invocations — replaying side effects (venv creation, network calls, interactive
  auth) is out of scope; the agent is notified and re-sources manually (decision 7 above).
- State accumulated since the last completed command (in-flight commands are lost on
  crash).

#### Restart procedure

1. Detect EOF on stdout, stderr, or fd 3 (shell died), or SIGKILL after grace expiry.
2. Spawn a fresh bash.
3. Source the last-known snapshot into it (env, functions, aliases, options), then `cd` to
   the recorded pwd.
4. Invoke the `on_restart` callback (see below) with `~state_restored:(<snapshot existed>)`.
5. Return `Error execution_error` for the command that was in flight at crash time — the
   caller (bash_tool) is responsible for surfacing this, plus the fact of the restart, in
   its tool output (see Stage 2).

#### Corrected notification design (was: new `agent_event` variant)

The earlier draft of this plan proposed adding `Shell_restarted of { state_restored : bool
}` to `agent_event` in `lib/pera_types/types.ml`, reusing `Agent_harness.subscribe`. Two
problems, found by checking the actual tree:

- `agent_event` is defined in `lib/pera_core/agent_types.mli`, not `pera_types` — and
  `pera_core` has **no dependency on `pera_env`** (confirmed via `dune` files). A
  `Persistent_shell` value in `pera_env` cannot construct a `pera_core` type.
- Even fixed to the right file, `subscribe` is one-directional — a way for *external* code
  (the CLI renderer) to observe events the loop already emitted, not a way to *inject* a
  synthetic event into the fan-out from outside a running turn. A shell crash can happen
  between turns, so there's no "current emit context" to route it through short of
  reproducing M6's `synthetic`-message/`should_stop_ctx.emit` machinery — disproportionate
  plumbing for what is, functionally, one line of tool output.

**Corrected design:** `Persistent_shell.exec` takes an `on_restart` callback
(`state_restored:bool -> unit`) supplied at `create` time; `bash_tool.ml` wires this to
prepend a notice to the tool's returned text content on the call where a restart was
detected, e.g.:

```
[shell restarted after unexpected exit; state_restored=true — cwd and env vars were
recovered, but traps, background jobs, and any prior `source` are not; re-run those if
needed]

<normal command output follows>
```

This reaches the agent through the **existing** tool-output → `AE_tool_execution_end` →
conversation-history path with zero new cross-layer plumbing, and the CLI's
`event_renderer.ml` already renders tool output, so the user sees it too for free. No
`pera_types`/`pera_core` change is needed for Stage 0. (If a dedicated `agent_event` is
wanted later for structured logging/telemetry, it can be layered on top in `pera_agent` —
which *does* depend on both `pera_env` and `pera_core` — without touching `pera_env`.)

#### Tests (Stage 1)

Extends `persistent_shell_test.ml`:

- `sleep 100` with a short timeout → SIGINT sent, shell survives, next command runs in the
  same cwd.
- A command that traps and ignores SIGINT, and an orphaned grandchild that ignores SIGINT
  → validates the SIGKILL fallback after grace.
- Bare `exit` → restart detected, `on_restart` fires with `state_restored` reflecting
  whether a snapshot existed yet.
- `exit 0` inside a sourced script; `kill -SEGV $$`; `kill -9` mid-command → same restart
  path, in-flight command surfaces as `Error`, not a hang.
- Snapshot fidelity: export/function/alias/`shopt`/`set -o` all survive crash+restart.
- **Negative case:** a `trap` set before the crash is *not* restored — assert it's actually
  gone post-restart, not flaky.
- `on_restart` callback correctly receives `state_restored:false` if the shell dies before
  any snapshot round-trip has completed.

---

### Stage 2 — Tool & config wiring

**Goal:** flip the actual default. Add `is_stateful` to `SHELL`, remove the cwd override in
`bash_tool`/`grep_tool` when stateful, wire config + a CLI flag, and construct
`Persistent_shell` from `pera_cli.ml`.

**Files to modify**

- `lib/pera_env/execution_env.mli` — add `val is_stateful : bool` to `SHELL`
- `lib/pera_env/local_env.ml` — `Sh.is_stateful = false` (no behaviour change)
- `lib/pera_tools/bash_tool.ml:57` — see below
- `lib/pera_tools/grep_tool.ml:107-116` — see below
- `lib/pera_cli/pera_config.ml` — new field on `config` (see below)
- `lib/pera_cli/config_resolver.ml` — resolve the new field
- `lib/pera_cli/cli_args.ml` — new flag
- `lib/pera_cli/pera_cli.ml` (`resolve_exec_env`, `pera_cli.ml:249`) — construct
  `Persistent_shell`-backed `S` when enabled

#### `bash_tool.ml` / `grep_tool.ml` change (the fix = removal)

```ocaml
let cwd_arg = if E.Sh.is_stateful then None else Some E.cwd in
E.Sh.exec ~command ?cwd:cwd_arg ...
```

`grep_tool.ml`'s `E.Fs.absolute_path "."`-then-`~cwd` path (lines 107–116) gets the same
treatment: for a stateful shell, let the shell's own cwd stand instead of resolving and
passing one.

#### `pera_config.ml` — matching the existing option-field convention

The doc's earlier draft proposed `persistent_shell : bool [@sexp.default true]` directly on
`config`. The actual codebase convention (confirmed against `compaction`, `cache`,
`session`, etc. in `pera_config.ml`) is `_ option [@sexp.option]` on the raw config, with
the default applied in `config_resolver.ml` via `Option.get_or` (never `Option.get` — it's
semgrep-banned). Mirroring that:

```ocaml
(* pera_config.ml, on the config record *)
persistent_shell : bool option; [@sexp.option]
```

```ocaml
(* config_resolver.ml, alongside resolve_compaction *)
let persistent_shell =
  Option.get_or ~default:true merged.Pera_config.persistent_shell
in
```

#### CLI flag — matching the existing negative-flag convention

`cli_args.ml` already has `no_compact` (`--no-compact`, a plain `Arg.flag`) for exactly
this "on by default, opt out" shape — mirror it rather than inventing a
`--persistent-shell=true|false` boolean-valued flag:

```ocaml
let no_persistent_shell =
  Arg.(
    value & flag
    & info [ "no-persistent-shell" ]
        ~doc:"Disable the persistent shell; use a fresh /bin/sh -c per command.")
in
```

Threaded through `build_args` and the CLI record the same way `no_compact` is.

#### `pera_cli.ml` wiring

`resolve_exec_env` picks `Persistent_shell` unless `no_persistent_shell` (CLI) or
`persistent_shell = false` (resolved config) is set, in which case it falls back to
today's `Local_env`. No `--sandbox` flag exists yet in Stage 0 (Phase 1).

#### Tests (Stage 2)

- Direct regression test for the Stage-0 core fix: `cd /some/dir` in one `bash` tool call,
  then a relative-path command in the next tool call, resolves against the new cwd — not
  the original `E.cwd`.
- `cd` into a directory then `rm -rf` it from within the same shell session (validates
  nothing in the tool layer re-injects a stale/absolute cwd behind the shell's back).
- `--no-persistent-shell` reverts to `Local_env` semantics (cwd does *not* persist) — a
  negative test proving the escape hatch actually works.
- `grep` tool call after a `cd` in a prior `bash` call searches the new cwd, not the
  original one.

---

### Stage 3 — Integration test suite for shell persistence

**Goal:** the concurrency/crash/snapshot categories from stages 0–2 need Eio-level control
(background jobs holding a pipe open, signals, races), not just shell one-liners, so this
is its own stage rather than an afterthought.

**Files to create**

- `lib/pera_env/test/persistent_shell_concurrency_test.ml` (or fold into
  `persistent_shell_test.ml` if it doesn't get unwieldy — call it during implementation)
- `lib/pera_env/test/fixtures/` — small shell snippets for the cross-shell smoke test, if
  the oils-style fixture-directory approach is used

#### Two test axes (important scope split — carried over from the original research)

Stage 0 only ever spawns **bash** (falling back to `/bin/sh`) as the *outer* persistent
process — zsh/dash/fish are never the wrapper's own interpreter in this design. "Test
across bash/zsh/dash/fish" splits into two axes with very different payoff:

1. **Outer-shell axis** (forward-looking only — matters solely if the wrapper is ever made
   to run the user's `$SHELL` instead of a hardcoded bash). `fish` is not POSIX: `( cmd )`
   means command substitution not a subshell, `$?` doesn't exist (`$status` does), and
   `echo "$? $SENTINEL"` is invalid fish syntax outright. Not applicable today; smoke-test
   the emission snippet against `dash`/`zsh` cheaply as insurance (see matrix below), skip
   `fish` entirely for Stage 0.
2. **Inner/nested-shell axis** (relevant *today*). The agent's commands, run inside the one
   persistent bash, can invoke `zsh -c`, `fish -c`, `dash script.sh`, subshells, background
   jobs, another REPL, `ssh`, etc. This is where concurrency/subshell interference actually
   bites Stage 0, and is the higher-priority axis.

#### Reflection carried over: no PTY is a correctness risk, not just a timestamp footnote

Absence of a PTY changes whether whole classes of commands work at all:

- Programs that branch on `isatty(1)`/`isatty(0)` change behavior under a pipe (`git` drops
  color/pager; `pip`/`npm`/`docker pull` progress bars degrade or spam newlines;
  interactive installers like `npm init`, `gh auth login`, `aws configure sso` may refuse
  to run or hang waiting on input that can never arrive).
- `sudo` (with `requiretty`), `ssh` password prompts, `gpg`/`pinentry` **deliberately
  refuse piped stdin** for credential entry — these hang until timeout rather than failing
  fast.
- No controlling tty means no `SIGWINCH`, no real job-control signal semantics
  (`Ctrl-Z`/`SIGTSTP`, `fg`/`bg`).
- Nothing stops an agent from independently running `aws sso login` or `gh auth login`
  directly in the persistent shell (the harness-side `refresh_credentials` tool from the
  Phase 1+ secret-injection design sidesteps this for the *built-in* flow, but not for an
  agent freelancing the same command itself); that path will hang with no pty.

**Recommendation carried into this plan:** treat "requires a tty" as a named, tested
failure class for Stage 0 — test that it hangs *safely* and recovers via the Stage-1
SIGINT+grace+timeout path, not that it's supported. Promote pty allocation (`openpty`) from
"possible future improvement" to an early Phase 1 candidate.

#### Test matrix

| Category | Scenarios | Why it can break the wrapper |
|---|---|---|
| Sentinel correctness | Adversarial echo of a `PERA_DONE_*`-shaped string; partial line then hang; no trailing newline before exit; empty/whitespace-only command | False sentinel match ends the read early, or never matches |
| Subshells & grouping | `( cd /tmp && pwd )` (must not leak cwd to parent); `{ cmd; }`; `cmd1; cmd2 &` outliving the sentinel; `nohup long &`; `disown` | A backgrounded job can inherit the write end of stdout/stderr and keep the pipe open past the sentinel line — the single most common real-world failure mode for this design (hung read on the *next* call) |
| Nested interpreters | `python3` left running (agent forgets to exit) then the next `exec`; `zsh -c`, `fish -c`, `dash script.sh`; `ssh host 'cmd'` | Confirms the sentinel-on-stdin design is agnostic to what runs underneath, and a wedged nested process surfaces as a timeout, not corruption of the next command's read |
| Concurrency / reentrancy | Two `exec` calls issued back-to-back without awaiting the first; cancellation of call N while call N+1 is queued; fd-3 snapshot fiber racing the next command's stdin write | Confirms the harness actually serializes access to the shared stdin/fds |
| Signals / timeout | `sleep 100` timeout → SIGINT → grace → shell survives; trap-and-ignore SIGINT; orphaned grandchild ignoring SIGINT | Validates SIGINT-stops-child-shell-survives, including SIGKILL fallback |
| Crash & restart | Bare `exit`; `exit 0` inside a sourced script; `kill -SEGV $$`; `kill -9` mid-command | Restart fires, snapshot replay works, in-flight command surfaces as `Error` |
| Snapshot fidelity | export/function/alias/`shopt`/`set -o` survive; negative case: a pre-crash `trap` is *not* restored | Confirms documented gaps are real, not flaky |
| cwd/env override removal | `cd` in one call then a relative-path command in the next resolves correctly; `cd` into then `rm -rf` the cwd itself | Direct regression test for the Stage-2 core fix |
| Buffering / streaming / interleaving | Alternating stdout/stderr writes with sleeps (timestamp merge reconstructs true order); fully-buffered vs line-buffered program; multi-MB output on one fd while the other is idle | Validates the three-fd concurrent-reader design under backpressure |
| TTY-dependent hangs | `read -p` with nothing on stdin; `sudo -S` with no password piped; `ssh` awaiting host-key confirmation; anything invoking `$PAGER`/`$EDITOR` | Confirms these degrade to hang → timeout → recover, not an unrecoverable wedge |
| Cross-shell emission snippet (axis 1, smoke only) | Run the sentinel-emission snippet verbatim through `dash` and `zsh` (skip `fish` — see above) | Cheap insurance if outer-shell choice is ever generalized |

#### Suggested structure

- Unit-level alcotest coverage for concurrency/signal/crash/snapshot — these need Eio
  control, not just shell scripts (this is `persistent_shell_test.ml` /
  `persistent_shell_concurrency_test.ml`).
- For the cross-shell smoke axis, borrow the
  [oils-for-unix spec-test](https://github.com/oils-for-unix/oils/wiki/Spec-Tests)
  approach directly: a small fixture directory of snippets with expected
  `(stdout, stderr, exit_code)`, run through whichever shell binaries are present in CI
  (`which dash zsh || skip`), with per-shell "known divergence" annotations rather than
  requiring identical output everywhere.

**Prior art consulted** (condensed — see git history of this file for the full survey):
pexpect's `replwrap.py` (closest existing analogue — has to special-case bash-vs-zsh
sentinel syntax, previews the fish-incompatibility trap above); OSC 133 "semantic prompt"
shell integration used by VSCode/iTerm2/kitty/ghostty/wezterm (bash via `PROMPT_COMMAND`,
zsh via `precmd`/`preexec` + a dedicated tty fd, fish via event hooks with documented gaps
per [fish-shell#8832](https://github.com/fish-shell/fish-shell/issues/8832)); oils-for-unix
spec tests (methodology model for the fixture suite); ShellSpec (BDD runner for shell
*scripts*, not IPC protocols — noted but not directly reused).

---

## Key risks (Stage 0)

- **Backgrounded jobs holding a pipe open past the sentinel** (`cmd &`, `nohup`,
  `disown`) is the single most likely real-world hang. Stage 3's subshell/grouping category
  exists specifically to pin this down before it's found in production.
- **No PTY is a correctness risk for whole workflows** (interactive auth, pagers, `sudo`),
  not just a timestamp-precision footnote — see the reflection under Stage 3. Recommend
  treating pty allocation as an early Phase 1 item rather than a "someday" note.
- **`exec_result` is a shared record type** — the `chunks` field addition must update every
  construction site (enumerated under Stage 0) in the same commit that changes the type, or
  the build breaks non-locally.
- **Snapshot fidelity gaps are real gaps** (traps, jobs, history, `PIPESTATUS`,
  `BASH_REMATCH`) — Stage 1's negative test (trap not restored) exists so this stays a
  documented, tested boundary rather than a silent surprise later.
- **Restart notice must not silently vanish.** Because it's carried in tool-output text
  (Stage 1's corrected design) rather than a structured event, a future refactor of
  `bash_tool.ml`'s output assembly could accidentally drop the prefix. Worth a dedicated
  test (Stage 1's `on_restart` tests) rather than relying on manual review to catch this.

---

## What Stage 0 does NOT include (deferred to Phase 1+)

- OS kernel sandbox (bwrap, sandbox-exec) — Phase 1.
- `Fs` substitution / containment gate — agents can still escape the workdir via tools
  until Phase 1 lands. Accepted risk for Stage 0.
- `--sandbox`/`--no-sandbox` flag — nothing backs it yet.
- Secret injection mechanisms (`env_passthrough` allowlist *enforcement*, secrets tmpfs,
  `refresh_credentials`) — the snapshot decision above takes the one Stage-0-relevant
  precaution (never touch disk) but does not implement allowlisting.
- Path remapping — Phase 2.
- PTY allocation — flagged above as an early Phase 1 candidate, not Stage 0 scope.
- **Reattaching a persistent shell across separate CLI process invocations, or session
  resume.** The shell dies with the CLI process (decision 9 above); a future session-resume
  feature will start a fresh shell rather than reconnect to one. Whether resume should also
  replay the last snapshot is left open until resume itself is designed.

---

## Reference: Phase 1+ design (not in scope for Stage 0)

Everything below is preserved research for when Phase 1 (OS sandbox) and Phase 2 (path
remapping) are scheduled. It has not been re-verified against the tree the way Epoch 0
above has, and should be re-checked against the codebase at that time.

### Industry survey (2026-07-01)

How major AI coding agent harnesses actually implement sandboxing:

| Tool | macOS tech | Linux tech | Persistent shell | Network isolation | Default |
|---|---|---|---|---|---|
| Claude Code | Seatbelt (sandbox-exec) | Bubblewrap + seccomp | Partial (cwd state, env NOT) | HTTP/SOCKS proxy outside sandbox | ON |
| Codex CLI | Seatbelt | Bubblewrap + Landlock + seccomp; vendors bwrap if absent | Not documented (fresh per call) | Blocked; seccomp blocks outbound except AF_UNIX | ON |
| Cursor | Seatbelt; dynamic SBPL profiles | Landlock + overlay FS + seccomp | Not documented | Approval gate | ON |
| Gemini CLI | sandbox-exec; Docker/gVisor optional | Docker/Podman/gVisor (opt-in) | Container persists (Docker mode) | Profile-based (open/proxied/restrictive) | OFF (opt-in) |
| Aider | None | None (subprocess.Popen, shell=True) | No (restarts per call) | None | N/A |
| OpenCode | None | None (MCP stdio, persistent) | Yes (MCP stdio persistent) | None | N/A |

**Key patterns from the survey:**

1. Seatbelt + Bubblewrap is the consensus for local kernel-level sandboxing across every
   serious tool (Claude Code, Codex, Cursor). No one serious uses Docker for local — too
   heavy.
2. seccomp is a second layer on Linux (Claude Code, Codex, Cursor). Worth deferring — bwrap
   alone gives strong isolation.
3. **Dynamic policy generation at runtime**: both Claude Code and Cursor generate sandbox
   policies from project config rather than a fixed profile.
4. **Cursor "overlay" (Linux)**: NOT kernel OverlayFS. tmpfs/bind mounts + Landlock:
   directories get one tmpfs mount each; file globs get one bind mount *per matched file*
   (hits Linux's ~1000 mount limit for `**/node_modules/**`-style patterns). Linux can't do
   lazy per-syscall filtering like macOS Seatbelt, so Cursor must pre-walk the filesystem
   and pre-stage all mounts before activation — "the slowest part of Linux sandboxing" per
   their blog.
5. **Proxy-based network filtering** (Claude Code): HTTP/SOCKS proxies outside the sandbox
   inspect egress traffic — cleaner than seccomp-based network blocking.
6. **Persistent shell gap**: OpenCode is the only tool with a truly persistent shell (MCP
   stdio JSON-RPC), and it has no sandbox. Claude Code has partial state (cwd tracks, env
   does NOT persist). Nobody has both a persistent shell AND sandbox today.
7. **Vendored bwrap** (Codex): vendors bubblewrap as a Rust binary to avoid a system dep.

**Sources:** Anthropic engineering blog, `anthropic-experimental/sandbox-runtime` (TS),
`openai/codex/codex-rs/linux-sandbox` (Rust), Cursor blog post on agent sandboxing, Gemini
CLI docs, agent-safehouse.dev investigation reports.

### Technology survey

#### Linux: bubblewrap (bwrap)

Used by Flatpak, Claude Code, Podman (rootless). Rootless Linux user namespaces, no setuid.
Flags of interest: `--ro-bind`, `--bind`, `--tmpfs`, `--dir`, `--setenv`, `--proc`, `--dev`,
`--unshare-net`. Available as a system package, opam, or nix. Check via `which bwrap`.

#### agent-safehouse investigation (macOS sandbox-exec wrapper)

[`eugene1g/agent-safehouse`](https://github.com/eugene1g/agent-safehouse) (Apache-2.0,
~1.9k stars, ships a `pi` agent profile already): macOS-only today, a single self-contained
bash script that assembles SBPL profiles and launches a command inside `sandbox-exec`.
Deny-first, composable profiles; auto-detects git root as workdir. It's a launcher/wrapper,
not a persistent shell. No Linux support (open issue #14, landlock+seccomp direction);
maintainer notes the value is in the rule collection, not the implementation.

**Implications for pera:** macOS — (a) fast first cut: vendor `safehouse.sh`, launch
pera's persistent bash inside it; (b) target: reuse only safehouse's SBPL rule collection,
feed it to `sandbox-exec` ourselves, keep pera in control of the persistent shell.
Recommend (a) → (b). Linux — safehouse doesn't help directly, but borrow its rule taxonomy
(workdir rw, toolchain ro, deny home) translated into bwrap argv.

#### macOS: sandbox-exec (Seatbelt)

Ships with macOS, no install needed, deprecated in docs but functional. No mount namespace
(can't give a fresh `/home`) — best for restricting writes, not full isolation. Primary
macOS path = agent-safehouse (above), not hand-rolled SBPL. Docker is out of scope.

#### Containment default (both backends)

Default writable surface = current git checkout root (`git rev-parse --show-toplevel`,
fallback to launch cwd). Everything outside is read-only or denied for writes. Applies to
both the sandboxed shell and the harness `Fs` tools.

#### macOS fallback: fresh-homedir-only mode

`$TMPDIR/pera-sandbox-<uuid>/` as fresh `$HOME`; block writes to the real `$HOME` via
`sandbox-exec` profile; "soft sandbox," not network-isolated.

#### Linux-only alternatives (deferred)

landlock (kernel 5.13+, in-process, not for subprocess sandboxing); firejail (richer
profiles, more complex, no macOS); nsjail (strong namespaces+seccomp, complex setup).

#### Docker/Podman — out of scope

Portable, strong isolation, requires a daemon, heavy for per-session use. Better fit for a
remote/VM sandbox path (deferred). Kept as notes only — not a backend variant in the config
model.

### Persistent-shell-only mode

Already shipped by Stage 0 above as the default.

### Module design: `Fs` substitution (Phase 1)

Refactor env construction so `Fs` is substitutable without changing `Execution_env.S`.
Today `local_env.ml` builds `Fs`/`Sh` inline and returns `(module S)` directly (confirmed —
see the Stage-0 architecture-context section above; there is no `Local_fs.make` extraction
yet). The refactor:

- Extract `Fs` construction: `Local_fs.make ~cwd : (module FILESYSTEM)`.
- Assemble `S` from given `Fs` + `Sh` + `cwd`: `S_env.make ~fs ~sh ~cwd : (module
  Execution_env.S)`.
- `Sandbox_env` supplies its own `Fs` — an identity `Fs` over host ops plus a containment
  gate: every `read_text_file`/`write_file`/`list_dir`/etc. first checks the resolved host
  path is inside the allowed writable surface (git checkout root) for writes, and inside
  the allowed readable surface (checkout root + system/toolchain ro mounts) for reads.
  Paths outside → `Error` (typed `file_error`), never reaching the OS.

This delivers containment with zero path remapping and pre-shapes the architecture for
Phase 2.

### Module design: path remapping (Phase 2)

```ocaml
module Path_map : sig
  type t
  val make : workdir_mount:[ `Same_path | `At of string ] ->
             extra_ro:(string * string) list ->
             extra_rw:(string * string) list -> t
  val to_host : t -> agent_path:string -> (string, [ `Outside_view ]) result
  val to_agent : t -> host_path:string -> string
end

module Path_mapping_fs
    (Host_fs : FILESYSTEM) (Map : Path_map.S) : FILESYSTEM
```

Because Phase 1 routes all `Fs` access through a swappable module, Phase 2 is purely
"provide a `Path_mapping_fs` impl instead of the identity `Fs`." Tools never know
remapping exists. Default `workdir_mount = Same_path` (no remapping, no LLM confusion); `At
sandbox_path` is an advanced opt-in.

### `Sandbox_env` config (Phase 1)

```ocaml
type sandbox_config = {
  workdir_mount : [ `Same_path | `At of string ];
  fresh_home : string option;
  env_passthrough : string list;
  env_script : string option;
  extra_ro_mounts : (string * string) list;
  extra_rw_mounts : (string * string) list;
}
```

OS backend (bwrap argv / sandbox-exec profile) resolved internally per platform; the
user-facing toggle is just `--sandbox`/`--no-sandbox`.

### `pera_config` additions (Phase 1)

```ocaml
type sandbox_config = {
  enabled : bool;                       (* default false; --sandbox *)
  env_passthrough : string list;        [@sexp.default []]
  env_script : string option;           [@sexp.option]
  unshare_network : bool;               [@sexp.default false]  (* Linux only *)
  extra_ro_paths : string list;         [@sexp.default []]
  extra_rw_paths : string list;         [@sexp.default []]
}
```

`sandbox : sandbox_config option` on `config` — following the `[@sexp.option]` convention
confirmed in Stage 2 above, not the `[@sexp.default false]` inline-record form the earliest
draft used for the top-level `enabled` field (mirror whichever form is actually adopted for
`persistent_shell` in Stage 2, for consistency).

### Secret injection design (Phase 1+)

**Problem statement:** secrets split into static long-lived (API keys, tokens) and dynamic
short-lived (STS tokens, OAuth, Vault leases expiring in 15min–1hr). Must never appear in
session JSONL, tool output visible to the LLM, `/proc/<pid>/cmdline`, or sandbox process
listings.

**Mid-session updates:** dynamic lookup from the pera-cli process environment at injection
time (not a one-time startup snapshot). Non-secret env updates: `export NAME=VALUE` sent to
the live shell's stdin, no restart. Secrets that must not appear in `env`: the tmpfs-file
mechanism (below). Unavoidable restarts fall back to the Stage-1 snapshot/replay procedure.
A `refresh_environment` tool (sibling of `refresh_credentials`) triggers re-lookup +
re-injection, returning only metadata.

**Mechanism 1 — `env_passthrough` (static, simple):** named vars copied from harness to
sandbox shell at startup. Static; `env`/`printenv` inside the sandbox exposes all of them
in one shot (prompt-injection risk) — appropriate only for secrets where seeing the value
in tool output is acceptable.

**Mechanism 2 — secrets tmpfs (dynamic, file-based):** harness creates a tmpfs dir on the
host (`$TMPDIR/pera-secrets-<uuid>/`), bind-mounted read-only into the sandbox
(`/run/pera/secrets/`). Harness refreshes files in the background before expiry; SDKs that
re-read credential files on each call need no agent action. Works for any file-based
credential format (AWS `~/.aws/credentials`, `.netrc`, OAuth token files). Cons: the agent
can `cat` the file and see raw values — mitigated by file perms, not eliminated (true
isolation needs Mechanism 4).

**Mechanism 3 — agent-callable `refresh_credentials` tool (primary pattern, decided):**
runs outside the sandbox (harness-side, not routed through `Sh.exec`); fetches fresh creds
from the host credential chain; writes to the secrets tmpfs; returns confirmation
**without credential values** (`"AWS credentials refreshed (valid until 14:32 UTC)"`).
Decided as primary because it naturally handles interactive flows (AWS SSO — user opens a
browser, harness waits) that Mechanism 2 alone can't, and the agent knowing a refresh
happened is useful context for retry logic.

```sexp
(sandbox
  (credential_providers
    ((name "aws") (type aws_default_chain) (refresh_before_expiry_s 300))
    ((name "github") (type env_var) (source_var "GITHUB_TOKEN"))))
```

**Mechanism 4 — credential process proxy — out of scope:** AWS `credential_process` config
key pointing at a small proxy binary that fetches creds over a Unix socket from the
harness, so they never live in the sandbox even as files. Most secure pattern, but out of
scope now that Docker/remote sandboxes aren't planned; notes retained for when
remote/Docker backends land.

**Mechanism 5 — startup env script:** user-provided script, read from host, sourced in the
sandbox shell at startup; runs host CLIs (e.g. `aws configure get ...`) outside the sandbox
to extract creds, harness injects the output as env vars. Re-sourcing for refresh is tricky
(doesn't un-export previously-set vars).

**Layering by use case:**

| Use case | Mechanism |
|---|---|
| Simple static API keys | `env_passthrough` |
| AWS creds with SSO/STS | Mechanism 3 + tmpfs write |
| AWS creds (no interactive auth) | Mechanism 2, Mechanism 3 fallback |
| OAuth tokens (GitHub, etc.) | Mechanism 2, Mechanism 3 fallback |
| Custom startup env setup | `env_script` |
| Most secure (file-free) | Mechanism 4 — deferred |

**SSO interactive refresh flow:** agent calls `refresh_credentials {provider: "aws-sso"}` →
harness detects SSO needed, notifies via the fan-out → CLI shows `[pera] AWS SSO login
required` → harness triggers `aws sso login` on host, outside sandbox → user completes
browser flow → harness writes fresh creds to secrets tmpfs → tool returns confirmation →
agent retries.

**Secret scrubbing:** values from any mechanism must never appear in session JSONL; the
session writer must not log env var values; `refresh_credentials`/`refresh_environment`
return only metadata.

**On hiding secrets from `env`:** no practical way to hide env vars from a process that has
them. Don't put secrets you want hidden in env vars — use the tmpfs-file approach instead.
`env_passthrough` is fine only for secrets where visibility in tool output is acceptable.

```ocaml
type credential_provider_type =
  | Aws_default_chain
  | Env_var of { source : string }
  | File of { path : string; format : [ `Aws_credentials | `Dotenv | `Raw_export ] }
  | Command of { argv : string list }

type credential_provider = {
  name : string;
  provider_type : credential_provider_type;
  refresh_before_expiry_s : int option;   [@sexp.option]
  target_path : string option;            [@sexp.option]
  interactive : bool option;              [@sexp.option]
}

(* Add to sandbox_config: *)
  credential_providers : credential_provider list;  [@sexp.default []]
```

### Seams that need work (Phase 1+)

| Location | Change |
|---|---|
| `lib/pera_env/sandbox_env.{ml,mli}` | **New** — sandbox-backed `Execution_env.S` (identity `Fs` + containment gate; OS backend resolved internally) |
| `lib/pera_env/path_map.{ml,mli}` | **Phase 2** — path mapping + `Path_mapping_fs` |
| `lib/pera_cli/pera_config.ml` | New `sandbox_config`; `sandbox : sandbox_config option` |
| `lib/pera_cli/config_resolver.ml` | Resolve sandbox config |
| `lib/pera_cli/pera_cli.ml` | `--sandbox`/`--no-sandbox`; hard-fail if backend can't start |
| `lib/pera_agent/agent_harness.mli` | Possibly carry sandbox config through; secret-refresh notifications via `subscribe` fan-out |

### Open design questions (Phase 1+)

- **bwrap availability** — decided: if `--sandbox` is requested and the backend can't
  start, `pera-cli` exits with a clear error. No silent fallback. Strict on/off, no `Auto`.
- **Startup latency** — bwrap shell startup adds ~50ms; acceptable for interactive use.
- **Tmpdir home cleanup** — fresh home dir under `$TMPDIR` cleaned up at session end via an
  Eio `Switch` resource.
- **`find_executable` inside sandbox** — currently searches host `PATH`; fine, since
  `PATH` is inherited/passed through. No change needed.
- **Init script approach** — user-configured startup script sourced via bash's
  `--init-file` or an initial `source` command.
