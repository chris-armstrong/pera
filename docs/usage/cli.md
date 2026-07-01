# Pera CLI

## Synopsis

```
pera [OPTION]…
```

## Options

### Model selection

| Option | Description |
|--------|-------------|
| `--model=PROVIDER/MODEL` | Fully-qualified model identifier (e.g. `anthropic/claude-sonnet-4-6`). |
| `--list-models` | List all available providers and models with their API key environment variables, then exit. |

### API key

| Option | Description |
|--------|-------------|
| `--api-key=KEY` | API key string. |
| `--api-key-file=PATH` | File containing the API key. |
| `--api-key-command=CMD` | Command whose stdout is the API key. |

These three are mutually exclusive. If none is given, the key is read from the
environment variable specified by the provider's `api_key_env` (e.g.
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`).

### Model behaviour

| Option | Description |
|--------|-------------|
| `--effort=LEVEL` | Thinking effort level: `low`, `medium`, or `high`. |
| `--max-tokens=N` | Maximum output tokens. |
| `--cache-policy=POLICY` | Cache policy: `no_cache`, `conversation`, or `system_and_tools`. |
| `--cache-ttl=TTL` | Cache TTL: `five_minutes` or `one_hour`. |

### Input

| Option | Description |
|--------|-------------|
| `--input=TEXT` | Run a single prompt non-interactively and exit. |
| `--input-file=PATH` | Read prompt from file, run non-interactively and exit. |

`--input` and `--input-file` are mutually exclusive. If neither is given, pera
starts an interactive session.

### Output

| Option | Description |
|--------|-------------|
| `--show-thinking` | Show thinking blocks in output. |
| `--quiet` | Suppress tool events from output. |
| `--json` | Emit newline-delimited JSON events. |

### Session

| Option | Description |
|--------|-------------|
| `--session=PATH` | Explicit session file path. |
| `--session-dir=DIR` | Directory for session files. |

### Compaction

| Option | Description |
|--------|-------------|
| `--no-compact` | Disable autonomous context compaction. |
| `--compact-threshold=PCT` | Compaction threshold as percentage of context window (default: 70). |
| `--compact-tail=N` | Number of trailing turns to keep verbatim after compaction (default: 4). |

### System prompt

| Option | Description |
|--------|-------------|
| `--system=PROMPT` | Literal system prompt override. |
| `--system-file=PATH` | Load system prompt from file. |

`--system` and `--system-file` are mutually exclusive.

### Environment

| Option | Description |
|--------|-------------|
| `--cwd=DIR` | Working directory for tools. |

## Interactive mode

When run without `--input` or `--input-file`, pera starts an interactive
session. A `> ` prompt is displayed. Type your message and press Enter to send
it to the model.

### Slash commands

| Command | Description |
|---------|-------------|
| `/compact` | Trigger context compaction manually. |
| `/info` | Show session statistics (model, turns, token usage). |
| `/quit`, `/q` | Exit the session. |

Custom slash commands can be defined in `config.sexp` (see
[Configuration](configuration.md)).

## Non-interactive mode

Use `--input` or `--input-file` to run a single prompt and exit:

```bash
pera --model anthropic/claude-sonnet-4-6 --input "Explain OCaml functors"
pera --model openai/gpt-4o --input-file prompt.txt
```

## Listing models

```bash
pera --list-models
```

Prints all available providers and models in the format:

```
provider/model_name    API_KEY_ENV_VAR
```

## Environment variables

| Variable | Description |
|----------|-------------|
| `PERA_DATA_DIR` | Override the directory containing `models.sexp`. |
| `PERA_CWD` | Working directory for tools (overridden by `--cwd`). |
| `PERA_MODEL` | Default model (overridden by `--model`). |
| `PERA_EFFORT` | Default effort level. |
| `PERA_CACHE_POLICY` | Default cache policy. |
| `PERA_NO_COMPACT` | Set to disable compaction. |
| Provider-specific | Each provider defines its own API key variable (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OLLAMA_API_KEY`). Use `--list-models` to see them all. |

## Configuration files

Pera reads configuration from (in priority order, later overrides earlier):

1. Built-in defaults
2. `~/.config/pera/config.sexp` — user configuration
3. `.pera` (in project directory or ancestors) — project configuration
4. Environment variables
5. CLI flags

See [Configuration](configuration.md) for details on the config file format.

## Exit status

| Code | Meaning |
|------|---------|
| 0 | Success. |
| 1 | Configuration or runtime error. |
| 124 | Command line parsing error. |
| 125 | Unexpected internal error. |
