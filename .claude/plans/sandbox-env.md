# Sandbox Execution Environment — Planning Document

**Status**: Stage 0 planned  
**Date**: 2026-07-01 (revised 2026-07-03)  
**Branch**: bridge-cse_01MY3dfGCqYK38hRssgyFdfV

---

## Goal

Add a sandbox execution environment: a long-running shell process (inside a namespace container or OS sandbox) whose state (cwd, env vars, shell functions) is preserved across tool calls. This differs from the current `Local_env`, which spawns a fresh `/bin/sh -c` process per call.

### Key requirements

1. **Shell state preserved** — `cd`, `export`, `alias`, etc. survive across consecutive bash tool calls within a session. (Persistent shell is the **default**, even without sandboxing.)
2. **Filesystem isolation** — the sandboxed shell gets a fresh home directory; it cannot write to the real `$HOME` unless explicitly permitted.
3. **Containment by default** — the writable surface defaults to the **current git checkout root** (`git rev-parse --show-toplevel`, falling back to the launch cwd if not in a repo). Everything outside it is read-only / denied for writes. This applies to both the shell *and* the `read`/`write`/`grep` tools — a broken or malicious agent must not be able to read/write host paths outside the sandbox view via the harness tools.
4. **Configurable environment** — a list of env vars to pass through from the harness, or a startup script to source inside the sandbox shell.
5. **macOS + Linux support** — different isolation backends, same `Execution_env.S` interface. Backend is chosen per-OS internally; the user-facing switch is a plain on/off.
6. **Hard-fail on misconfiguration** — if `--sandbox` is requested and the chosen backend cannot start (bwrap missing on Linux, `sandbox-exec` unavailable on macOS), pera-cli exits with a clear error. No silent fallback to no-sandbox.

### Phasing

- **Stage 0 (MVP, ships first)**: persistent shell as the default execution env (`/bin/bash` only, no OS sandbox); `is_stateful` flag on `SHELL`; cwd-override fix in tools; post-command state snapshot for crash recovery; SIGINT+grace timeout; `Shell_restarted` event. Zero new OS dependencies.
- **Phase 1 (after Stage 0)**: refactor `Execution_env.S` construction so `Fs` is **substitutable** without changing the interface; ship an **identity** `Fs` (host paths, no remapping) with the **containment gate**; `--sandbox`/`--no-sandbox` bool; OS backends (bwrap on Linux, sandbox-exec on macOS); hard-fail on missing backend.
- **Phase 2 (later, additive)**: path remapping (`workdir_mount = At sandbox_path`) via a drop-in `Path_mapping_fs` wrapper. Because Phase 1 routes all `Fs` access through a swappable module, Phase 2 is purely "provide a different `Fs` impl" — no changes to tools, `S` assembly, or `bash_tool`/`grep_tool`.

---

## Current architecture context

### `Execution_env.S` (lib/pera_env/execution_env.mli)

```
module type S = sig
  val cwd : string          (* working directory this env is rooted at *)
  module Fs : FILESYSTEM    (* file operations via Eio / host OS *)
  module Sh : SHELL         (* shell execution *)
end
```

`SHELL.exec` takes optional `?cwd`, `?env`, `?timeout` per call.  
`Local_env` implements `Sh` by spawning `["/bin/sh"; "-c"; command]` fresh each call.

### Critical current issue: cwd is not preserved

`bash_tool.ml` and `grep_tool.ml` both pass `?cwd:(Some E.cwd)` (or resolve cwd then pass it) on every `Sh.exec` call. This means even with a persistent shell, callers override cwd every time. This must change for the persistent shell case — and the fix is simply **removal**: when `E.Sh.is_stateful`, do not pass `?cwd` at all, letting the shell maintain its own cwd. (See `bash_tool.ml` line ~57 and `grep_tool.ml` line ~116.)

### Where env is created

`pera_cli/pera_cli.ml` (Make functor) → `Cli_env.create ~env ~sw ~cwd` → passed into `Agent_harness.config.exec_env`.  
The CLI's `Cli_env` module (the `Env` module type) is the injection point.

---

## Industry survey (2026-07-01)

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

1. Seatbelt + Bubblewrap is the consensus for local kernel-level sandboxing across every serious tool (Claude Code, Codex, Cursor). No one serious uses Docker for local — too heavy.
2. seccomp is added as a second layer on Linux (Claude Code, Codex, Cursor). Worth deferring to a follow-on — bwrap alone gives strong isolation.
3. **Dynamic policy generation at runtime**: both Claude Code and Cursor generate sandbox policies from project config (`.cursorignore`, settings files) rather than using a fixed profile.
4. **Cursor "overlay" (Linux)**: NOT kernel OverlayFS. Uses tmpfs/bind mounts + Landlock: directories get one tmpfs mount each (efficient); file globs get one bind mount *per matched file* (slow, hits Linux's ~1000 mount limit for `**/node_modules/**`-style patterns). Pure deny-listing — no CoW upper layer. Linux can't do lazy per-syscall filtering like macOS Seatbelt can, so Cursor must pre-walk the entire filesystem and pre-stage all mounts before sandbox activation. This is "the slowest part of Linux sandboxing" per their blog.
5. **Proxy-based network filtering** (Claude Code): HTTP/SOCKS proxies run *outside* the sandbox and inspect all egress traffic. Cleaner than seccomp-based network blocking.
6. **Persistent shell gap**: OpenCode is the only tool with a truly persistent shell (via MCP stdio JSON-RPC), and it has no sandbox. Claude Code has partial state (cwd tracks, env vars do NOT persist across commands). Nobody has both a persistent shell AND sandbox today — this is a differentiator.
7. **Vendored bwrap** (Codex): they vendor bubblewrap as a Rust binary to avoid requiring it as a system dep. Useful for distribution.

**Sources:** Anthropic engineering blog, `anthropic-experimental/sandbox-runtime` (TS), `openai/codex/codex-rs/linux-sandbox` (Rust), Cursor blog post on agent sandboxing, Gemini CLI docs, agent-safehouse.dev investigation reports.

---

## Technology survey

### Linux: bubblewrap (bwrap)

- Used by Flatpak, Claude Code, Podman (rootless), many sandboxing tools.
- Rootless Linux user namespaces (no setuid, no root needed on modern kernels).
- Flags of interest:
  - `--ro-bind /usr /usr` — read-only bind mounts for system paths
  - `--bind <host_path> <sandbox_path>` — read-write bind mount
  - `--tmpfs /tmp` — fresh tmpfs
  - `--dir /home/sandbox` — create empty dir
  - `--setenv HOME /home/sandbox` — override env
  - `--proc /proc`, `--dev /dev` — needed by most programs
  - `--unshare-net` — network isolation (optional)
- Available as system package (`bubblewrap`), also installable via opam/nix.
- Check availability: `which bwrap` or `bwrap --version`.

### agent-safehouse investigation (macOS sandbox-exec wrapper)

[`eugene1g/agent-safehouse`](https://github.com/eugene1g/agent-safehouse) (Apache-2.0, ~1.9k stars, ships a `pi` agent profile already):

- **macOS-only today.** A single self-contained Bash script (`dist/safehouse.sh`) that assembles SBPL profiles and launches a command inside `sandbox-exec`. Deny-first, composable profiles: auto-detects git root as workdir (read/write), grants read-only toolchains, denies `~/.ssh` / `~/.aws` / other repos.
- It's a **launcher/wrapper**, not a persistent shell — it runs a child process inside the sandbox.
- **No Linux support** (open issue #14, landlock+seccomp direction). The maintainer: *"the main value is in collecting rules rather than the actual implementation, and those rules are potentially useful across the board."*

**Implications for pera:**

- **macOS** — two options: (a) **fast first cut**: vendor/bundle `safehouse.sh` and launch pera's persistent bash inside it (cheapest path to macOS sandboxing; gets the deny-first model + git-root workdir for free, satisfying the containment requirement); (b) **target**: reuse only safehouse's **SBPL profile/rule collection** and feed it to `sandbox-exec` ourselves, keeping pera in control of the persistent shell (no extra wrapper process). Recommend (a) → (b).
- **Linux** — safehouse doesn't help; we still need bwrap ourselves. But we can **borrow safehouse's rule taxonomy** (workdir rw, toolchain ro, deny home) and translate it into bwrap argv. Track issue #14's landlock+seccomp direction for forward-compat.

### macOS: sandbox-exec (Seatbelt)

- Apple's `sandbox-exec(1)` + SBPL (Sandbox Profile Language, Scheme-like DSL).
- Ships with macOS; no install needed.
- Deprecated in Apple docs but still functional (used by macOS itself, Xcode).
- Example profile to deny writes outside workdir:

```scheme
(version 1)
(allow default)
(deny file-write*
  (regex "^/Users/[^/]+")
  (regex "^/private/var/folders"))
(allow file-write*
  (subpath "/path/to/workdir")
  (subpath "/tmp")
  (subpath "/private/tmp"))
```

- Limitation: no mount namespace (can't give a fresh `/home`). Best for *restricting writes* rather than full isolation.
- **Primary macOS path = agent-safehouse** (see above): reuse its deny-first profile assembly rather than hand-rolling SBPL. **Docker is out of scope for now** (removed from consideration as a backend; notes kept below only for forward-compat).
- ~~Alternative for macOS: Virtualization.framework (heavy, needs entitlements), Docker (daemon required).~~ — deferred/out of scope.

### Containment default (both backends)

Regardless of backend, the **default writable surface is the current git checkout root**, detected via `git rev-parse --show-toplevel` from the launch cwd (falling back to the launch cwd if not in a git repo). Everything outside the checkout is read-only (system paths, toolchains) or denied for writes (`$HOME`, other repos, `~/.ssh`, `~/.aws`). This applies to both the sandboxed shell **and** the harness `Fs` tools (read/write/grep) so a broken or malicious agent can't escape the sandbox dir through the tools — see the containment gate in the `Fs` substitution design.

### macOS fallback: Fresh-homedir-only mode

Without strong isolation, we can still achieve useful sandboxing:
- Create `$TMPDIR/pera-sandbox-<session-uuid>/` as a fresh home.
- Set `HOME` to that path before spawning the shell.
- Block writes to the real `$HOME` via `sandbox-exec` profile (deny outside the git checkout root, per the containment default above).
- System tools, PATH, etc. inherited from harness.
- "Soft sandbox" — prevents accidental dotfile corruption; not network-isolated.

### Linux-only alternatives (deferred)

- **landlock** (kernel 5.13+): in-process path restriction via syscall, no child process. Restricts the pera process itself rather than a subprocess. Useful if we want to lock down pera's own file access, not for sandboxing agent commands. (Track via agent-safehouse issue #14.)
- **firejail**: user-space, richer profiles than bwrap but more complex. Not available on macOS.
- **nsjail** (Google): strong namespaces + seccomp. More complex setup, not commonly pre-installed.

### Docker/Podman — out of scope (forward-compat notes only)

- Very portable, strong isolation. Requires daemon process. Heavy for per-session use.
- Better fit for remote/VM sandboxes (the "slave process" path), which is itself deferred.
- Kept as notes so nothing we design now conflicts with adding it later; **not** a backend variant in the config model.

---

## Persistent shell design

### Why a persistent shell

Current model: each `Sh.exec` call spawns `/bin/sh -c <command>`, runs, dies. No state.  
Persistent model: one long-lived shell process (bash). Each tool call sends a command to it and reads back the result.

State preserved between calls: cwd, exported env vars, shell functions, history, jobs (if not backgrounded).

### Protocol: three independent channels, no stream merging

No slave binary needed for local sandboxes. We communicate directly with the shell over three pipes set up at spawn time: **stdout** (fd 1), **stderr** (fd 2), and a private **state** channel (fd 3) that user commands never see or touch.

**Revised from an earlier draft** that merged stdout/stderr with `2>&1` so a single sentinel could mark completion. That merge happens *inside the shell*, before the harness ever sees two streams — it throws away the stream tag permanently and forecloses ever separating them later without redesigning the protocol (see "stdout/stderr merging" discussion in the design notes). Splitting them costs nothing extra: a real interactive shell already has stdout and stderr as distinct fds — `2>&1` was the artificial step we were adding, not a natural default. Eio supports arbitrary fd mapping on process spawn (mirrors `Types.Exec.exec`'s `?fds:redirect list` in the `merry` survey), so a third fd is straightforward.

**Per-command protocol:**

1. Generate a unique per-call sentinel: `SENTINEL = "PERA_DONE_" + uuidv4_hex()`
2. Write to shell stdin:
   ```
   ( <user_command> )
   printf '\n' 1>&1; printf '\n' 1>&2
   echo "$? $SENTINEL" 1>&1
   echo "$SENTINEL" 1>&2
   ```
3. Read stdout and stderr **concurrently**, one Eio fiber per fd, each terminating on its own sentinel line. Because bash only reaches the `echo ... $SENTINEL` lines after the subshell (and everything it forked) has fully exited, and pipe writes/reads are ordered per-fd, seeing a fd's sentinel guarantees all of that command's output on that fd has already been delivered — no merge needed to know when you're done.
4. The harness timestamps every line as it is read (`Eio.Time.now`), independent of the shell — zero protocol coordination required for this part. Each captured line is conceptually `(stream, timestamp, content)`.
5. `exec_result` still exposes flattened `stdout : string` / `stderr : string` for compatibility, plus an ordered list of timestamped, tagged chunks. Tools can merge-sort by timestamp to reconstruct **true wall-clock interleaving** without ever forcing both streams through one fd — strictly better than shell-side `2>&1`, which is also only an approximation of interleaving and destroys the tag to get it. Default tool output becomes this order-correct merge; "stdout only" (for machine-parsed output like `--json`/`--porcelain` flags) and per-line timing (useful for spotting hangs/slow steps) both become available without extra shell round-trips.

**Known limitation (documented, accepted, not new):** many programs fully block-buffer stdio when fd 1/2 is a pipe rather than a tty, so a timestamp means "when the harness received the flushed chunk," not the instant it was produced. This is true of today's `Local_env` pipe capture too — not introduced by this change, and not being solved now (pty allocation, e.g. via `openpty`/`script`, is a possible future improvement, out of scope for Stage 0).

**Why this works:**
- UUID sentinel is unique per call — collisions with command output are astronomically unlikely, on either stream.
- Wrapping in `( ... )` makes the exit code of the subshell reflect `<user_command>`.
- `printf '\n'` on both fds ensures a clean newline before each sentinel even if the command's output on that fd ended without one.

**Cancellation and timeout:**
- A separate Eio fiber monitors `Eio.Cancel.t`; if cancelled, sends SIGINT to the shell process (not SIGKILL — allows the shell to clean up).
- For timeout, use `Eio.Time.with_timeout_exn`; on expiry, send SIGINT and wait for the sentinel (with a short grace period), then send SIGKILL if still unresponsive.
- If the shell process dies unexpectedly, reads from stdout will hit EOF. The env detects this and triggers the **shell lifecycle** procedure below.

### Shell selection

Default to `/bin/bash` for state-preserving semantics (arrays, `BASH_SOURCE`, etc.). Fall back to `/bin/sh` if bash not found.

### Shell lifecycle: crash detection, notification, and state preservation

If the persistent shell exits unexpectedly (e.g. `exit` was run in a command, or it segfaulted), the env must **tell the agent** so the agent can reinitialise shell state, and must preserve as much shell state as possible across the restart.

**Crash notification (decided):** surface a structured `agent_event` to subscribers (and thereby to the agent's context) stating the shell died and was restarted. Reuse the existing `Agent_harness.subscribe` fan-out — no new event bus. The agent receives the notification and knows to re-`export`, re-`source`, re-`cd` as needed.

**State preservation across restart — hybrid snapshot/replay (decided, with security mitigations):**

On a periodic checkpoint (and at crash detection), capture the shell's own state into a re-sourceable script and replay it into a fresh shell. The hybrid approach: snapshot env/funcs/options via bash introspection; replay `cd` + any `source` commands.

Snapshot set:
- `declare -px` — exported env vars
- `declare -f` — shell functions
- `alias -p` — aliases (NOT covered by `declare`; needed for coherence)
- `shopt -p` — shell options (e.g. `globstar`, `nullglob`)
- `set +o` — `set` options
- `pwd` — current working directory (replayed as `cd`)

Replay: source the assembled snapshot script into the fresh shell, then replay the recorded `cd`/`source` commands.

**Security — credential-leak risk (the critical one):** `declare -px` dumps *all* exported vars at checkpoint time — not just the ones we injected. That includes credentials the **agent or a command it ran** placed into the shell env mid-session (e.g. `eval $(aws sts assume-role)` exporting `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`, or `export GITHUB_TOKEN=$(gh auth token)`). A naive snapshot silently captures **generated STS/OAuth tokens we never passed through**, exactly the "beyond those we passed through" case. If the snapshot is stored as a file the agent can read (inside the sandbox writable view), it directly violates the secret-injection rule (secrets must never appear in files the LLM can read); even host-side, replay re-exports **stale** creds after expiry, causing confusing auth failures.

**Mitigations (baked in):**
- **Allowlist the env snapshot**: persist only vars in the `env_passthrough` set plus vars explicitly created via the `refresh_environment`/`refresh_credentials` tools. **Drop everything else** — including agent/command-generated creds. Tag secret-sourced vars as "re-fetch on restart, never persist value"; re-derive them via `refresh_credentials` instead.
- **Store the snapshot outside the sandbox's readable view** (host-side under pera-cli control, or in pera-cli memory) — never as a sandbox-readable file. Same treatment as the secrets tmpfs, but harness-private.

**Coherence downsides (documented, accepted):**
- `declare` does **not** cover traps, jobs, the directory stack, history, `PIPESTATUS`, or `BASH_REMATCH`. A snapshot restores funcs/env/aliases/options but **not** traps/jobs/history — commands relying on an `alias` or `shopt` setting survive (we capture them); commands relying on a trap or a backgrounded job do not. Always notify the agent on restart so it can redo anything we deliberately didn't persist.
- `source` replay re-runs scripts with **side effects** (re-creating venvs, re-cloning, network calls) — nondeterministic, slow, may fail offline or re-trigger interactive auth. Prefer to record `source` invocations rather than their effects where possible.
- The snapshot is point-in-time; state since the last checkpoint is lost on crash (recent `cd`/`export`).
- Order/dependency: a filtered env snapshot loses the sequence that produced values; re-derivation via `refresh_credentials`/`refresh_environment` is preferred for dynamic values.

**Config:** `--persistent-shell-state=none|snapshot` (default `snapshot`).

---

## Module design

### `Fs` substitution (Phase 1, ships first)

Refactor env construction so `Fs` is **substitutable** without changing the `Execution_env.S` interface. Today `local_env.ml` builds `module Fs` and `module Sh` inline then returns `(module S)`. The refactor:

- Extract `Fs` construction: `Local_fs.make ~cwd : (module FILESYSTEM)` (the current host-Eio implementation, unchanged behaviour).
- Assemble `S` from **given** `Fs` + `Sh` + `cwd`: `S_env.make ~fs ~sh ~cwd : (module Execution_env.S)`.
- `Sandbox_env` supplies its own `Fs` — an **identity** `Fs` over the host ops (same paths, no remapping) plus a **containment gate**: every `read_text_file` / `write_file` / `list_dir` / etc. first checks the resolved host path is inside the allowed writable surface (the git checkout root) for write operations, and inside the allowed readable surface (checkout root + system/toolchain ro mounts) for reads. Paths outside → `Error` (typed `file_error`), never reaching the OS. This is the defence against a broken/malicious agent that gets the harness to read/write outside the sandbox dir through the tools.

This delivers containment with **zero path remapping** and pre-shapes the architecture for Phase 2.

### Path remapping (Phase 2, later, additive)

```ocaml
(** Maps between agent-visible paths and host paths. *)
module Path_map : sig
  type t
  val make : workdir_mount:[ `Same_path | `At of string ] ->
             extra_ro:(string * string) list ->
             extra_rw:(string * string) list -> t
  val to_host : t -> agent_path:string -> (string, [ `Outside_view ]) result
  val to_agent : t -> host_path:string -> string
end

(** Wraps a host FILESYSTEM, translating paths inbound and outbound. *)
module Path_mapping_fs
    (Host_fs : FILESYSTEM) (Map : Path_map.S) : FILESYSTEM
```

Because Phase 1 routes all `Fs` access through a swappable module, Phase 2 is purely "provide a `Path_mapping_fs` impl instead of the identity `Fs`." Tools (`read`/`write`/`grep`) never know remapping exists — they keep operating on agent-visible paths; `file_info.path`, `canonical_path`, and `list_dir` results are translated back to agent coordinates via `to_agent`.

**Default `workdir_mount = Same_path`** (no remapping, no LLM confusion). `At sandbox_path` is an advanced opt-in that requires the rewriting `Fs`.

### New module: `pera_env/persistent_shell.{ml,mli}`

```ocaml
(** A long-lived shell process that preserves state between exec calls. *)

type t

val create :
  proc_mgr:Eio.Process.mgr ->
  sw:Eio.Switch.t ->
  argv:string list ->     (* full argv: ["bwrap"; ...flags...; "/bin/bash"]
                             or just ["/bin/bash"] for no sandbox *)
  env:string array ->     (* env vars for the shell process itself *)
  cwd:string ->           (* initial working directory *)
  t
(** Spawns the shell process and writes a startup sentinel to confirm it's ready. *)

val exec :
  t ->
  command:string ->
  ?timeout:float ->
  cancel:Eio.Cancel.t ->
  (Execution_env.exec_result, Pera_types.Types.execution_error) result
(** Sends [command] to the persistent shell and reads back the result.
    Internally spawns two reader fibers (stdout, stderr), each waiting on its
    own sentinel, plus a third fiber draining the fd-3 state channel. Every
    line is timestamped as it is read; [exec_result] carries the flattened
    [stdout]/[stderr] strings for compatibility plus the ordered, timestamped,
    tagged chunks so callers can reconstruct true interleaving without the
    shell ever merging the two streams. *)

val close : t -> unit
(** Sends 'exit' to the shell and waits for it to terminate. *)
```

### New module: `pera_env/sandbox_env.{ml,mli}`

Implements `Execution_env.S` using a `Persistent_shell.t`.

```ocaml
type sandbox_config = {
  workdir_mount : [ `Same_path | `At of string ];  (* default `Same_path *)
  fresh_home : string option;   (* None = derive from tmpdir; Some p = use p *)
  env_passthrough : string list;  (* env var names to copy from harness *)
  env_script : string option;   (* path to shell script to source at startup *)
  extra_ro_mounts : (string * string) list;  (* (host, sandbox) read-only *)
  extra_rw_mounts : (string * string) list;  (* (host, sandbox) read-write *)
}
```

The OS-specific backend (bwrap argv on Linux, `sandbox-exec` profile on macOS) is resolved **internally per platform**, not exposed as a config variant. The user-facing toggle is just `--sandbox` / `--no-sandbox`.

`Fs` module: supplied via the substitution refactor — identity `Fs` + containment gate in Phase 1; `Path_mapping_fs` in Phase 2 when `workdir_mount <> Same_path`.

### `Execution_env.SHELL` signature change

Add:
```ocaml
val is_stateful : bool
(** [true] if shell state (cwd, env) is preserved between exec calls.
    Stateful shells ignore the [?cwd] and [?env] per-call overrides. *)
```

`Local_env.Sh.is_stateful = false`  
`Sandbox_env.Sh.is_stateful = true`

### `bash_tool.ml` / `grep_tool.ml` change (the fix = removal)

When `E.Sh.is_stateful = true`, **remove** the `?cwd:(Some E.cwd)` override — don't pass `?cwd` at all, letting the shell maintain its own cwd:

```ocaml
let cwd_arg = if E.Sh.is_stateful then None else Some E.cwd in
E.Sh.exec ~command ?cwd:cwd_arg ...
```

For non-stateful shells, keep current behaviour. In `grep_tool.ml` the same applies to the `E.Fs.absolute_path "."`-then-`~cwd` path (line ~107–116): for stateful shells, let the shell's cwd stand.

### `pera_config` changes

New config section (sandbox is **opt-in**):

```ocaml
type sandbox_config = {
  enabled : bool;                       (* default false; set via --sandbox *)
  env_passthrough : string list;        [@sexp.default []] (* env var names *)
  env_script : string option;           [@sexp.option]
  unshare_network : bool;               [@sexp.default false] (* Linux only *)
  extra_ro_paths : string list;         [@sexp.default []]
  extra_rw_paths : string list;         [@sexp.default []]
}
[@@deriving sexp, ...]

type config = {
  ...
  sandbox : sandbox_config option;      [@sexp.option]
  persistent_shell : bool;              [@sexp.default true] (* default ON; --persistent-shell=false opts out *)
  ...
}
```

Persistent shell is **not** a sandbox "backend" — it's an implementation detail that's on by default (even without `--sandbox`) and can be turned off with `--persistent-shell=false` for the stateless `/bin/sh -c`-per-call model (useful for debugging/CI).

### `pera_cli/pera_cli.ml` / `Cli_env` changes

The `Env` module type already has `create ~env ~sw ~cwd`. The `Make (Cli_env : Env)` functor's `resolve_exec_env` reads sandbox config from `rc` and:
- if `sandbox.enabled` → call `Sandbox_env.create`, resolving the OS backend internally; **if the backend cannot start, exit with a clear error** (no fallback).
- else → `Local_env` (but still persistent-shell by default unless `persistent_shell=false`).

CLI flags: `--sandbox` / `--no-sandbox` (equivalently `--sandbox=true|false`), and `--persistent-shell=false` opt-out.

---

## Seams that need work

| Location | Change |
|---|---|
| `lib/pera_env/execution_env.mli` | Add `val is_stateful : bool` to `SHELL` |
| `lib/pera_env/local_env.ml` | Extract `Local_fs.make`; `S_env.make ~fs ~sh ~cwd` assembly; `Sh.is_stateful = false` |
| `lib/pera_env/persistent_shell.{ml,mli}` | **New** — persistent shell proc + lifecycle (crash detect, snapshot/replay) |
| `lib/pera_env/sandbox_env.{ml,mli}` | **New** — sandbox-backed `Execution_env.S` (identity `Fs` + containment gate; OS backend resolved internally) |
| `lib/pera_env/path_map.{ml,mli}` | **Phase 2 (later)** — path mapping + `Path_mapping_fs` |
| `lib/pera_env/dune` | Add new modules |
| `lib/pera_tools/bash_tool.ml` | Remove `?cwd:(Some E.cwd)` when `is_stateful` |
| `lib/pera_tools/grep_tool.ml` | Same |
| `lib/pera_cli/pera_config.ml` | New `sandbox_config`; `persistent_shell` default true |
| `lib/pera_cli/config_resolver.ml` | Resolve sandbox config |
| `lib/pera_cli/pera_cli.ml` | Create appropriate env based on sandbox config; hard-fail if backend can't start |
| `lib/pera_agent/agent_harness.mli` | Possibly carry sandbox config through; expose shell-crash event via `subscribe` fan-out |

---

## Decisions (resolved — was "Questions for user")

1. **Scope** — Keep `Persistent_shell` and `Sandbox_env` inside `pera_env`. (No new `pera_env_sandbox` package; `pera_env` has zero deps beyond pera_types/Eio — adding bwrap detection is fine, no new library deps.)
2. **macOS approach** — Use `agent-safehouse`'s SBPL profile/rule collection as the primary macOS path (vendor script first, reuse rules as target). Research additional `sandbox-exec` approaches. **Docker is out of scope for now** (notes retained for forward-compat).
3. **Filesystem view** — `Fs` is **substitutable from Phase 1** (refactor to inject `Fs`); ship **identity** `Fs` with containment gate, **no remapping**. Path remapping (`Path_map` + `Path_mapping_fs`, `workdir_mount = At`) is a **later Phase 2** additive stage. Default `workdir_mount = Same_path`.
4. **Persistent-shell-only mode** — Persistent shell is the **default** (even without sandboxing). `--persistent-shell=false` opts out to the stateless model for dev/testing/CI.
5. **Changing `bash_tool`/`grep_tool` cwd behaviour now** — Yes, now. The fix is **removal**: drop the `?cwd:(Some E.cwd)` override when `E.Sh.is_stateful`.
6. **Remote/VM sandbox slave protocol** — **Deferred**. Local-first design must not preclude it later.
7. **Default** — Sandboxing is **opt-in** (`--sandbox`). Without it, pera runs as today (but persistent-shell by default per #4).
8. **State-capture mechanism** — Stay with a **real bash subprocess** as the executor, controlled via the enriched sentinel protocol above (three fds, harness-side timestamps). Two alternatives were considered and rejected for now:
   - **Embedding a shell interpreter as a library** (surveyed: [merry](https://tangled.org/patrick.sirref.org/merry), an OCaml shell library with immutable/introspectable state — would eliminate the text snapshot/replay round-trip entirely). Rejected: not complete enough to depend on — no working job control (`fg`/`bg`/`jobs` are reserved words with no implementation), background jobs (`&`) are explicitly disabled/broken per its own TODO, and its POSIX `State`/`Exec` reference implementation was deleted from its tree the day before this evaluation (single-maintainer, pre-alpha, `dune build` fails out of the box). Job control is a hard minimum for a shell substitute. Revisit only if/when it stabilizes — it would carry its own dependency lifecycle risk regardless.
   - **Platform-specific introspection** (Linux `/proc/<pid>/environ` reads instead of `declare -px`; bash loadable builtins via `enable -f` reporting state over a C-level side-channel). Rejected: pera's cross-platform bar is macOS + Linux (a hard requirement — see "5. macOS + Linux support" above, and the goal of being a general-purpose starting point for agentic dev on both), and both alternatives are Linux-only or require maintaining compiled platform-specific shims (a bash `.so` per OS/arch, notarization concerns on macOS) for a benefit — avoiding one `declare -px` round-trip — that the fd-3 side-channel above already captures without any platform-specific code, since it's pure Eio pipe plumbing on both OSes.

---

## Secret injection design

### Problem statement

Secrets come in two categories with different lifecycle requirements:

- **Static long-lived** (OpenAI API key, GitHub token, service passwords): set once at session start, don't change.
- **Dynamic short-lived** (AWS STS tokens, OAuth access tokens, Vault leases): expire mid-session (often in 15 min–1 hour) and must be refreshed without restarting the session or the agent.

The constraint is that secrets must never appear in:
- Session JSONL logs (conversation history that pera writes)
- Tool output visible in the conversation (the LLM sees everything in its context)
- `/proc/<pid>/cmdline` (don't pass as CLI arguments)
- Process listings visible inside the sandbox

### Mid-session environment updates

Env vars and credentials should be available **during** a running session without restarting it, leaning toward **dynamic lookup** from the pera-cli process environment rather than a one-time snapshot at startup.

- **Dynamic lookup preference**: env values are looked up lazily from the pera-cli process environment at injection time. A re-injection picks up refreshed values without restarting pera itself. (Even values that are "just grab the environment variable of the pera-cli process" are looked up on demand.)
- **Injection without restart (persistent shell default)**: for non-secret vars, injecting a new value mid-session means sending an `export NAME=VALUE` command to the live shell's stdin — no restart needed. For secrets that must not appear in the shell's `env` (prompt-injection risk), use the tmpfs-file mechanism (Mechanism 2): the harness updates the file and the agent re-reads it.
- **When a restart is unavoidable** (e.g. a crashed shell, or re-ordering `PATH` in a way that confuses already-running logic): fall back to the snapshot/replay procedure from the shell-lifecycle section, so the agent doesn't lose state.
- **`refresh_environment` harness-side tool**: a sibling of `refresh_credentials` that triggers re-lookup + re-injection and returns only metadata (not values), consistent with the scrubbing rules below.

### Mechanism 1: env_passthrough (static, simple)

Already in the config design. At sandbox startup, named env vars are copied from the harness process into the sandbox shell's environment.

```sexp
(sandbox
  (env_passthrough (OPENAI_API_KEY GITHUB_TOKEN NPM_TOKEN)))
```

**Pros**: trivial, standard.  
**Cons**: static — refresh requires re-injection (see mid-session updates above). Also, `env` or `printenv` inside the sandbox exposes all of them to the agent in a single shot (prompt injection risk).

### Mechanism 2: Secrets tmpfs directory (dynamic, file-based)

The harness creates a `tmpfs` directory on the host — e.g. `$TMPDIR/pera-secrets-<session-uuid>/` — and bind-mounts it into the sandbox at a fixed path: `/run/pera/secrets/` (read-only inside sandbox). The harness can write and update files in it at any time; changes are immediately visible inside the sandbox because it's the same underlying tmpfs.

```
host:    $TMPDIR/pera-XXXX/secrets/aws-credentials  ← harness writes here
sandbox: /run/pera/secrets/aws-credentials           ← same inode, ro bind
```

**Credential refresh without agent involvement**: for file-based credential formats (AWS `~/.aws/credentials`, `.netrc`, OAuth token files), the harness refreshes the file in the background before it expires. The AWS SDK and similar libraries re-read the credentials file on each call — no agent action needed.

**Startup bootstrap for AWS**: inside the sandbox, `~/.aws/config` (in the fresh home dir) contains:
```ini
[default]
credential_file = /run/pera/secrets/aws-credentials
```
The harness writes the initial credentials before launching the sandbox shell.

**Pros**: works for any file-based credential format; refresh is transparent to the agent; secrets never appear in conversation.  
**Cons**: the agent can `cat /run/pera/secrets/aws-credentials` and see the raw values (then the LLM sees them). Mitigated by file permissions (mode 0400, owned by sandbox user) — but in practice, if the agent is the sandbox user, it can still read them. True isolation of secrets from the agent requires the credential proxy pattern (Mechanism 4, deferred — see out-of-scope below).

### Mechanism 3: Agent-callable refresh tool

A special built-in tool — `refresh_credentials` — registered with the harness and visible to the agent. When the agent calls it (e.g. after getting an auth error):

1. The tool runs **outside the sandbox** (it's a harness-side tool, not routed through `Sh.exec`)
2. The harness fetches fresh credentials from the host credential chain (AWS SDK, keychain, etc.)
3. Writes them to the secrets tmpfs (Mechanism 2) — the sandbox sees the new values immediately
4. Returns a confirmation message **without the credential values**: `"AWS credentials refreshed (valid until 14:32 UTC)"`

The agent never sees the actual credential values in tool output — just the confirmation.

**Interaction pattern the agent would use:**
```
[agent calls bash tool] aws s3 ls
→ "An error occurred (ExpiredTokenException)"
[agent calls refresh_credentials tool with args: { provider: "aws" }]
→ "AWS credentials refreshed, valid for 55 minutes"
[agent calls bash tool] aws s3 ls
→ (success)
```

**Configuration**:
```sexp
(sandbox
  (credential_providers
    ((name "aws")
     (type aws_default_chain)   ; uses the host's AWS SDK default chain
     (refresh_before_expiry_s 300))   ; refresh 5 min before expiry
    ((name "github")
     (type env_var)
     (source_var "GITHUB_TOKEN"))))
```

### Mechanism 4: Credential process proxy — OUT OF SCOPE (forward-compat notes only)

For AWS specifically, the SDK supports a `credential_process` config key: a command that returns credentials as JSON on stdout. We could set this to a small binary (`pera-cred-proxy`) that:
1. Communicates with the harness via a Unix socket bind-mounted into the sandbox
2. The harness holds the actual credentials outside the sandbox
3. The proxy fetches and returns them on demand, but they never live inside the sandbox as files

```ini
# ~/.aws/config inside sandbox
[default]
credential_process = pera-cred-proxy aws
```

The proxy binary speaks the [AWS credential process protocol](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html):
```json
{
  "Version": 1,
  "AccessKeyId": "...",
  "SecretAccessKey": "...",
  "SessionToken": "...",
  "Expiration": "2026-07-01T15:30:00Z"
}
```

This is **the most secure pattern** (credentials never persist inside the sandbox even as files — fetched on demand), **but it is out of scope now** that we've decided not to support Docker/remote sandboxes yet. Notes retained so nothing we design now conflicts with adding it later (it'll be needed for remote/Docker backends when those land).

### Mechanism 5: Startup env script

The user provides a shell script path; the harness reads it from the host and sources it in the sandbox shell at startup (or re-sources on credential refresh). The script exports secrets as env vars.

```sexp
(sandbox
  (env_script "/home/user/.config/pera/sandbox-env.sh"))
```

The script:
```bash
export AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
```

This runs the host's `aws` CLI **outside** the sandbox to extract creds, then the harness injects the output as env vars. The env script approach is familiar and flexible — the user controls exactly what gets injected.

**For mid-session refresh**: the harness can re-source the env script by sending the `source /run/pera/secrets/env-refresh.sh` command to the persistent shell's stdin — but this is tricky because re-sourcing doesn't un-export previously-set vars.

### Recommended design for pera

**Decided**: Mechanism 3 (on-demand agent-triggered refresh) is the primary pattern for dynamic credentials. Reasons:
- It naturally handles interactive flows like AWS SSO, where the user must open a browser and authenticate — the harness can notify the user and wait for completion before returning to the agent.
- The agent knowing that a refresh happened (and why) is useful context for it to handle retries correctly.
- Background silent refresh (Mechanism 2 alone) doesn't work for SSO or any auth flow requiring user interaction.

Layer these mechanisms, ordered by use case:

| Use case | Mechanism |
|---|---|
| Simple static API keys | `env_passthrough` list |
| AWS creds with SSO or STS | Mechanism 3: agent-triggered refresh + tmpfs write |
| AWS creds (no interactive auth) | Mechanism 2: harness background-refreshes tmpfs file; Mechanism 3 as fallback |
| OAuth tokens (GitHub, etc.) | Mechanism 2 (silent background refresh) + Mechanism 3 fallback |
| Custom startup env setup | `env_script` sourced at session start |
| Most secure (file-free) | ~~Mechanism 4~~ — **deferred / out of scope** (see above) |

**SSO interactive refresh flow**:
1. Agent calls `refresh_credentials { provider: "aws-sso" }`
2. Harness detects SSO is required, emits a notification `agent_event` to subscribers
3. CLI renderer displays: `[pera] AWS SSO login required — browser opening...`
4. Harness triggers `aws sso login` (or equivalent) on the host, outside the sandbox
5. User completes the browser flow
6. Harness writes fresh credentials to the secrets tmpfs (`/run/pera/secrets/aws-credentials`)
7. Tool returns to agent: `"AWS SSO credentials refreshed, valid for 8 hours"`
8. Agent retries the failed command

The harness's fan-out event system (already in `Agent_harness.subscribe`) is the right channel for step 2 notifications — no new event bus needed. **The same channel is reused for shell-crash notifications** (see shell lifecycle above).

**Secret scrubbing from logs**: values injected via any of these mechanisms must never appear in session JSONL entries. The session writer must not log env var values, and the `refresh_credentials` / `refresh_environment` tools must return only metadata (not the credential values) as their tool result.

**On hiding secrets from `env` inside the sandbox**: there is no practical way to hide env vars from a process that has them — `env`/`printenv` will always expose them. The correct approach is: *don't put secrets you want hidden in env vars*. For credentials that must stay confidential from the LLM's context window, use the tmpfs-file approach (Mechanism 2). The `env_passthrough` list is appropriate for secrets where seeing the value in a tool output is acceptable (e.g. a public-ish token with no destructive scope).

**Config additions**:
```ocaml
type credential_provider_type =
  | Aws_default_chain     (* uses host AWS SDK credential chain, supports SSO *)
  | Env_var of { source : string }
  | File of { path : string; format : [ `Aws_credentials | `Dotenv | `Raw_export ] }
  | Command of { argv : string list }  (* arbitrary command that emits credentials *)
[@@deriving sexp, ...]

type credential_provider = {
  name : string;                          (* identifier used with refresh_credentials tool *)
  provider_type : credential_provider_type;
  refresh_before_expiry_s : int option;   [@sexp.option]  (* background pre-refresh window *)
  target_path : string option;            [@sexp.option]  (* write path inside sandbox *)
  interactive : bool option;              [@sexp.option]  (* may require user interaction, eg SSO *)
}
[@@deriving sexp, ...]

(* Add to sandbox_config: *)
  credential_providers : credential_provider list;  [@sexp.default []]
```

---

## Stage 0 — MVP: Persistent Shell

**Goal**: ship a usable persistent shell with no new OS dependencies. The single biggest gap today is that `cd` does not survive between tool calls. This stage fixes that.

### What it delivers

- The agent can `cd` to a directory and subsequent bash/grep tool calls run there.
- `export`, shell functions, and aliases persist across tool calls within a session.
- Works on any host where `/bin/bash` exists (Linux and macOS with no extra packages).
- stdout and stderr are captured on genuinely separate fds (not shell-side `2>&1`) and timestamped per line by the harness, so tool output can be reconstructed in true wall-clock order, filtered to one stream when needed (e.g. machine-parseable `--json` output), and carries per-command timing for spotting hangs/slow steps — without any platform-specific code, since it's pure Eio pipe plumbing on both macOS and Linux.
- Shell crash (e.g. agent types `exit`, script calls `exit 0`) is detected, the shell is restarted, state is replayed from the last snapshot, and a `Shell_restarted` event is surfaced to the agent so it knows to re-establish anything that was not snapshotted.
- `--persistent-shell=false` reverts to the current stateless `/bin/sh -c` model (CI / debug escape hatch).

### What is deferred

- OS kernel sandbox (bwrap, sandbox-exec) — Phase 1.
- `Fs` substitution / containment gate — agents can still escape the workdir via tools until Phase 1. Accepted risk for Stage 0.
- `--sandbox` / `--no-sandbox` flag — nothing backs it yet; added in Phase 1.
- Secret injection mechanisms (`env_passthrough` allowlist enforcement, secrets tmpfs, `refresh_credentials`) — Phase 1 / later.
- Path remapping — Phase 2.

### Sentinel protocol: three channels, harness-side timestamps

Each `exec` call communicates with the persistent bash over three pipes set up at spawn time: stdout (fd 1), stderr (fd 2), and a private state channel (fd 3) that user commands never touch.

1. Generate a unique per-call sentinel: `SENTINEL = "PERA_DONE_" ^ uuidv4_hex ()`.
2. Write to shell stdin:
   ```
   ( <user_command> )
   printf '\n' 1>&1; printf '\n' 1>&2
   echo "$? $SENTINEL" 1>&1
   echo "$SENTINEL" 1>&2
   ```
3. Read stdout and stderr **concurrently**, one fiber per fd, each **line by line** until its own sentinel line arrives (`"<exit_code> <SENTINEL>"` on stdout; bare `"<SENTINEL>"` on stderr). Bash only reaches the `echo ... $SENTINEL` lines after the subshell and everything it forked has fully exited, and pipe writes/reads are ordered per fd, so seeing a fd's sentinel guarantees that fd's output for this command is fully drained — no merge required to know completion.
4. As each line is read off either fd, the harness timestamps it (`Eio.Time.now`) independently of the shell.
5. Strip the sentinel lines and return `exec_result` with flattened `stdout : string` / `stderr : string` (for compatibility) plus an ordered list of `(stream, timestamp, line)` chunks that callers can merge-sort to reconstruct true wall-clock interleaving without ever forcing both streams through one fd.

Wrapping in `( ... )` makes the subshell exit code reflect `<user_command>`. The UUID sentinel makes collisions with command output astronomically unlikely, on either stream.

**Why not `2>&1` + a single sentinel (rejected):** merging at the shell level throws away the stream tag before the harness ever sees two streams, and forecloses separating them later without redesigning the protocol. It also isn't necessary — a real interactive shell already keeps stdout/stderr as distinct fds; `2>&1` was the artificial addition, not the default. The known cost of true separation (knowing when *both* streams are done, not just one) is solved by sentinel-per-fd, not by merging.

**Streaming (exit plan):** the per-fd line readers already have the right structure for streaming — for MVP, lines are accumulated into buffers and returned at end. To enable streaming later, call `on_stdout`/`on_stderr` immediately for each non-sentinel line instead of accumulating; both callbacks receive real content now (no `2>&1` constraint to document, unlike the earlier draft).

**Known limitation (documented, accepted, not new):** many programs fully block-buffer stdio when writing to a pipe rather than a tty, so a captured timestamp means "when the harness received the flushed chunk," not the instant it was produced. True of today's `Local_env` pipe capture too; not solved here (pty allocation is a possible future improvement, out of scope for Stage 0).

### Timeout: SIGINT + grace

On timeout expiry:
1. Send **SIGINT** to the shell's process group (stops the running subprocess; shell itself typically survives).
2. Continue reading **both** sentinel loops (stdout and stderr) for a **5 s grace period**.
3. If **both** sentinels arrive within grace → return the (interrupted) result normally.
4. If either is still missing when grace expires → send **SIGKILL** to the shell process and enter the crash-restart path (see below).

This means a timeout does not necessarily kill the shell — SIGINT may stop only the running child command while the shell remains alive and stateful. Waiting on both fds (rather than one) matters now that stdout/stderr aren't merged: a command could finish writing to one stream well before the other.

### State snapshot and crash recovery

**Snapshot (out-of-band, same round-trip, fd 3):** rather than a second stdin/stdout exchange after every command (doubling latency and reusing the channel a command just used), the snapshot capture rides the private state channel opened at spawn time, appended to the *same* wrapper send as the command itself:

```bash
{ declare -px ; declare -f ; alias -p ; shopt -p ; set +o ; pwd ; echo "$SENTINEL" ; } 1>&3
```

The fd-3 reader is its own fiber and does **not** gate the tool call's return to the agent — the result comes back as soon as the stdout/stderr sentinels land; the snapshot updates shortly after, once its own sentinel arrives on fd 3. The result is stored **in pera-cli memory only** (never written to a file the agent can read, and never sandbox-readable). For Stage 0, the snapshot captures all exported vars without filtering; tighten to the `env_passthrough` allowlist when `--sandbox` lands in Phase 1 (before that, there is no security boundary to protect).

**What the snapshot does NOT cover** (documented gap, kept simple by design):
- Traps (`trap`), background jobs, directory stack (`pushd`/`popd`), `PIPESTATUS`, `BASH_REMATCH`.
- `source` invocations: replaying source scripts has unpredictable side effects (network calls, interactive auth, venv creation). We do **not** replay them — the agent receives `Shell_restarted` and can re-source manually. This is the right long-term decision: replay should stay dumb.
- State accumulated since the last completed command (in-flight commands lost on crash).

**Restart procedure:**
1. Detect EOF on stdout, stderr, or fd 3 (shell died) or SIGKILL after grace expiry.
2. Spawn a fresh bash.
3. Source the last-known snapshot into it (sets env, functions, aliases, options, cwd).
4. Emit `Shell_restarted { state_restored : bool }` agent event via the existing `Agent_harness.subscribe` fan-out. `state_restored = true` if a snapshot existed; `false` if the shell died before any snapshot was captured.
5. Return an `Error execution_error` for the command that was in flight at crash time.

### Files and seams

| File | Change |
|---|---|
| `lib/pera_env/execution_env.mli` | Add `val is_stateful : bool` to `SHELL` sig |
| `lib/pera_env/local_env.ml` | `Sh.is_stateful = false` (no behaviour change) |
| `lib/pera_env/persistent_shell.{ml,mli}` | **New** — spawn bash with 3 fds (stdout/stderr/state); per-fd sentinel exec loop with `?on_stdout`/`?on_stderr` and harness-side per-line timestamps; state snapshot via fd 3 (same round-trip, non-gating); SIGINT+grace timeout waiting on both stdout+stderr sentinels; crash detection (EOF on any of the 3 fds) → restart → snapshot replay; `close` |
| `lib/pera_tools/bash_tool.ml` | Drop `?cwd:(Some E.cwd)` override when `E.Sh.is_stateful` |
| `lib/pera_tools/grep_tool.ml` | Same |
| `lib/pera_cli/pera_config.ml` | Add `persistent_shell : bool` field (default `true`) |
| `lib/pera_cli/pera_cli.ml` | Wire `Persistent_shell`-backed env when `persistent_shell = true`; pass `Local_env` when `false` |
| `lib/pera_types/types.ml` | Add `Shell_restarted of { state_restored : bool }` variant to `agent_event` |

---

## Open design questions

- **Shell restart on crash** — **Decided**: notify the agent (via the `Agent_harness.subscribe` fan-out) so it can reinitialise shell state; preserve state via the hybrid snapshot/replay procedure (env allowlist + host-side storage + secret re-fetch; documented that traps/jobs/history are not restorable).
- **bwrap availability** — **Decided**: if `--sandbox` is requested and the chosen backend cannot start (bwrap missing on Linux, `sandbox-exec` unavailable on macOS), **pera-cli exits with a clear error**. No silent fallback to `Persistent_shell`/no-sandbox. Strict on/off; no `Auto` variant.
- **Startup latency**: bwrap shell startup adds ~50ms. Acceptable for interactive use.
- **Tmpdir home cleanup**: The fresh home directory under `$TMPDIR` should be cleaned up at session end. Can be done with a resource cleanup via Eio Switch.
- **`find_executable` inside sandbox**: Currently `Local_env.Sh.find_executable` searches the host's `PATH`. For sandbox env, this is fine since we inherit `PATH` (or pass through it). No change needed.
- **Init script approach**: A startup shell script (user-configured) sourced by the persistent shell at startup (via bash's `--init-file` flag or source in first command). This is how you'd set up tools, PATH additions, etc.

---

## Appendix: Integration test strategy for shell persistence (2026-07-05)

### Prior art surveyed

**pexpect's `replwrap.py`** is the closest existing analogue to the sentinel protocol above — it wraps a REPL by rewriting its prompt to a unique sentinel and reading until the sentinel reappears. Notable for pera:
- It has to **special-case bash vs zsh** even though both are "just shells": bash needs the sentinel wrapped in `\[...\]` non-printable markers (so line-editing doesn't miscount it), zsh needs `%(!..)` conditional syntax instead. This previews what would bite pera if the persistent-shell backend is ever generalized past bash — **the sentinel-emission snippet is not portable shell syntax**.
- It disables paging (`PAGER=cat`) at REPL init — same class of problem pera's fd-3 snapshot step (`declare -px`, etc.) will have if a command invokes a pager or `$EDITOR` mid-session.

**OSC 133 "semantic prompt" shell integration** (used by VSCode, iTerm2, kitty, ghostty, wezterm) solves the same "detect a command boundary/exit code" problem, across the same shell set pera cares about:
- **bash**: hooks via `PROMPT_COMMAND`/`PS0`/`PS1` string injection — structurally similar to pera's approach.
- **zsh**: uses `precmd`/`preexec` functions and opens a **dedicated fd to the tty** so marks still emit even when stdout is redirected — a fundamentally different mechanism than string-based prompts.
- **fish**: uses **event hooks** (`fish_prompt`, `fish_postexec`), not PS1 manipulation at all — fish's prompt isn't a plain string, so a bash-style "marker in PS1" trick doesn't transfer.
- fish-shell issue [#8832](https://github.com/fish-shell/fish-shell/issues/8832) documents that even fish's own idiomatic mechanism for this has known gaps: the `fish_prompt` event doesn't fire after a cancelled command or syntax error. Concrete evidence that "detect command completion in a shell-agnostic way" is a genuinely hard, previously-mis-solved problem, not a solved one.

**oils-for-unix (`oilshell/oils`) spec test suite** is the best model for *methodology* (not protocol): thousands of small shell snippets run through `bash`, `dash`, `zsh`, `mksh` (and `osh`) via a `compare_shells` directive, with explicit per-shell **qualifiers** for known divergence rather than an expectation of uniform output. This is the right shape for a pera cross-shell fixture suite if the persistent-shell backend ever becomes multi-shell.

**ShellSpec** (BDD framework for bash/ksh/zsh/dash/POSIX) is worth noting as an existing "write once, run across shells" test runner, though it tests shell *scripts*, not a wrapper's IPC protocol.

Sources: [pexpect replwrap](https://github.com/pexpect/pexpect/blob/master/pexpect/replwrap.py), [oils Spec Tests wiki](https://github.com/oils-for-unix/oils/wiki/Spec-Tests), [ghostty OSC 133 docs](https://deepwiki.com/ghostty-org/ghostty/9.3-osc-133-prompt-marking), [fish-shell #8832](https://github.com/fish-shell/fish-shell/issues/8832), [ShellSpec](https://shellspec.info/).

### Two test axes (important scope split)

Stage 0 only ever spawns **bash** (falling back to `/bin/sh`) as the *outer* persistent process — zsh/dash/fish are never the wrapper's own interpreter in the current design. "Test across bash/zsh/dash/fish" therefore splits into two axes with different payoff and different failure modes:

1. **Outer-shell axis** (forward-looking; only matters if the wrapper is ever made to run the user's `$SHELL` instead of a hardcoded bash). Does the sentinel-emission snippet even parse in the candidate shell? `dash` is POSIX-strict — fine, the snippet is POSIX. `zsh` is bash-compatible enough — fine. **`fish` is not a POSIX shell**: `( cmd )` in fish means command substitution, not a subshell; `$?` doesn't exist (`$status` does); `echo "$? $SENTINEL"` is invalid fish syntax outright. If outer-shell choice is ever exposed, the emission snippet needs a fish-specific variant, mirroring the OSC 133 finding above.
2. **Inner/nested-shell axis** (relevant *today*, bash-only). The agent's *commands*, run inside the one persistent bash, can themselves invoke `zsh -c`, `fish -c`, `dash script.sh`, subshells, background jobs, another REPL, `ssh`, etc. This is where "concurrency, subshells, interference" actually bites Stage 0, and is the higher-priority axis to build coverage for first.

### Reflection: no PTY is a correctness risk, not just a timestamp-fidelity footnote

The plan currently documents block-buffering under pipe capture as a "known limitation, accepted, not new." Absence of a PTY is broader than that — it changes whether whole classes of commands *work at all*, not just how precisely their output is timestamped:

- Programs that branch on `isatty(1)`/`isatty(0)` change behavior under a pipe: `git` drops color/pager, progress bars (`pip`, `npm`, `docker pull`) degrade or spam newlines, interactive installers (`npm init`, `gh auth login`, `aws configure sso`) may refuse to run or hang waiting on input that can never arrive.
- `sudo` (with `requiretty`), `ssh` password prompts, and `gpg`/`pinentry` **deliberately refuse piped stdin** for credential entry — these hang until timeout rather than failing fast.
- No controlling tty means no `SIGWINCH`/window size (`stty: standard input: Inappropriate ioctl for device`) and no real job-control signal semantics (`Ctrl-Z`/`SIGTSTP`, `fg`/`bg`).
- This touches the secret-injection SSO flow above: the plan correctly routes `aws sso login` through a dedicated harness-side tool "outside the sandbox," not through `Sh.exec` — good, that sidesteps the issue for the built-in flow. But nothing stops an agent from independently running `aws sso login` or `gh auth login` directly in the persistent shell; that path *will* hang with no pty.

**Recommendation:** promote "requires a tty" to a named, tested failure class for Stage 0 (test that it hangs *safely* and is recovered by the existing SIGINT+grace+timeout path, not that it's supported), and reprioritize pty allocation (`openpty`) from "possible future improvement" to an early Phase 1 candidate — it changes usability of whole workflows (interactive auth, editors, REPLs left running), not just timestamp precision.

### Proposed test matrix

| Category | Scenarios | Why it can break the wrapper |
|---|---|---|
| Sentinel correctness | output containing a string matching the `PERA_DONE_*` pattern (adversarial echo); partial line then hang; no trailing newline before exit; empty/whitespace-only command | False sentinel match ends the read early, or never matches |
| Subshells & grouping | `( cd /tmp && pwd )` (must not leak cwd to parent); `{ cmd; }` group; `cmd1; cmd2 &` background job outliving the sentinel; `nohup long &`; `disown` | A backgrounded job can inherit the write end of stdout/stderr and keep the pipe open past the sentinel line — the single most common real-world failure mode for this design (hung read on next call) |
| Nested interpreters | `python3` left running (agent forgets to exit) then next `Sh.exec`; `zsh -c`, `fish -c`, `dash script.sh`; `ssh host 'cmd'` | Confirms the sentinel-on-stdin design is agnostic to what runs underneath, and that a wedged nested process surfaces as a timeout, not corruption of the next command's read |
| Concurrency / reentrancy | two `Sh.exec` calls issued back-to-back without awaiting the first; cancellation of call N while call N+1 is queued; fd-3 snapshot fiber racing the next command's stdin write | Confirms the harness actually serializes access to the shared stdin/fds rather than allowing interleaving |
| Signals / timeout | `sleep 100` timeout → SIGINT → grace → shell survives, next command runs in same cwd; command that traps and ignores SIGINT; orphaned grandchild that ignores SIGINT | Validates "SIGINT stops the child, shell survives," including the SIGKILL fallback path |
| Crash & restart | bare `exit`; `exit 0` inside a sourced script; `kill -SEGV` on the shell pid; `kill -9` mid-command | `Shell_restarted` fires, snapshot replay works, the in-flight command surfaces as `Error`, not a hang |
| Snapshot fidelity | export/function/alias/`shopt`/`set -o` survive crash+restart; **negative case**: a `trap` set before crash is *not* restored — assert it's actually gone, not flaky | Confirms documented gaps are real gaps, not intermittently-working |
| cwd/env override removal | `bash_tool`/`grep_tool` no longer pass `?cwd` when `is_stateful`; `cd` in one call then a relative-path command in the next resolves correctly; `cd` into then `rm -rf` the cwd itself | Direct regression test for the Stage-0 core fix |
| Buffering / streaming / interleaving | alternating stdout/stderr writes with sleeps between (timestamp-based merge reconstructs true order); fully-buffered vs line-buffered program; multi-MB output on one fd while the other is idle (no pipe-backpressure deadlock) | Validates the three-fd concurrent-reader design under backpressure, not just the happy path |
| TTY-dependent hangs | `read -p` with nothing on stdin; `sudo -S` with no password piped; `ssh` awaiting host-key confirmation; anything invoking `$PAGER`/`$EDITOR` | Confirms these degrade to hang → timeout → recover, not an unrecoverable wedge or corrupted next-command state |
| Cross-shell emission snippet (axis 1, smoke-level) | run the sentinel-emission snippet verbatim through `dash` and `zsh` even though neither is wired as a backend yet | Cheap insurance against the fish-incompatibility trap if outer-shell choice is ever generalized |

### Suggested structure

- Unit-level alcotest coverage (a new `persistent_shell_test.ml` alongside the existing `local_env_sh_test.ml`/`bash_tool_test.ml` pattern) for the concurrency/signal/crash/snapshot categories — these need Eio control, not just shell scripts.
- For the cross-shell axis, borrow oils' approach directly: a small directory of fixture snippets with expected `(stdout, stderr, exit_code)` tuples, run through whichever shell binaries are present in CI (`which dash zsh fish || skip`), with per-shell "known divergence" annotations rather than requiring identical output everywhere.