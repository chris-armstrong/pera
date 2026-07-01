# Sandbox Execution Environment — Planning Document

**Status**: Research / pre-proposal  
**Date**: 2026-07-01  
**Branch**: bridge-cse_01Qyur6Fg8v7neexJujzV8V1

---

## Goal

Add a sandbox execution environment: a long-running shell process (inside a namespace container or OS sandbox) whose state (cwd, env vars, shell functions) is preserved across tool calls. This differs from the current `Local_env`, which spawns a fresh `/bin/sh -c` process per call.

### Key requirements

1. **Shell state preserved** — `cd`, `export`, `alias`, etc. survive across consecutive bash tool calls within a session.
2. **Filesystem isolation** — the sandboxed shell gets a fresh home directory; it cannot write to the real `$HOME` unless explicitly permitted.
3. **Path remapping** — the workdir can be bind-mounted at a configurable sandbox path, or at the same host path. Host system tools remain accessible (read-only).
4. **Configurable environment** — a list of env vars to pass through from the harness, or a startup script to source inside the sandbox shell.
5. **Linux + macOS support** — different isolation backends, same `Execution_env.S` interface.

---

## Current architecture context

### `Execution_env.S` (lib/pera_env/execution_env.mli)

```
module type S = sig
  val cwd : string          (* initial working directory *)
  module Fs : FILESYSTEM    (* file operations via Eio / host OS *)
  module Sh : SHELL         (* shell execution *)
end
```

`SHELL.exec` takes optional `?cwd`, `?env`, `?timeout` per call.  
`Local_env` implements `Sh` by spawning `["/bin/sh"; "-c"; command]` fresh each call.

### Critical current issue: cwd is not preserved

`bash_tool.ml` and `shell_tool_builder.ml` both pass `?cwd:(Some E.cwd)` on every `Sh.exec` call. This means even with a persistent shell, callers override cwd every time. This must change for the persistent shell case.

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
  - `--unshare-pid` — PID namespace
- Available as system package (`bubblewrap`), also installable via opam/nix.
- Check availability: `which bwrap` or `bwrap --version`.

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
- Alternative for macOS: Virtualization.framework (heavy, needs entitlements), Docker (daemon required).

### macOS fallback: Fresh-homedir-only mode

Without strong isolation, we can still achieve useful sandboxing:
- Create `$TMPDIR/pera-sandbox-<session-uuid>/` as a fresh home.
- Set `HOME` to that path before spawning the shell.
- Block writes to the real `$HOME` via `sandbox-exec` profile.
- System tools, PATH, etc. inherited from harness.
- "Soft sandbox" — prevents accidental dotfile corruption; not network-isolated.

### Cross-platform: Docker/Podman

- Very portable, strong isolation.
- Requires daemon process. Heavy for per-session use.
- Better fit for remote/VM sandboxes (the "slave process" path).
- Can be a sandbox backend type but not the default.

### Linux-only alternatives

- **landlock** (kernel 5.13+): in-process path restriction via syscall, no child process. Restricts the pera process itself rather than a subprocess. Useful if we want to lock down pera's own file access, not for sandboxing agent commands.
- **firejail**: user-space, richer profiles than bwrap but more complex. Not available on macOS.
- **nsjail** (Google): strong namespaces + seccomp. More complex setup, not commonly pre-installed.

---

## Persistent shell design

### Why a persistent shell

Current model: each `Sh.exec` call spawns `/bin/sh -c <command>`, runs, dies. No state.  
Persistent model: one long-lived shell process (bash). Each tool call sends a command to it and reads back the result.

State preserved between calls: cwd, exported env vars, shell functions, history, jobs (if not backgrounded).

### Protocol: stdin/stdout with sentinel

No slave binary needed for local sandboxes. We communicate directly with the shell over its stdin/stdout pipes.

**Per-command protocol:**

1. Generate a unique per-call sentinel: `SENTINEL = "PERA_DONE_" + uuidv4_hex()`
2. Write to shell stdin:
   ```
   ( <user_command> ) 2>&1
   printf '\n'
   echo "$? $SENTINEL"
   ```
3. Read stdout lines until a line matches `"<exit_code> <SENTINEL>"`.
4. Everything before that line is the command's combined stdout+stderr output.
5. Strip the sentinel line; return output and exit code.

**Why this works:**
- UUID sentinel is unique per call — collisions with command output are astronomically unlikely.
- Wrapping in `( ... )` makes the exit code of the subshell reflect `<user_command>`.
- `2>&1` inside the subshell redirects stderr to stdout (matching current bash_tool behavior).
- `printf '\n'` ensures a clean newline before the sentinel even if command output ended without one.

**Cancellation and timeout:**
- A separate Eio fiber monitors `Eio.Cancel.t`; if cancelled, sends SIGINT to the shell process (not SIGKILL — allows the shell to clean up).
- For timeout, use `Eio.Time.with_timeout_exn`; on expiry, send SIGINT and wait for the sentinel (with a short grace period), then send SIGKILL if still unresponsive.
- If the shell process dies unexpectedly, reads from stdout will hit EOF. The env should detect this and restart the shell or return an error.

### Shell selection

Default to `/bin/bash` for state-preserving semantics (arrays, `BASH_SOURCE`, etc.). Fall back to `/bin/sh` if bash not found.

---

## Module design

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
(** Sends [command] to the persistent shell and reads back the result. *)

val close : t -> unit
(** Sends 'exit' to the shell and waits for it to terminate. *)
```

### New module: `pera_env/sandbox_env.{ml,mli}`

Implements `Execution_env.S` using a `Persistent_shell.t`.

```ocaml
type sandbox_config = {
  backend : [ `None | `Bwrap of bwrap_config | `Sandbox_exec of string (* profile *) ];
  workdir_mount : [ `Same_path | `At of string (* sandbox path *) ];
  fresh_home : string option;   (* None = derive from tmpdir; Some p = use p *)
  env_passthrough : string list;  (* env var names to copy from harness *)
  env_script : string option;   (* path to shell script to source at startup *)
  extra_ro_mounts : (string * string) list;  (* (host, sandbox) read-only *)
  extra_rw_mounts : (string * string) list;  (* (host, sandbox) read-write *)
}

and bwrap_config = {
  bwrap_path : string;          (* path to bwrap binary *)
  unshare_net : bool;           (* default false *)
  unshare_pid : bool;           (* default false *)
}

val create :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  cwd:string ->
  config:sandbox_config ->
  (module Execution_env.S)
```

`Fs` module: same as `Local_env` (host Eio filesystem). For path consistency, the workdir bind-mount should use the same host path inside the sandbox (or provide a `Fs` that translates paths if `workdir_mount = `At sandbox_path`).

### `Execution_env.SHELL` signature change

Add:
```ocaml
val is_stateful : bool
(** [true] if shell state (cwd, env) is preserved between exec calls.
    Stateful shells ignore the [?cwd] and [?env] per-call overrides. *)
```

`Local_env.Sh.is_stateful = false`  
`Sandbox_env.Sh.is_stateful = true`

### `bash_tool.ml` change

When `E.Sh.is_stateful = true`, do NOT pass `?cwd:(Some E.cwd)`. Let the shell maintain its own cwd.

```ocaml
let cwd_arg = if E.Sh.is_stateful then None else Some E.cwd in
E.Sh.exec ~command ?cwd:cwd_arg ...
```

Same change in `shell_tool_builder.ml`.

### `pera_config` changes

New config section:

```ocaml
type sandbox_backend =
  | No_sandbox
  | Persistent_shell   (* state preserved, no isolation *)
  | Bubblewrap         (* Linux: bwrap *)
  | Sandbox_exec       (* macOS: sandbox-exec *)
  | Auto               (* pick best available for platform *)
[@@deriving sexp, ...]

type sandbox_config = {
  backend : sandbox_backend option;   [@sexp.option]   (* default: None = No_sandbox *)
  env_passthrough : string list;      [@sexp.default []] (* env var names *)
  env_script : string option;         [@sexp.option]
  unshare_network : bool option;      [@sexp.option]   (* bwrap only *)
  extra_ro_paths : string list;       [@sexp.default []]
  extra_rw_paths : string list;       [@sexp.default []]
}
[@@deriving sexp, ...]

type config = {
  ...
  sandbox : sandbox_config option;    [@sexp.option]
  ...
}
```

### `pera_cli/pera_cli.ml` / `Cli_env` changes

The `Env` module type already has `create ~env ~sw ~cwd`. A new `Sandbox_cli_env` implementation that reads sandbox config and creates the appropriate env.

Or: the existing `Make (Cli_env : Env)` functor's `resolve_exec_env` reads sandbox config from `rc` and calls `Sandbox_env.create` when configured.

---

## Seams that need work

| Location | Change |
|---|---|
| `lib/pera_env/execution_env.mli` | Add `val is_stateful : bool` to `SHELL` |
| `lib/pera_env/local_env.ml` | `Sh.is_stateful = false` |
| `lib/pera_env/persistent_shell.{ml,mli}` | **New** — persistent shell proc |
| `lib/pera_env/sandbox_env.{ml,mli}` | **New** — sandbox-backed Execution_env.S |
| `lib/pera_env/dune` | Add new modules |
| `lib/pera_tools/bash_tool.ml` | Don't pass `?cwd` when stateful |
| `lib/pera_tools/shell_tool_builder.ml` | Same |
| `lib/pera_cli/pera_config.ml` | New `sandbox_config` type |
| `lib/pera_cli/config_resolver.ml` | Resolve sandbox config |
| `lib/pera_cli/pera_cli.ml` | Create appropriate env based on sandbox config |
| `lib/pera_agent/agent_harness.mli` | Possibly carry sandbox config through |

---

## Questions for user (open)

1. **Scope**: Keep `Persistent_shell` and `Sandbox_env` inside `pera_env`, or new `pera_env_sandbox` package? (`pera_env` currently has zero deps beyond pera_types/Eio — adding bwrap detection is fine, no new library deps.)

2. **macOS approach**: `sandbox-exec` (SBPL, ships with macOS, deprecated-ish) or just fresh-homedir-only as a first pass? Docker as optional backend?

3. **Filesystem view**: Keep `Fs` on host paths (simpler, slight inconsistency if workdir is remapped inside sandbox) — or translate paths in `Fs` too?

4. **Persistent-shell-only mode** (no isolation, just state preservation): Worth having as a named mode? Useful for dev/testing without needing bwrap.

5. **Changing `bash_tool` cwd behavior now**: The current `?cwd:(Some E.cwd)` prevents cwd persistence even without sandboxing. Fix it now (guarded by `is_stateful`) or defer?

6. **Remote/VM sandbox slave protocol**: For now out of scope, but do you want the plan to include the protocol design so the architecture is ready for it?

7. **Default**: Sandboxing opt-in (user adds `(sandbox (backend auto))` to config) or opt-out?

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

### Mechanism 1: env_passthrough (static, simple)

Already in the config design. At sandbox startup, named env vars are copied from the harness process into the sandbox shell's environment.

```sexp
(sandbox
  (env_passthrough (OPENAI_API_KEY GITHUB_TOKEN NPM_TOKEN)))
```

**Pros**: trivial, standard.
**Cons**: static — refresh requires restarting the session. Also, `env` or `printenv` inside the sandbox exposes all of them to the agent in a single shot (prompt injection risk).

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
**Cons**: the agent can `cat /run/pera/secrets/aws-credentials` and see the raw values (then the LLM sees them). Mitigated by file permissions (mode 0400, owned by sandbox user) — but in practice, if the agent is the sandbox user, it can still read them. True isolation of secrets from the agent requires the credential proxy pattern (Mechanism 4).

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

### Mechanism 4: Credential process proxy (AWS-native, most secure)

For AWS specifically, the SDK supports a `credential_process` config key: a command that returns credentials as JSON on stdout. We can set this to a small binary (`pera-cred-proxy`) that:
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

The credentials are fetched from the harness over the Unix socket each time the AWS SDK calls `pera-cred-proxy`. The harness decides whether to return cached creds or refresh them. This is **the most secure pattern**: credentials never persist inside the sandbox even as files — they're fetched on demand.

**Complexity**: requires a small binary (`pera-cred-proxy`) to be on the sandbox's PATH, plus a Unix socket protocol between harness and proxy.

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
- The proxy binary (Mechanism 4) is acceptable and will be needed anyway for remote/Docker sandboxes.

**Decided**: Small proxy processes are in scope. The same `pera-cred-proxy` binary (or equivalent) will serve both local and remote sandbox configurations.

Layer these mechanisms, ordered by use case:

| Use case | Mechanism |
|---|---|
| Simple static API keys | `env_passthrough` list |
| AWS creds with SSO or STS | Mechanism 3: agent-triggered refresh + tmpfs write |
| AWS creds (no interactive auth) | Mechanism 2: harness background-refreshes tmpfs file; Mechanism 3 as fallback |
| OAuth tokens (GitHub, etc.) | Mechanism 2 (silent background refresh) + Mechanism 3 fallback |
| Credential process (most secure) | Mechanism 4: `pera-cred-proxy` Unix socket proxy |
| Custom startup env setup | `env_script` sourced at session start |

**SSO interactive refresh flow**:
1. Agent calls `refresh_credentials { provider: "aws-sso" }`
2. Harness detects SSO is required, emits a notification `agent_event` to subscribers
3. CLI renderer displays: `[pera] AWS SSO login required — browser opening...`
4. Harness triggers `aws sso login` (or equivalent) on the host, outside the sandbox
5. User completes the browser flow
6. Harness writes fresh credentials to the secrets tmpfs (`/run/pera/secrets/aws-credentials`)
7. Tool returns to agent: `"AWS SSO credentials refreshed, valid for 8 hours"`
8. Agent retries the failed command

The harness's fan-out event system (already in `Agent_harness.subscribe`) is the right channel for step 2 notifications — no new event bus needed.

**Secret scrubbing from logs**: values injected via any of these mechanisms must never appear in session JSONL entries. The session writer must not log env var values, and the `refresh_credentials` tool must return only metadata (not the credential values) as its tool result.

**On hiding secrets from `env` inside the sandbox**: there is no practical way to hide env vars from a process that has them — `env`/`printenv` will always expose them. The correct approach is: *don't put secrets you want hidden in env vars*. For credentials that must stay confidential from the LLM's context window, use the tmpfs-file approach (Mechanism 2) or the credential process proxy (Mechanism 4). The `env_passthrough` list is appropriate for secrets where seeing the value in a tool output is acceptable (e.g. a public-ish token with no destructive scope).

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

## Open design questions

- **Shell restart on crash**: If the persistent shell exits unexpectedly (e.g., `exit` was run in a command, or it segfaulted), should we restart it automatically, surface an error, or terminate the session?
- **bwrap availability**: On Linux systems without bwrap (some CI, distros, old kernels with user namespaces disabled), `Auto` backend should fall back to `Persistent_shell` (no isolation). Log a warning.
- **Startup latency**: bwrap shell startup adds ~50ms. Acceptable for interactive use.
- **Tmpdir home cleanup**: The fresh home directory under `$TMPDIR` should be cleaned up at session end. Can be done with a resource cleanup via Eio Switch.
- **`find_executable` inside sandbox**: Currently `Local_env.Sh.find_executable` searches the host's `PATH`. For sandbox env, this is fine since we inherit `PATH` (or pass through it). No change needed.
- **Init script approach**: A startup shell script (user-configured) sourced by the persistent shell at startup (via bash's `--init-file` flag or source in first command). This is how you'd set up tools, PATH additions, etc.
