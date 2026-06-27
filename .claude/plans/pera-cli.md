# Pera CLI — specification

> Status: design draft v0.3 — open questions marked `[?]`.
> Covers: the `pera` binary, `pera_cli` library, config file format,
> slash commands, tool extension points, system prompt customisation.
> Does NOT cover: implementation sequencing, M7 details (compact-model).

---

## Overview

The CLI layer splits into two OCaml packages:

**`pera-cli` (library, `lib/pera_cli/`)** — reusable wiring: argument parsing,
config loading, event rendering, the interactive input loop, MCP client,
config-defined shell tool construction. It is generic over the tool context
type `'ctx`. Users who need a different execution environment (SSH, Irmin,
sandboxed, no-filesystem) write their own binary that links against `pera-cli`
and supplies their own env and tool set.

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

Each higher-priority source **replaces** the value from lower-priority sources —
there is no concatenation for list fields (`commands`, `tools`, `mcp_servers`).
A project config `commands` list replaces the user config `commands` list
entirely. This matches the semantics used by Claude Code and OpenCode.

---

## Config file format

S-expressions, parsed with `sexplib` / `ppx_sexp_conv`. This keeps the config
structurally typed — the OCaml type is the schema; no separate parser is written.

### File locations

| File | Purpose |
|---|---|
| `$PREFIX/share/pera/models.sexp` | Packaged provider and model catalog — shipped with pera |
| `$XDG_CONFIG_HOME/pera/models.sexp` | User model catalog — merged into packaged catalog by provider name, then by model name within each provider |
| `$XDG_CONFIG_HOME/pera/config.sexp` | User defaults — provider API keys, default model, output style |
| `.pera` in project root (walk up from cwd) | Project settings — default model, cache policy, tools, compaction; no `api_key` allowed |

Project config discovery walks up from the process cwd until `.pera` is found
or the filesystem root is reached (git-style). If none is found, only the user
config applies.

### Security: API keys in config

- `api_key` (inside a `provider_auth` entry) is **only accepted in the user config**.
  The parser rejects it in a project config and emits a loud error:
  `[pera] api_key may not appear in project config (.pera); use user config or the provider's api_key_env variable`.
- `base_url` overrides inside `provider_auth` are accepted in both user and project config.

### API key resolution order

For each connector call, the key is resolved in priority order:

1. `provider_auth.api_key` from user or project `config.sexp` — highest priority; explicit beats implicit.
2. First env var in `provider_spec.api_key_env` that is set in the process environment.
3. **OAuth device flow** (`provider_spec.oauth`), when defined:
   a. Read `$XDG_STATE_HOME/pera/tokens/<provider>.sexp` (mode 0600).
   b. If `access_token` present and `expires_at` > now − 60 s → use it.
   c. Else if `refresh_token` present → POST `grant_type=refresh_token` to `token_url`; on success persist new tokens and use `access_token`.
   d. Else → trigger device flow: POST to `device_auth_url`, print `user_code` and `verification_uri` on stderr, poll `token_url` at `interval` seconds until authorised or `expires_in` elapsed; persist tokens.
4. Error: `[pera] no auth for provider "<name>"; set api_key in ~/.config/pera/config.sexp or run: pera login <name>`.

**Token cache format** — `$XDG_STATE_HOME/pera/tokens/<provider>.sexp` (created with mode 0600):

```sexp
((access_token  "ghu_...")
 (refresh_token "ghr_...")
 (expires_at    "2026-07-15T09:30:00Z"))
```

`expires_at` is an RFC 3339 UTC timestamp. The 60-second early-expiry margin prevents clock-skew failures at the edge of token validity. `refresh_token` may be absent for providers that issue non-refreshable tokens (device flow re-runs when the access token expires).

The token cache is provider-level, not model-level. `pera login <provider>` pre-triggers the device flow interactively before a session starts (useful to confirm auth before beginning a long run). The same flow triggers automatically on first use if no cached token exists.

---

## Models file

`models.sexp` is the provider and model catalog. Two files are loaded and
merged at startup:

1. **Packaged** — `$PREFIX/share/pera/models.sexp`. Ships with pera. Defines
   all providers and models pera knows about out of the box.
2. **User** — `$XDG_CONFIG_HOME/pera/models.sexp`. Optional. Merged into the
   packaged file by provider name; within each provider, models are merged by
   model name. A user entry for an existing provider/model overrides only the
   fields it specifies; absent fields inherit from the packaged definition.
   A user entry for a new provider name is appended.

The models file is **not a config file** — it carries no secrets and no
personal preferences. It defines *capabilities*: what endpoints exist, what
models they expose, and what those models can do. Auth lives exclusively in
`config.sexp`.

**Data sources for the packaged catalog.** Field values in
`$PREFIX/share/pera/models.sexp` are sourced and cross-referenced from two
public databases:

- **[models.dev](https://models.dev)** (SST/Anomaly, MIT) — primary source.
  Provides provider structure, env var names, base URLs, and per-MTok pricing.
  Field naming in `provider_spec` follows models.dev conventions directly:
  `protocol` maps from the `npm` package name; `api` is models.dev's `api`
  field (the base URL). The provider key used in models.dev (e.g. `moonshotai`,
  `opencode-go`) is the canonical provider name used in pera.
- **[BerriAI/litellm](https://github.com/BerriAI/litellm)** `model_prices_and_context_window.json`
  — cross-check for pricing accuracy. LiteLLM routes real API traffic so
  corrections appear quickly. Anthropic native models are keyed by bare model
  name (e.g. `claude-sonnet-4-6`, `litellm_provider: "anthropic"`).

When models.dev and LiteLLM disagree on a value, prefer LiteLLM for pricing
and context window sizes; prefer models.dev for env var names and base URLs.

**Protocol lookup table** — maps models.dev `npm` package to pera `protocol`:

| models.dev `npm` | pera `protocol` |
|---|---|
| `@ai-sdk/anthropic` | `"anthropic"` |
| `@ai-sdk/openai` | `"openai-completions"` |
| `@ai-sdk/openai-compatible` | `"openai-completions"` |
| `@ai-sdk/groq` | `"openai-completions"` |
| `@ai-sdk/togetherai` | `"openai-completions"` |
| `@ai-sdk/mistral` | `"openai-completions"` |
| `@ai-sdk/google`, `@ai-sdk/cohere`, etc. | not supported |

Note: `@ai-sdk/anthropic` with a non-Anthropic `api` URL (e.g. kimi-for-coding
at `https://api.kimi.com/coding/v1`) is valid — it uses the Anthropic wire
protocol over a third-party endpoint.

**Model addressing:** all model references are fully qualified as
`<provider>/<model>` (e.g. `anthropic/claude-sonnet-4-6`,
`moonshotai/kimi-k2-0905-preview`). Short names are not resolved; using an
unqualified name is a startup error with a suggestion of matching qualified
names.

---

## OCaml types (ppx_sexp_conv)

### models.sexp types

```ocaml
(** Extended thinking capabilities for a model. *)
type thinking_spec = {
  budget_medium : int; [@sexp.default 8_000]
    (** thinking_budget_tokens used when effort = Medium. *)
  budget_high   : int; [@sexp.default 32_000]
    (** thinking_budget_tokens used when effort = High. *)
} [@@deriving sexp]

(** openai-completions endpoint quirks. Absent fields use connector defaults.
    Only meaningful when provider_spec.protocol = "openai-completions";
    ignored by the anthropic connector. *)
type compat_config = {
  reasoning_field          : string option; [@sexp.option]
    (** JSON field carrying reasoning/thinking content. Default: "reasoning_content". *)
  max_tokens_field         : string option; [@sexp.option]
    (** JSON field for max output tokens. Default: "max_completion_tokens". *)
  require_tool_result_name : bool   option; [@sexp.option]
    (** Whether tool-result messages require a "name" field. Default: false. *)
  enable_thinking_field    : string option; [@sexp.option]
    (** Field to set to true to enable thinking. None = provider enables thinking
        via model selection (e.g. OpenAI o-series), no explicit field needed. *)
} [@@deriving sexp]

(** USD pricing for a model, per million tokens.
    Stored as Decimal.t via custom converters (decimal_of_sexp / sexp_of_decimal)
    that represent each value as a quoted string atom, e.g. (input_per_mtok "3.00").
    Absent cost record = cost unknown/not applicable (e.g. local models).
    Cache fields are optional — only providers that charge for cache operations
    include them (currently only Anthropic has cache_write fees). *)
type model_cost = {
  input_per_mtok       : decimal;
  output_per_mtok      : decimal;
  cache_read_per_mtok  : decimal option; [@sexp.option]
  cache_write_per_mtok : decimal option; [@sexp.option]
} [@@deriving sexp]

(** A model entry nested under a provider in models.sexp. *)
type model_spec = {
  name           : string;
    (** Unqualified model name. Full address: <provider_spec.name>/<name>. *)
  context_window : int;
  max_tokens     : int;
    (** Default maximum output tokens. Overridable via config or --max-tokens. *)
  thinking       : thinking_spec option; [@sexp.option]
    (** None = model does not support extended thinking.
        Startup error if effort > Low is requested for such a model. *)
  cost           : model_cost option; [@sexp.option]
    (** USD pricing per million tokens. Absent = unknown/not applicable. *)
} [@@deriving sexp]

(** RFC 8628 Device Authorization Grant configuration.
    Lives in models.sexp (public — client_id is not a secret).
    Tokens are cached in $XDG_STATE_HOME/pera/tokens/<provider>.sexp.
    See §API key resolution order for the full resolution sequence. *)
type oauth_flow = {
  device_auth_url : string;
    (** RFC 8628 device_authorization_endpoint.
        E.g. "https://github.com/login/device/code". *)
  token_url       : string;
    (** OAuth 2.0 token endpoint.
        E.g. "https://github.com/login/oauth/access_token". *)
  client_id       : string;
    (** OAuth application client_id (public; not a secret).
        E.g. "Iv1.b507a08c87ecfe98" for GitHub Copilot / GitHub Models. *)
  scope           : string list; [@sexp.default []]
    (** OAuth scopes to request. Empty list = provider default. *)
} [@@deriving sexp]

(** A provider entry in models.sexp.

    Field naming follows the models.dev convention:
      protocol — connector type discriminator ("anthropic" | "openai-completions")
      api      — base URL (same meaning as models.dev's "api" field)

    See "Protocol lookup table" in §Models file for npm→protocol mapping.
    See §API key resolution order for how api_key_env and oauth interact. *)
type provider_spec = {
  name         : string;
    (** Provider identifier. Models addressed as <name>/<model_name>.
        Use the models.dev provider key as the canonical name (e.g. "moonshotai"). *)
  protocol     : string;
    (** "anthropic" | "openai-completions". Selects the Connector implementation. *)
  api_key_env  : string list; [@sexp.default []]
    (** Env var names to try in order when user config provides no explicit api_key.
        Empty list = no env var (e.g. local/ollama).
        E.g. ["ANTHROPIC_API_KEY"] or ["GITHUB_TOKEN"; "GH_TOKEN"]. *)
  api          : string option; [@sexp.option]
    (** Base URL. Absent = connector's built-in default (e.g. Anthropic, OpenAI native).
        Required for openai-compatible third-party endpoints. *)
  base_url_env : string option; [@sexp.option]
    (** Env var whose value, if set at runtime, overrides api.
        Useful for local providers like Ollama where the URL varies per install.
        E.g. "OLLAMA_BASE_URL". *)
  oauth        : oauth_flow option; [@sexp.option]
    (** RFC 8628 device flow. When present and no API key is available from
        user config or api_key_env, pera triggers the device flow automatically
        and caches the resulting tokens. See §API key resolution order. *)
  compat       : compat_config option; [@sexp.option]
    (** openai-completions quirks. Only meaningful when protocol = "openai-completions". *)
  models       : model_spec list; [@sexp.default []]
} [@@deriving sexp]

type models_file = {
  providers : provider_spec list; [@sexp.default []]
} [@@deriving sexp]
```

### config.sexp types

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

(** Per-model effort override within a provider_auth entry. *)
type model_auth = {
  name   : string;
    (** Unqualified model name within this provider. *)
  effort : effort option; [@sexp.option]
    (** Override the global or system-default effort for this specific model. *)
} [@@deriving sexp]

(** Auth and personal overrides for a named provider.
    User config: api_key accepted.
    Project config: api_key rejected (loud error); base_url allowed. *)
type provider_auth = {
  name     : string;
    (** Must match a provider_spec.name from models.sexp. *)
  api_key  : api_key_source option; [@sexp.option]
  base_url : string option; [@sexp.option]
    (** Override the provider's api (base URL) for this user/project. *)
  models   : model_auth list; [@sexp.default []]
    (** Per-model effort overrides for this provider. *)
} [@@deriving sexp]

type cache_config = {
  policy : cache_policy option; [@sexp.option]
  ttl    : cache_ttl    option; [@sexp.option]
} [@@deriving sexp]

type session_config = {
  dir : string option; [@sexp.option]
    (** Default: $XDG_STATE_HOME/pera/sessions/ *)
} [@@deriving sexp]

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
  description : string;  (** Shown in /info output *)
  template    : string;
    (** Injected as a user message. Substitution:
          {args}  — everything typed after the command name
          {1}, {2}, ... — individual whitespace-delimited tokens
        Example: "Please review {args} for correctness and style." *)
} [@@deriving sexp]

(** Shell-backed tool argument type. See §Tool extension points §1. *)
type shell_arg_type =
  | String of { description : string }
  | Int    of { description   : string
              ; min           : int option [@sexp.option]
              ; max           : int option [@sexp.option] }
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
  args          : shell_arg list; [@sexp.default []]  (** empty = no-arg tool *)
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
  providers     : provider_auth list; [@sexp.default []]
    (** Auth and overrides for named providers. Keys only in user config.
        Project config may contain base_url overrides but not api_key. *)
  default_model : string option; [@sexp.option]
    (** Fully-qualified model to use when --model is not given.
        Format: "<provider>/<model>", e.g. "anthropic/claude-sonnet-4-6". *)
  effort        : effort option; [@sexp.option]
    (** Global default effort. Per-model setting in providers takes precedence. *)
  max_tokens    : int option; [@sexp.option]
    (** Override model_spec.max_tokens for this config tier. *)
  cache       : cache_config       option; [@sexp.option]
  session     : session_config     option; [@sexp.option]
  compaction  : compaction_config  option; [@sexp.option]
  output      : output_config      option; [@sexp.option]
  commands    : command_def list;   [@sexp.default []]
    (** User-defined slash commands. Reachable as /<name> in interactive mode.
        Built-in names (compact, info, quit) are reserved. *)
  tools       : shell_tool_def list; [@sexp.default []]
    (** Config-defined shell-backed tools. See §Tool extension points §1. *)
  mcp_servers : mcp_server_def list; [@sexp.default []]
    (** MCP server definitions. See §Tool extension points §2. Deferred to v2. *)
} [@@deriving sexp]
```

---

## Example config files

### Packaged models catalog — `$PREFIX/share/pera/models.sexp`

```sexp
; Packaged provider and model catalog — shipped with pera.
; Provider names and base URLs from models.dev; pricing cross-checked with
; BerriAI/litellm model_prices_and_context_window.json.
; Users may extend or override entries in $XDG_CONFIG_HOME/pera/models.sexp.
((providers
  (((name anthropic)
    (protocol anthropic)
    (api_key_env (ANTHROPIC_API_KEY))
    (models
      (((name claude-sonnet-4-6)
        (context_window 200000)
        (max_tokens 16000)
        (thinking ((budget_medium 8000) (budget_high 32000)))
        (cost ((input_per_mtok "3") (output_per_mtok "15")
               (cache_read_per_mtok "0.30") (cache_write_per_mtok "3.75"))))
       ((name claude-haiku-4-5-20251001)
        (context_window 200000)
        (max_tokens 8192)
        (cost ((input_per_mtok "1") (output_per_mtok "5")
               (cache_read_per_mtok "0.10") (cache_write_per_mtok "1.25")))))))
   ((name openai)
    (protocol openai-completions)
    (api_key_env (OPENAI_API_KEY))
    (api "https://api.openai.com/v1")
    (compat
      ((max_tokens_field max_completion_tokens)
       (require_tool_result_name false)))
    (models
      (((name gpt-4o)
        (context_window 128000)
        (max_tokens 16384)
        (cost ((input_per_mtok "2.50") (output_per_mtok "10.00")
               (cache_read_per_mtok "1.25"))))
       ((name o3)
        (context_window 200000)
        (max_tokens 100000)
        (cost ((input_per_mtok "2") (output_per_mtok "8")
               (cache_read_per_mtok "0.50")))))))
   ((name moonshotai)
    (protocol openai-completions)
    (api_key_env (MOONSHOT_API_KEY))
    (api "https://api.moonshot.ai/v1")
    (compat
      ((reasoning_field reasoning_content)
       (max_tokens_field max_tokens)
       (require_tool_result_name false)
       (enable_thinking_field enable_thinking)))
    (models
      (((name kimi-k2-0905-preview)
        (context_window 262144)
        (max_tokens 32768)
        (thinking ((budget_medium 8000) (budget_high 32000)))
        (cost ((input_per_mtok "0.6") (output_per_mtok "2.5")
               (cache_read_per_mtok "0.15")))))))
   ((name github-copilot)
    (protocol openai-completions)
    (api "https://api.githubcopilot.com")
    (api_key_env (GITHUB_TOKEN GH_TOKEN))
    (oauth ((device_auth_url "https://github.com/login/device/code")
            (token_url "https://github.com/login/oauth/access_token")
            (client_id "Iv1.b507a08c87ecfe98")))
    (models
      (((name claude-sonnet-4.5)
        (context_window 128000)
        (max_tokens 16384))
       ((name gpt-4o)
        (context_window 128000)
        (max_tokens 16384))
       ((name gemini-2.5-pro)
        (context_window 1000000)
        (max_tokens 65536)))))
   ((name github-models)
    (protocol openai-completions)
    (api "https://models.github.ai/inference")
    (api_key_env (GITHUB_TOKEN GH_TOKEN))
    (oauth ((device_auth_url "https://github.com/login/device/code")
            (token_url "https://github.com/login/oauth/access_token")
            (client_id "Iv1.b507a08c87ecfe98")))
    (models
      (((name openai/gpt-4o)
        (context_window 128000)
        (max_tokens 16384))
       ((name meta/meta-llama-3.1-405b-instruct)
        (context_window 128000)
        (max_tokens 8192)))))
   ((name local)
    (protocol openai-completions)
    (api_key_env ())
    (api "http://localhost:11434")
    (base_url_env OLLAMA_BASE_URL)
    (models
      (((name qwen2.5-coder:14b)
        (context_window 32768)
        (max_tokens 8192))))))))
```

### User config — `~/.config/pera/config.sexp`

```sexp
; Pera user configuration
((providers
   (((name anthropic)
     (api_key (File "/home/alice/.config/pera/anthropic_key"))
     (models
       (((name claude-sonnet-4-6)
         (effort Medium)))))
    ((name moonshot)
     (api_key (Command (pass show moonshot/api-key))))))
 (default_model "anthropic/claude-sonnet-4-6")
 (effort Low)
 (cache
   ((policy Conversation)
    (ttl Five_minutes)))
 (compaction
   ((threshold 70)
    (tail 4)
    (enabled true)))
 (output
   ((plain false)
    (show_thinking false))))
```

### User config — macOS Keychain example

```sexp
((providers
   (((name anthropic)
     (api_key (Command (security find-generic-password -s pera-anthropic -w)))))))
```

### User config — Linux secret-tool example

```sexp
((providers
   (((name anthropic)
     (api_key (Command (secret-tool lookup service pera account anthropic)))))))
```

### Project config — `.pera` in project root

```sexp
; Project config — committed to the repo.
; api_key is not allowed here; base_url overrides are permitted.
((default_model "anthropic/claude-sonnet-4-6")
 (cache
   ((policy Conversation)))
 (tools
   (((name run-tests)
     (description "Run the project test suite and return results")
     (command "dune test 2>&1")
     (parallel_safe false))
    ((name lint)
     (description "Run ocamlformat and semgrep checks on a file")
     (command "ocamlformat --check {file} 2>&1 && semgrep --config .semgrep/ {file}")
     (parallel_safe true)
     (args
       (((name file)
         (arg_type (String ((description "Absolute path of the OCaml file to check"))))))))))
 (mcp_servers
   (((name filesystem)
     (transport (Stdio ((command (npx -y @modelcontextprotocol/server-filesystem /tmp))))))))
 (commands
   (((name review)
     (description "Review staged diff for correctness")
     (template "Review the following diff for bugs and style issues:\n{args}"))
    ((name explain)
     (description "Explain a file or symbol")
     (template "Explain what {args} does, in plain language.")))))
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

## System prompt construction

`pera-cli` assembles the system prompt before creating the harness and passes
it via a new `system_prompt : string` field added to `agent_harness.config`
(this is part of the prerequisite refactor — see §Tool refactor required by Q7).
The existing `build_system_prompt` function in `agent_harness.ml` is removed;
`agent_harness` no longer owns a default.

**Assembly:**

The system prompt is just `base_text`:

- `base_text` — from `--system` / `--system-file` if either is supplied;
  otherwise the built-in default (below). `--system` and `--system-file` are
  mutually exclusive; supplying both is a startup error.

**Built-in default text** (moved from `agent_harness.ml`; tool listing dropped
— tools are already in `Connector.context.tools` and visible to the model natively):

```
You are a helpful coding assistant. Work methodically, verify your understanding before acting, and prefer small targeted changes.
```

**`agent_harness.config` change required:**

```ocaml
type config = {
  cwd                    : string;
  model                  : Pera_types.Types.model;
  session_path           : string;
  stream_fn              : Pera_core.Agent_types.stream_fn;
  max_tokens             : int;
  exec_env               : (module Pera_env.Execution_env.S);
  system_prompt          : string;         (* NEW — assembled by pera-cli *)
  thinking_budget_tokens : int option;
    (* NEW — None = no thinking; Some n = enable thinking with budget n tokens.
       pera-cli resolves this from (effort, model_spec.thinking) in models.sexp:
         Low  → None
         Medium → thinking_spec.budget_medium
         High   → thinking_spec.budget_high
       Startup error if effort > Low for a model with thinking = None. *)
  compaction             : compaction_config option;
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

`pera login <provider>` is a **top-level subcommand** (not a slash command) that
pre-triggers the OAuth device flow for a named provider and stores the resulting
token before a session begins. It exits after the flow completes. Useful for
confirming auth in CI or before a long run. `pera logout <provider>` deletes the
cached token file, forcing re-authentication on the next use.

User-defined commands (from `commands` in config) extend this slash-command set.
Built-in names (`compact`, `info`, `quit`) are reserved and cannot be overridden.

---

## Environment variables

Every option follows: `CLI flag > env var > project config > user config > built-in default`.

All env vars are prefixed `PERA_`. They shadow config file values of all tiers.
No component below `bin/pera/` reads environment variables.

| Env var | Mirrors |
|---|---|
| `PERA_API_KEY` | `providers[resolved].api_key` (as `Key`) — overrides the resolved provider's key |
| `PERA_API_KEY_FILE` | `providers[resolved].api_key` (as `File`) |
| `PERA_API_KEY_COMMAND` | `providers[resolved].api_key` (as `Command`, space-split) |
| `PERA_MODEL` | `default_model` — must be fully qualified: `provider/model-name` |
| `PERA_EFFORT` | `effort` |
| `PERA_MAX_TOKENS` | `max_tokens` |
| `PERA_CACHE_POLICY` | `cache.policy` |
| `PERA_CACHE_TTL` | `cache.ttl` |
| `PERA_SESSION` | Explicit session file path |
| `PERA_SESSION_DIR` | `session.dir` |
| `PERA_CWD` | Working directory for tools |
| `PERA_NO_COMPACT` | `compaction.enabled = false` |
| `PERA_COMPACT_THRESHOLD` | `compaction.threshold` |
| `PERA_COMPACT_TAIL` | `compaction.tail` |

Note: `PERA_API_KEY`, `PERA_API_KEY_FILE`, and `PERA_API_KEY_COMMAND` are
mutually exclusive; if more than one is set, the binary fails loudly.

Provider-specific API keys (e.g. `ANTHROPIC_API_KEY`, `MOONSHOT_API_KEY`) are
declared in models.sexp via `api_key_env` and read directly from the environment
by pera at startup. `PERA_API_KEY` overrides whichever provider is resolved by
the active model — useful for quick testing without editing config.

---

## CLI flags — complete table

| Flag | Config field | Default | Notes |
|---|---|---|---|
| `--api-key` | `providers[resolved].api_key (Key ...)` | — | Overrides resolved provider's key; loud fail if multiple key sources |
| `--api-key-file` | `providers[resolved].api_key (File ...)` | — | |
| `--api-key-command` | `providers[resolved].api_key (Command ...)` | — | Space-split argv |
| `--model` | `default_model` | — | Fully-qualified `provider/model`; required if not set in config; loud fail if absent |
| `--effort` | `effort` | `low` | `low\|medium\|high`; startup error if model has no thinking and effort > low |
| `--max-tokens` | `max_tokens` | model_spec default | Overrides model_spec.max_tokens |
| `--cache-policy` | `cache.policy` | `no_cache` | `no_cache\|conversation\|system_and_tools` |
| `--cache-ttl` | `cache.ttl` | `five_minutes` | `five_minutes\|one_hour` |
| `--session` | — | — | Explicit path; overrides `--session-dir` |
| `--session-dir` | `session.dir` | XDG state home | |
| `--cwd` | — | Process cwd | |
| `--system` | — | Built-in | Literal system prompt override |
| `--system-file` | — | — | Load system prompt from file |
| `--no-compact` | `compaction.enabled = false` | — | |
| `--compact-threshold` | `compaction.threshold` | 70 | |
| `--compact-tail` | `compaction.tail` | 4 | |
| `--plain` | `output.plain` | false | |
| `--show-thinking` | `output.show_thinking` | false | |
| `--quiet` | `output.quiet` | false | |
| `--json` | — | — | Newline-delimited JSON events |
| `--verbose` | — | — | Tool args, cache warnings, compaction |

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
- The substituted command is passed to `(E : Execution_env.S).Sh.exec` —
  the same path the built-in `bash` tool uses (run under `$SHELL -c`).
- Only declared args are substituted; unknown `{...}` tokens are a startup
  error (not runtime).

**Schema exposure:** the tool's JSON Schema is derived from `args`. A no-arg
tool gets `{"type": "object", "properties": {}, "required": []}`. The LLM
sees the `name`, `description`, and schema exactly as with built-in tools.

**Limitation:** shell-backed tools require a shell (`Execution_env.S.Sh.exec`).
If a custom exec env does not support shell execution, the tool's execute
function returns a `tool_error`; the LLM sees an error result and can adapt.

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
  (** The tool context type. For the default [pera] binary this is
      [(module Execution_env.S)] — the env handle passed as [~ctx] to
      every tool execute call. Custom binaries may use their own handle type. *)

  val create :
    env:Eio_unix.Stdenv.base ->
    sw:Eio.Switch.t ->
    cwd:string ->
    ctx
  (** Construct the execution context. Called once at startup. *)

  val tools : ctx -> ctx Pera_core.Agent_types.tool list
  (** The base tool set for this env. Called after [create].
      Config-defined shell tools and MCP tools are added by [pera-cli]
      on top of this list (see below). *)

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
MCP tools from config, and the interactive loop for free — only the env and
tool set differ.

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

## Context window and model capabilities

Context windows, max token limits, and thinking capabilities are now stored in
`models.sexp` as `model_spec` fields rather than a static lookup table in the
binary. When `pera` starts:

1. Load and merge packaged + user `models.sexp`.
2. Resolve the fully-qualified model name (e.g. `anthropic/claude-sonnet-4-6`)
   to a `provider_spec` + `model_spec` pair.
3. Startup error if the model is not found in the merged catalog. Message:
   `[pera] unknown model "provider/model" — add it to $XDG_CONFIG_HOME/pera/models.sexp`

The `--context-window`, `--api`, and `--base-url` CLI flags are removed; all
such information is sourced from models.sexp. To add a model not in the
packaged catalog, users extend their personal `models.sexp`.

---

## `--effort` thresholds and wiring

`effort` flows from config/CLI into `pera-cli`, which resolves it against the
model's `thinking_spec` from models.sexp and passes the computed
`thinking_budget_tokens : int option` to `agent_harness.config`.

**Resolution in pera-cli:**

| Effort | `thinking_budget_tokens` |
|---|---|
| `Low` (default) | `None` — thinking disabled |
| `Medium` | `Some model_spec.thinking.budget_medium` |
| `High` | `Some model_spec.thinking.budget_high` |

Startup error if effort > Low is requested for a model whose `model_spec.thinking`
is `None` (model does not support extended thinking).

Per-model defaults in `provider_auth.models` override the global effort before
this resolution step.

**Stack changes required:**

1. `Connector.simple_stream_options` gets a new required field:
   ```ocaml
   thinking_budget_tokens : int option;
   (* None = thinking disabled. Passed as thinking.budget_tokens in
      Anthropic requests; ignored by openai-completions connector unless
      compat.enable_thinking_field is set. *)
   ```
   This is a breaking record change. All `simple_stream_options` construction
   sites (drivers, harness, tests) must add `thinking_budget_tokens = None`.
   Offline-test drivers scheduled for migration to `lib/*/test/` can be
   updated as part of that migration.
2. `agent_harness` receives pre-computed `thinking_budget_tokens` in its config
   and passes it directly to the loop config. The loop no longer hardcodes
   `~thinking:false`.
3. `Anthropic_request` reads `thinking_budget_tokens` from `simple_stream_options`
   and emits the `thinking` block and `betas` header when non-None.

`Low` effort (thinking disabled) is the default; no `betas` header is emitted
and no budget is set, preserving existing behaviour for callers that do not
set effort.

---

## Open questions

| # | Question | Proposal |
|---|---|---|
| 1 | Env vars above or below project config? | **Settled:** above (standard Unix order — matches env vars section). |
| 2 | Project config filename: `.pera`, `pera.sexp`, `.pera.sexp`? | **Settled:** `.pera` (used throughout this spec). |
| 3 | Which models in the built-in context-window table? | **Settled:** no static table — models.sexp is the catalog; initial packaged file covers anthropic + openai + moonshot. |
| 4 | `--effort` thresholds for medium and high? | **Settled:** per-model `thinking_spec` in models.sexp (`budget_medium` / `budget_high`); defaults 8 000 / 32 000. |
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

---

## Connector rename (was Provider)

The OCaml module type currently named `Provider.S` conflicts with the
user-facing concept of a "provider" (an entry in models.sexp with a name,
api_key_env, and list of models). To eliminate ambiguity, the OCaml API
barrier for LLM HTTP calls is renamed to `Connector`.

**Rename map:**

| Old name | New name |
|---|---|
| `Provider.S` | `Connector.S` |
| `Anthropic_provider` | `Anthropic_connector` |
| `Openai_completions_provider` | `Openai_completions_connector` |
| `Provider_registry` | `Connector_registry` |
| `Provider_adapter` | `Connector_adapter` |
| `lib/pera_provider/` | `lib/pera_connector/` |
| Package `pera-provider` | Package `pera-connector` |

`provider_driver` and `conversation_driver` (which directly reference
`Anthropic_provider` / `Openai_completions_provider`) are scheduled for removal
— see §Driver cleanup. The rename can proceed independently; remaining live
usages are in `live_driver` and `compaction_driver`, which keep the old names
until the rename lands.

The word "provider" in user-facing contexts (config, CLI help text, error
messages) always refers to the models.sexp provider concept. The word
"connector" is an internal implementation detail not exposed to users.

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
pera-connector  (renamed from pera-provider — Connector.S, Anthropic_connector, Openai_completions_connector)
pera-core       (unchanged)
pera-env        (unchanged)
pera-tools      (modified — tool refactor: unit tool → (module Execution_env.S) tool)
pera-harness    (unchanged)
pera-agent      (modified — add system_prompt and thinking_budget_tokens to config; remove build_system_prompt; remove effort field)
pera-cli        (new library — reusable CLI wiring, generic over Env; owns models.sexp loading and config merging)
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
| `xdg` | XDG base directory resolution (config, state, data paths) | v1 (CLI) |
| `cmdliner` | CLI argument parsing | v1 (CLI) |
| `jsonrpc` | JSON-RPC framing for MCP client implementation | v2 (MCP) |
| `cohttp-eio` | HTTP transport for MCP HTTP/SSE servers (already in project) | v2 (MCP) |

**Note on `xdg`:** The `xdg` opam package (from the Dune/ocaml-lsp project) is
pure OCaml — it only reads env vars and computes paths. It works with any
runtime including Eio. Provides `Xdg.config_home`, `Xdg.state_home`,
`Xdg.data_home`, and `Xdg.data_dirs` with correct platform fallbacks.

---

## Driver cleanup

Building `pera` makes several `bin/drivers/` binaries obsolete. Each falls into one of three categories.

### Delete outright — pure CLI prototypes superseded by `pera`

| Driver | Reason |
|---|---|
| `conversation_driver.ml` | Interactive conversation loop; `pera` replaces it entirely. |
| `conversation_driver_helpers.ml` | Real-model scenarios (simple_text, echo_tool, multi_turn, parallel_echo) overlap with `live_driver.ml`; absorb any unique coverage there before deleting. The `echo_tool` and `counter_tool` helpers referenced by `loop_driver.ml` move to `pera_core_test_util` when that driver is migrated. |

### Migrate then delete — self-contained test suites that belong under `dune runtest`

For each driver below: audit its scenarios against the existing Alcotest test files in the target directory; add any missing scenarios as proper Alcotest tests; then delete the driver.

| Driver | Target | Scenarios to verify |
|---|---|---|
| `loop_driver.ml` | `lib/pera_core/test/` | 14 Faux_provider scenarios — cross-check thinking_blocks, prepare_next_turn_update, before_tool_call_deny/allow, and after_tool_call_fires against `agent_loop_test.ml`, `agent_loop_tools_test.ml`, and `agent_loop_cancel_test.ml`. |
| `env_driver.ml` | `lib/pera_env/test/` | 9 scenarios — likely covered by `local_env_sh_test.ml` + `local_env_fs_test.ml`; verify. |
| `tool_driver.ml` | `lib/pera_tools/test/` | 9 scenarios — likely covered by existing tool tests; verify read_truncation and read_missing_path_arg in particular. |
| `harness_driver.ml` | `lib/pera_agent/test/` | 4 scenarios — likely covered by `agent_harness_test.ml`; verify the autonomous_compaction scenario is present before deleting. |
| `session_driver.ml` | `lib/pera_harness/test/` | 7 scenarios — likely covered by `session_writer_test.ml`; verify crash_resilience and model_change. |
| `compaction_driver.ml` (`offline_faux` only) | `lib/pera_harness/test/` | 1 scenario — verify covered by `compaction_test.ml`; then remove `offline_faux` from the driver (the `real_model` scenario stays). |

### Keep — live tests or lower-level tests not superseded by the CLI

| Driver | Reason |
|---|---|
| `live_driver.ml` | Full-stack end-to-end tests against the real Anthropic API; not superseded by `pera`. |
| `provider_driver.ml` | Raw provider streaming tests (Anthropic thinking, openai-completions); not superseded by `pera`. |
| `compaction_driver.ml` (`real_model` scenario) | Live Anthropic API compaction test; keep. |

---

*End of pera-cli spec v0.3.*
