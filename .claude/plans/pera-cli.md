# Pera CLI — specification

> Status: design draft v0.3 — open questions marked `[?]`.
> Covers: the `pera` binary, `pera_cli` library, config file format, skills loading,
> slash commands, tool extension points.
> Does NOT cover: implementation sequencing, M7 details (compact-model).

---

## Overview

The CLI layer splits into two OCaml packages:

**`pera-cli` (library, `lib/pera_cli/`)** — reusable wiring: argument parsing,
config loading, event rendering, the interactive input loop, skills loading, MCP
client, config-defined shell tool construction. It is generic over the tool
context type `'ctx`. Users who need a different execution environment (SSH,
Irmin, sandboxed, no-filesystem) write their own binary that links against
`pera-cli` and supplies their own env and tool set.

**`pera` (executable, `bin/pera/`)** — the standard binary. Composes `pera-cli`
with `Local_env` and the default four tools. Adds config-defined shell-backed
tools on top (requires local shell; the Local_env provides it). MCP tools are
added from config regardless of env.

Both packages are the only components that read environment variables or config
files; everything below them receives only typed parameters.

Three config sources are merged in order, lowest priority first:

```
built-in defaults
  ← user config       ($XDG_CONFIG_HOME/pera/config.sexp)
    ← project config  (.pera in nearest ancestor directory)
      ← env vars      (PERA_*)
        ← CLI flags   (--flag)
```

`[?-1]` **Env vars vs project config precedence.** Standard Unix convention
puts env vars above config files (a `PERA_MODEL=haiku` export in a shell
session should win over whatever the project pinned). Alternative: project
config above env vars, so a team `.pera` can enforce a model without each
developer having to unset their personal env. Proposal: keep the standard
order (env above config), document it clearly.

---

## Config file format

S-expressions, parsed with `sexplib` / `ppx_sexp_conv`. This keeps the config
structurally typed — the OCaml type is the schema; no separate parser is written.

### File locations

| File | Purpose |
|---|---|
| `$XDG_CONFIG_HOME/pera/config.sexp` | User defaults — API keys, personal model preference, output style |
| `.pera` in project root (walk up from cwd) | Project settings — model, cache policy, skill set, compaction |

Project config discovery walks up from the process cwd until `.pera` is found
or the filesystem root is reached (git-style). If none is found, only the user
config applies.

`[?-2]` **Project config filename.** `.pera` (no extension, like `.gitignore`)
vs `pera.sexp` vs `.pera.sexp`. Preference: `.pera` — visible, obvious, no
extension ambiguity since the format is stable. The sexp format does not need
an extension to be identified.

### Security: API keys in config

- `api_key` is **only accepted in the user config**. The parser rejects it in
  a project config and emits a loud error (`[pera] api_key may not appear in
  project config (.pera); use user config or PERA_API_KEY`).
- `api_key_file` and `api_key_command` are accepted in both.

---

## OCaml types (ppx_sexp_conv)

```ocaml
(** How the API key is sourced. *)
type api_key_source =
  | Key of string
    (** Literal key string. User config only. Emits a warning recommending
        a file or command source instead. *)
  | File of string
    (** Path to a file whose sole content is the key. Tilde-expanded. *)
  | Command of string list
    (** Argv of a helper binary. stdout (trimmed) is the key.
        Supports platform keychains:
          macOS:   (Command (security find-generic-password -s pera -w))
          Linux:   (Command (secret-tool lookup service pera))
          Windows: (Command (powershell.exe -Command
                     "(Get-StoredCredential -Target pera).Password")) *)
[@@deriving sexp]

type effort = Low | Medium | High
[@@deriving sexp]

type cache_policy = No_cache | Conversation | System_and_tools
[@@deriving sexp]

type cache_ttl = Five_minutes | One_hour
[@@deriving sexp]

type auth_config = {
  api_key : api_key_source option; [@sexp.option]
    (** Project config: only File and Command accepted; Key rejected. *)
} [@@deriving sexp]

type model_config = {
  api            : string option; [@sexp.option]  (** "anthropic" | "openai-completions" *)
  model          : string option; [@sexp.option]  (** Model ID *)
  base_url       : string option; [@sexp.option]  (** openai-completions endpoint override *)
  context_window : int    option; [@sexp.option]  (** Required when model not in built-in table *)
  effort         : effort option; [@sexp.option]
  max_tokens     : int    option; [@sexp.option]
} [@@deriving sexp]

type cache_config = {
  policy : cache_policy option; [@sexp.option]
  ttl    : cache_ttl    option; [@sexp.option]
} [@@deriving sexp]

type session_config = {
  dir : string option; [@sexp.option]
    (** Default: $XDG_STATE_HOME/pera/sessions/ *)
} [@@deriving sexp]

type skills_config = {
  dirs      : string list; [@sexp.default []]
    (** Extra directories to search beyond XDG data dirs *)
  available : string list; [@sexp.default []]
    (** Filter by front-matter name; empty list = all *)
  enabled   : bool option; [@sexp.option]
    (** false disables all skill loading; absent = true *)
} [@@deriving sexp]
(** Parsed in v1 but unused — skills loading is deferred to v2.
    Kept in the config type so project .pera files can include skills
    fields without breaking the parser when v2 ships. *)

type compaction_config = {
  threshold : int  option; [@sexp.option]  (** % of context window; default 70 *)
  tail      : int  option; [@sexp.option]  (** turns kept verbatim; default 4 *)
  enabled   : bool option; [@sexp.option]  (** false = --no-compact; absent = true *)
} [@@deriving sexp]

type output_config = {
  plain         : bool option; [@sexp.option]
  show_thinking : bool option; [@sexp.option]
  quiet         : bool option; [@sexp.option]
} [@@deriving sexp]

(** A user-defined slash command. *)
type command_def = {
  name        : string;  (** Invoked as /<name> *)
  description : string;  (** Shown in /info and skill catalogue *)
  template    : string;
    (** Injected as a user message. Substitution:
          {args}  — everything typed after the command name
          {1}, {2}, ... — individual whitespace-delimited tokens
        Example: "Please review {args} for correctness and style." *)
} [@@deriving sexp]

(** Shell-backed tool argument type. See §Tool extension points §1. *)
type shell_arg_type =
  | String of { description : string }
  | Int    of { description : string; min : int option; max : int option }
[@@deriving sexp]

type shell_arg = {
  name     : string;
  arg_type : shell_arg_type;
} [@@deriving sexp]

(** A config-defined shell-backed tool. See §Tool extension points §1. *)
type shell_tool_def = {
  name          : string;
  description   : string;
  command       : string;
    (** Template string; {arg_name} is shell-quoted and substituted. *)
  parallel_safe : bool;
  args          : shell_arg list;  (** empty = no-arg tool *)
} [@@deriving sexp]

(** MCP server transport. See §Tool extension points §2. Deferred to v2. *)
type mcp_transport =
  | Stdio of { command : string list }
  | Http  of { url : string }
[@@deriving sexp]

type mcp_server_def = {
  name      : string;
  transport : mcp_transport;
} [@@deriving sexp]

type config = {
  auth        : auth_config        option; [@sexp.option]
  model       : model_config       option; [@sexp.option]
  cache       : cache_config       option; [@sexp.option]
  session     : session_config     option; [@sexp.option]
  skills      : skills_config      option; [@sexp.option]
  compaction  : compaction_config  option; [@sexp.option]
  output      : output_config      option; [@sexp.option]
  commands    : command_def list;   [@sexp.default []]
    (** User-defined slash commands, separate from skill-file invocations.
        Both skills and commands are reachable as /<name> in interactive mode;
        name collision: command_def wins (explicit beats discovered). *)
  tools       : shell_tool_def list; [@sexp.default []]
    (** Config-defined shell-backed tools. See §Tool extension points §1. *)
  mcp_servers : mcp_server_def list; [@sexp.default []]
    (** MCP server definitions. See §Tool extension points §2. Deferred to v2. *)
} [@@deriving sexp]
```

---

## Example config files

### User config — `~/.config/pera/config.sexp`

```sexp
; Pera user configuration
((auth
   (api_key (File "/home/alice/.config/pera/anthropic_key")))
 (model
   (api anthropic)
   (model "claude-sonnet-4-6")
   (effort low)
   (max_tokens 8192))
 (cache
   (policy Conversation)
   (ttl Five_minutes))
 (skills
   (enabled true))
 (compaction
   (threshold 70)
   (tail 4)
   (enabled true))
 (output
   (plain false)
   (show_thinking false)))
```

### User config — macOS Keychain example

```sexp
((auth
   (api_key (Command (security find-generic-password -s pera-anthropic -w)))))
```

### User config — Linux secret-tool example

```sexp
((auth
   (api_key (Command (secret-tool lookup service pera account anthropic)))))
```

### Project config — `.pera` in project root

```sexp
; Project config — committed to the repo.
; No api_key field allowed here.
((model
   (api anthropic)
   (model "claude-sonnet-4-6")
   (context_window 200000))
 (cache
   (policy Conversation))
 (skills
   (available (ocaml-style commit-message)))
 (tools
   ((name run-tests)
    (description "Run the project test suite and return results")
    (command "dune test 2>&1")
    (parallel_safe false))
   ((name lint)
    (description "Run ocamlformat and semgrep checks on a file")
    (command "ocamlformat --check {file} 2>&1 && semgrep --config .semgrep/ {file}")
    (parallel_safe true)
    (args
      ((file (string (description "Absolute path of the OCaml file to check")))))))
 (mcp_servers
   ((name filesystem)
    (transport (Stdio (command (npx -y @modelcontextprotocol/server-filesystem /tmp))))))
 (commands
   ((name review)
    (description "Review staged diff for correctness")
    (template "Review the following diff for bugs and style issues:\n{args}"))
   ((name explain)
    (description "Explain a file or symbol")
    (template "Explain what {args} does, in plain language."))))
```

---

## Session file naming

When neither `--session` nor a pre-existing session path is supplied, `pera-cli`
generates a filename inside the session directory:

```
<YYYYMMDD>_<HHMMSS>_<uuid>.jsonl
```

Example: `20260624_143022_550e8400-e29b-41d4-a716-446655440000.jsonl`

- Timestamp is local wall-clock time at session start, formatted as
  `YYYYMMDD_HHMMSS`. This makes sessions sort chronologically in `ls` output.
- UUID is generated with `Uuidm.v4_gen` (already in the project). It doubles as
  the **session ID** — the identifier written into JSONL session entries and
  surfaced in `/info` output.
- The `.jsonl` extension is always appended.

`PERA_SESSION` overrides the entire path; `PERA_SESSION_DIR` / `--session-dir`
override the directory only (the timestamp+UUID filename is still generated).

---

## Skills loading

Skills follow the pi Agent Skills spec. They are markdown files with YAML
front matter, discovered from:

1. `$XDG_DATA_DIRS/pera/skills/` (system-wide, lowest priority)
2. `$XDG_DATA_HOME/pera/skills/` (user skills)
3. Project-local `.pera/skills/` directory under cwd
4. Any `skills.dirs` entries from config (highest priority)

Discovery is ordered; later directories shadow earlier ones by skill name.
Name must match the parent directory name (pi spec rule), be lowercase
`a-z0-9-`, max 64 characters.

### Skill file structure

A skill is either:
- A direct `.md` file at the root of a skills directory, or
- A `SKILL.md` inside a named subdirectory (pi convention; name comes from
  the directory name, frontmatter `name` must match).

Minimum front matter:

```markdown
---
name: ocaml-style
description: Enforce pera project OCaml coding conventions.
---

When reviewing or writing OCaml code, apply the following conventions...
(body follows)
```

Optional front matter field:

```yaml
disable-model-invocation: true
```

### Two invocation modes

**Model-loadable (default, `disable-model-invocation` absent or false):**
The system prompt receives an `<available_skills>` XML block listing name,
description, and **file path** for each such skill:

```
<available_skills>
  <skill>
    <name>ocaml-style</name>
    <description>Enforce pera project OCaml coding conventions.</description>
    <location>/home/alice/.local/share/pera/skills/ocaml-style/SKILL.md</location>
  </skill>
</available_skills>
```

The LLM is instructed to use the `read` tool to load a skill's content when
the task matches its description. The body is loaded on demand as a tool
call — it is never embedded in the system prompt. This keeps the prompt
cache-stable: only name/description/path need to be stable across turns.

**User-only (`disable-model-invocation: true`):**
The skill is invisible to the LLM. Not listed in the system prompt. Only
reachable via `/<name> [args]` in interactive mode or `--skill <name>` at
startup. When invoked, the full body is injected into the user message as:

```xml
<skill name="ocaml-style" location="/path/to/SKILL.md">
References are relative to /path/to/.

...body content...
</skill>
```

### Code-backed skills

Skills are pure prose. They cannot execute code at invocation time. If a
task requires code (e.g. "run git diff then review"), the skill body
instructs the LLM to use the `bash` tool — execution happens through the
agent's existing tools, not through the skill itself.

A slash command that needs to run code without LLM involvement (e.g. a
harness-level action) is a **built-in command**, not a skill. User-defined
code-backed commands are explicitly out of scope for v1. The correct
alternative for "run a script and give the output to the LLM" is to pipe
from outside: `git diff | pera "review this"`.

**Cache-stability note:**
Changing the set of available model-loadable skills (by editing `skills.dirs`,
`skills.available`, or the skill files themselves) changes the
`<available_skills>` block and invalidates the Anthropic cache prefix.
The `--skills` flag and `skills.available` config field documentation both
note this. `disable-model-invocation: true` skills do not appear in the block
and do not affect cache stability.

### Slash command collision

If a `command_def` in the config has the same name as a discovered skill,
the `command_def` wins (explicit beats discovered). Skills from earlier
directories are shadowed by those from later directories.

---

## System prompt construction

`pera-cli` assembles the system prompt before creating the harness and passes
it via a new `system_prompt : string` field added to `agent_harness.config`
(this is part of the prerequisite refactor — see §Tool refactor required by Q7).
The existing `build_system_prompt` function in `agent_harness.ml` is removed;
`agent_harness` no longer owns a default.

**v1 assembly (skills deferred to v2):**

The system prompt is just `base_text`:

- `base_text` — from `--system` / `--system-file` if either is supplied;
  otherwise the built-in default (below). `--system` and `--system-file` are
  mutually exclusive; supplying both is a startup error.

**v2 note:** when skills land, a `<available_skills>` block will be appended as
a stable suffix after `base_text`. The assembly function in `pera-cli` is the
right place to add it; no v1 API changes are required.

**Built-in default text** (moved from `agent_harness.ml`; tool listing dropped
— tools are already in `Provider.context.tools` and visible to the model natively):

```
You are a helpful coding assistant. Work methodically, verify your understanding before acting, and prefer small targeted changes.
```

**`agent_harness.config` change required:**

```ocaml
type config = {
  cwd           : string;
  model         : Pera_types.Types.model;
  session_path  : string;
  stream_fn     : Pera_core.Agent_types.stream_fn;
  max_tokens    : int;
  exec_env      : (module Pera_env.Execution_env.S);
  system_prompt : string;                  (* NEW — assembled by pera-cli *)
  effort        : Pera_types.Types.effort option;  (* NEW — harness maps to thinking+budget *)
  compaction    : compaction_config option;
}
```

**Cache-stability note:** changing `--system` or `--system-file` changes
`Provider.context.system` and invalidates the Anthropic cache entirely. This
is expected and unavoidable.

---

## Built-in slash commands

Available in interactive (tty) mode only:

| Command | Effect |
|---|---|
| `/compact` | Force immediate compaction |
| `/info` | Print current stats: tokens, cache read/write, model, turn count |
| `/quit` | Exit cleanly |

User-defined commands (from `commands` in config) and skill invocations extend
this set. Built-in names (`compact`, `info`, `quit`) are reserved and cannot
be overridden.

---

## Environment variables

Every option follows: `CLI flag > env var > project config > user config > built-in default`.

All env vars are prefixed `PERA_`. They shadow config file values of all tiers.
No component below `bin/pera/` reads environment variables.

| Env var | Mirrors |
|---|---|
| `PERA_API_KEY` | `auth.api_key` (as `Key`) |
| `PERA_API_KEY_FILE` | `auth.api_key` (as `File`) |
| `PERA_API_KEY_COMMAND` | `auth.api_key` (as `Command`, space-split) |
| `PERA_MODEL` | `model.model` |
| `PERA_API` | `model.api` |
| `PERA_BASE_URL` | `model.base_url` |
| `PERA_CONTEXT_WINDOW` | `model.context_window` |
| `PERA_EFFORT` | `model.effort` |
| `PERA_MAX_TOKENS` | `model.max_tokens` |
| `PERA_CACHE_POLICY` | `cache.policy` |
| `PERA_CACHE_TTL` | `cache.ttl` |
| `PERA_SESSION` | Explicit session file path |
| `PERA_SESSION_DIR` | `session.dir` |
| `PERA_CWD` | Working directory for tools |
| `PERA_SKILLS_DIR` | Prepended to `skills.dirs` — **deferred to v2** |
| `PERA_SKILLS` | `skills.available` (comma-separated) — **deferred to v2** |
| `PERA_NO_COMPACT` | `compaction.enabled = false` |
| `PERA_COMPACT_THRESHOLD` | `compaction.threshold` |
| `PERA_COMPACT_TAIL` | `compaction.tail` |

Note: `PERA_API_KEY`, `PERA_API_KEY_FILE`, and `PERA_API_KEY_COMMAND` are
mutually exclusive; if more than one is set, the binary fails loudly.

---

## CLI flags — complete table

| Flag | Config field | Default | Notes |
|---|---|---|---|
| `--api-key` | `auth.api_key (Key ...)` | — | Loud fail if multiple key sources |
| `--api-key-file` | `auth.api_key (File ...)` | — | |
| `--api-key-command` | `auth.api_key (Command ...)` | — | Space-split argv |
| `--model` | `model.model` | — | Required; loud fail |
| `--api` | `model.api` | — | Required; loud fail; no inference |
| `--base-url` | `model.base_url` | Provider default | openai-completions only |
| `--context-window` | `model.context_window` | Lookup table | Loud fail when model unknown |
| `--effort` | `model.effort` | `low` | `low\|medium\|high` |
| `--max-tokens` | `model.max_tokens` | 4096 | |
| `--cache-policy` | `cache.policy` | `no_cache` | `no_cache\|conversation\|system_and_tools` |
| `--cache-ttl` | `cache.ttl` | `five_minutes` | `five_minutes\|one_hour` |
| `--session` | — | — | Explicit path; overrides `--session-dir` |
| `--session-dir` | `session.dir` | XDG state home | |
| `--cwd` | — | Process cwd | |
| `--system` | — | Built-in | Literal system prompt override |
| `--system-file` | — | — | Load system prompt from file |
| `--skills-dir` | Prepends `skills.dirs` | — | **Deferred to v2** |
| `--skills` | `skills.available` | all | **Deferred to v2** |
| `--skill` | — | — | **Deferred to v2** |
| `--no-skills` | `skills.enabled = false` | — | **Deferred to v2** |
| `--no-compact` | `compaction.enabled = false` | — | |
| `--compact-threshold` | `compaction.threshold` | 70 | |
| `--compact-tail` | `compaction.tail` | 4 | |
| `--plain` | `output.plain` | false | |
| `--show-thinking` | `output.show_thinking` | false | |
| `--quiet` | `output.quiet` | false | |
| `--json` | — | — | Newline-delimited JSON events |
| `--verbose` | — | — | Tool args, cache warnings, compaction |

**Deferred to v2 (skills):** `--skills-dir`, `--skills`, `--skill`, `--no-skills`.
**Deferred to M7:** `--compact-model` / `compaction.model`.
**Deferred (batch mode):** `--max-turns`.

---

## Tool extension points

The built-in tool set (read, write, bash, grep) is always registered when
using `Local_env`. Three additional extension mechanisms layer on top.
All three produce `'ctx tool` values registered alongside built-ins before
the agent loop starts.

### 1 — Shell-backed tool definitions (config, v1)

Defined in the `tools` config section (see `shell_tool_def` in §OCaml types).
Each entry becomes a real tool the LLM can call; execution goes through the
existing bash execution path with a fixed command template.

**Command template substitution:**
- `{arg_name}` is replaced by the LLM-provided value, quoted with
  `Filename.quote` (single-quote escaping on POSIX).
- The substituted command is passed to `Sh.exec` as a shell command string
  (i.e., run under `$SHELL -c`).
- Only declared args are substituted; unknown `{...}` tokens are a startup
  error (not runtime).

**Schema exposure:** the tool's JSON Schema is derived from `args`. A no-arg
tool gets `{"type": "object", "properties": {}, "required": []}`. The LLM
sees the `name`, `description`, and schema exactly as with built-in tools.

**Limitation:** shell-backed tools require a shell (`Sh.exec`). If a custom
exec env does not support shell execution, the tool's execute function returns
a `tool_error`; the LLM sees an error result and can adapt.

### 2 — MCP servers (config, v2 target)

Defined in the `mcp_servers` config section. Each entry specifies a server
process; pera acts as an MCP client. Types `mcp_transport` and
`mcp_server_def` are defined in §OCaml types.

**Protocol:** JSON-RPC 2.0, MCP spec v2024-11 (current stable at time of
writing). Startup sequence: `initialize` → `tools/list`. Each tool call:
`tools/call`. Tool schemas arrive in MCP's JSON Schema format and are
translated to `Json_schema.t` values for the agent loop.

**No OCaml MCP client library exists yet.** `snf_mcp` (opam) is a server;
`jsonrpc` (from ocaml-lsp) provides JSON-RPC framing. A pera MCP client
(`lib/pera_mcp/`) needs ~300 LoC covering stdio process management, the
initialize handshake, tool discovery, and call dispatch. This is a discrete
unit of work, clearly bounded.

**Interaction with exec env:** MCP tools are not routed through
`Execution_env.S` — they communicate with an external process over the wire.
They work with any exec env, including custom ones.

`[?-5]` **MCP tool naming collisions.** If an MCP server provides a tool
named `read` (same as the built-in), which wins? Proposal: built-ins win;
MCP tools with colliding names are prefixed `<server_name>__<tool_name>` and
a warning is logged.

### 3 — Custom binary via `pera-cli` library (compile-time, not config)

Swapping the execution environment and tool set entirely is a **compile-time
decision**, not a runtime config option. The reason is OCaml's type system:
`'ctx tool` is parametric over the context type. A tool factory for `Ssh_env`
and one for `Local_env` produce incompatible types; no runtime mechanism
(dynlink or otherwise) can bridge this safely without type-unsafe casts.
Dynlink is therefore not used for env replacement.

The solution is to expose `pera-cli` as a library so custom binaries can
compose it with a different env and tool set:

```ocaml
(* pera_cli.mli — the reusable library interface *)

module type Env = sig
  type ctx
  (** The tool context type. For Local_env-backed tools this is [unit]
      (env captured in closure). For other envs it may carry the env handle. *)

  val create :
    env:Eio_unix.Stdenv.base ->
    sw:Eio.Switch.t ->
    cwd:string ->
    ctx
  (** Construct the execution context. Called once at startup. *)

  val tools : ctx -> ctx Pera_core.Agent_types.tool list
  (** The primary tool set for this env. Called after [create].
      Owns the complete tool set — pera-cli does not add built-ins on top.
      MCP tools and config-defined shell tools are added separately if
      applicable (see below). *)

  val has_shell : bool
  (** Whether this env supports shell execution. False suppresses
      config-defined shell tool construction at startup with a warning. *)
end

module Make (E : Env) : sig
  val run : unit -> unit
  (** Parse args and config, assemble harness, start the agent loop.
      Blocks until the session ends. Exit code reflects success/failure. *)
end
```

**The default `pera` binary** is:

```ocaml
(* bin/pera/main.ml *)
module Cli = Pera_cli.Make (struct
  type ctx = (module Pera_env.Execution_env.S)
  (* ctx IS the env module; it is passed as ~ctx to every tool execute call. *)

  let create ~env ~sw:_ ~cwd =
    Pera_env.Local_env.create ~env ~cwd

  let tools _ctx =
    (* Post-refactor: tools are (module Execution_env.S) tool constants.
       The env module arrives via ~ctx at execute time, not at construction. *)
    Pera_tools.Tools.default

  let has_shell = true
end)

let () = Cli.run ()
```

**A custom binary with SSH env:**

```ocaml
(* bin/pera_ssh/main.ml *)
module Cli = Pera_cli.Make (struct
  type ctx = My_ssh_env.t

  let create ~env ~sw ~cwd =
    My_ssh_env.connect ~env ~sw ~host:"my-host.example.com" ~cwd

  let tools ssh =
    [ My_ssh_tools.read ssh
    ; My_ssh_tools.write ssh
    ; My_ssh_tools.exec ssh ]
    (* bash and grep adapted for remote shell; no local fs tools *)

  let has_shell = true  (* SSH exec counts as shell access *)
end)

let () = Cli.run ()
```

This binary gets full CLI arg parsing, config loading, session management,
skills, MCP tools from config, and the interactive loop for free — only the
env and tool set differ.

**Config-defined shell tools and MCP** interact with the `Env` as follows:
- Shell tools from `tools` config section: for the standard `pera` binary,
  `has_shell = true` is unconditional — all config-defined shell tools are
  always constructed. Custom library binaries that set `has_shell = false`
  will see shell tools skipped with a warning; this is a library concern,
  not a user-facing CLI concern.
- MCP tools: always added regardless of `E.has_shell`. MCP servers are
  external processes; they do not go through `Execution_env.S`.
- `exec_env` is NOT a config field — it is a compile-time choice encoded in
  which binary the user builds and runs.

---

## Context window lookup table

Built into `bin/pera/`. `--context-window` overrides it; if the model is not
in the table and `--context-window` is absent, the binary fails with a clear
error naming the missing model.

`[?-3]` **Which models belong in the initial table?** Proposal: all claude-*
variants pera currently tests against, plus kimi-k2.6. The table is a static
`String.Map` in source; adding a model is a one-line change.

---

## `--effort` thresholds and wiring

`effort` flows from config/CLI into `agent_harness.config.effort`, which the
harness maps to `thinking : bool` and `thinking_budget_tokens : int option`
before building the loop config.

**Mapping:**

| Effort | `thinking` | `thinking_budget_tokens` |
|---|---|---|
| `Low` (default) | `false` | `None` |
| `Medium` | `true` | `Some 8_000` |
| `High` | `true` | `Some 32_000` |

`[?-4]` The `medium` = 8 000 and `high` = 32 000 values are provisional; adjust
from empirical testing.

**Stack changes required:**

1. `Provider.simple_stream_options` gets a new field:
   ```ocaml
   thinking_budget_tokens : int option;
   (* None = thinking disabled or provider default. Passed as
      thinking.budget_tokens in Anthropic requests when thinking=true. *)
   ```
2. `agent_harness` maps `effort` to `(thinking, budget)` and passes both to
   the loop config. The loop no longer hardcodes `~thinking:false`.
3. `Anthropic_request` reads `thinking_budget_tokens` from `simple_stream_options`
   and emits the `thinking` block and `betas` header when non-None.

`Low` effort (thinking disabled) is the default; no `betas` header is emitted
and no budget is set, preserving existing behaviour for callers that do not
set effort.

---

## Open questions

| # | Question | Proposal |
|---|---|---|
| 1 | Env vars above or below project config? | Above (standard Unix order) |
| 2 | Project config filename: `.pera`, `pera.sexp`, `.pera.sexp`? | `.pera` |
| 3 | Which models in the built-in context-window table? | claude-* tested variants + kimi-k2.6 |
| 4 | `--effort` thresholds for medium and high? | 8 000 / 32 000 tokens |
| 5 | MCP tool naming collisions? | Built-ins win; colliding MCP tools prefixed `<server>__<tool>` |
| 7 | `Env.create` → `Env.tools` wiring: does `ctx` carry the env handle? | **Settled: yes.** `type ctx = (module Execution_env.S)` for default binary. `Env.tools _ctx = Pera_tools.Tools.default`. |

---

## Tool refactor required by Q7

Current tools are `unit tool` — the env is captured in a closure at
construction time:

```ocaml
(* current *)
val read : (module Execution_env.S) -> unit tool
val write : (module Execution_env.S) -> unit tool
val bash : (module Execution_env.S) -> unit tool
val grep : (module Execution_env.S) -> unit tool
```

With `ctx = (module Execution_env.S)` the env is passed at call time by the
loop, so tool constructors take no env argument:

```ocaml
(* after refactor *)
val read  : (module Execution_env.S) tool
val write : (module Execution_env.S) tool
val bash  : (module Execution_env.S) tool
val grep  : (module Execution_env.S) tool

val default : (module Execution_env.S) tool list
```

The `execute` function inside each tool receives the env as `~ctx` on every
call rather than closing over it. This is strictly cleaner — the env is no
longer invisible state hidden in a closure, and two calls to the same tool
value can use different envs if needed (not a current use case but a free
correctness property).

`agent_harness` changes accordingly: it holds a `(module Execution_env.S)`
value and passes it as `ctx` to the loop config. `agent_loop` is unchanged —
it already threads `ctx` through every tool call.

This is a contained refactor touching `pera_tools/` and `pera_agent/` only.
It must land before `pera_cli` is built; it is a prerequisite, not a
separate concern.

---

## Package structure

```
pera-types      (unchanged)
pera-provider   (unchanged)
pera-core       (unchanged)
pera-env        (unchanged)
pera-tools      (modified — tool refactor: unit tool → (module Execution_env.S) tool)
pera-harness    (unchanged)
pera-agent      (modified — tool refactor: add system_prompt to config; remove build_system_prompt)
pera-cli        (new library — reusable CLI wiring, generic over Env)
pera            (executable — Pera_cli.Make(Local_env + default tools))
```

`pera-cli` depends on all libraries above it, including `pera-agent`.
The standard `pera` binary therefore only needs to depend on `pera-cli` —
it gets `pera-agent` (and everything below it) transitively.
A third-party custom binary depends on `pera-cli` plus their own env library.

---

## Dependencies to add

| Package | Purpose | When |
|---|---|---|
| `sexplib` | S-expression parsing and printing | v1 (config) |
| `ppx_sexp_conv` | Derive `sexp_of` / `of_sexp` for config types | v1 (config) |
| `cmdliner` | CLI argument parsing | v1 (CLI) |
| `jsonrpc` | JSON-RPC framing for MCP client implementation | v2 (MCP) |
| `cohttp-eio` | HTTP transport for MCP HTTP/SSE servers (already in project) | v2 (MCP) |

**Note on XDG:** No opam library is needed. XDG base directory resolution is
~25 lines of env-var lookups with standard fallbacks
(`$XDG_CONFIG_HOME` → `~/.config`, `$XDG_STATE_HOME` → `~/.local/state`,
`$XDG_DATA_HOME` → `~/.local/share`, `$XDG_DATA_DIRS` → `/usr/local/share:/usr/share`).
This is implemented inline in `pera-cli` as a small `Xdg` submodule.

---

*End of pera-cli spec v0.3.*
