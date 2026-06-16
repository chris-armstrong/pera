# Driver Usage

The `bin/drivers/` directory contains five executable drivers for exercising the provider, agent, harness, and tool layers during development. None of them is a production CLI — they are test harnesses.

Build everything first:

```bash
dune build
```

---

## Environment variables

### Credentials

| Variable | Required by | Description |
|----------|-------------|-------------|
| `ANTHROPIC_API_KEY` | `provider_driver`, `conversation_driver` | Anthropic API key |
| `OPENAI_API_KEY` | `conversation_driver` | API key for any OpenAI-compatible endpoint |

### OpenAI-compatible provider tuning

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAI_COMPAT` | `openai` | Preset: `openai`, `zen` (zen.opencode.ai), or `go` (opencode.ai/zen/go) |
| `OPENAI_BASE_URL` | from preset | Override the base URL for the OpenAI-compatible provider; path prefix is preserved |

### Logging

| Variable | Default | Description |
|----------|---------|-------------|
| `PERA_LOG` | `warning` | Log level: `debug`, `info`, `warning`, `error` |

Set `PERA_LOG=debug` to see raw SSE chunks, HTTP request URLs, and request bodies.

---

## provider_driver

Exercises the **Anthropic provider** directly (no agent loop). Sends one user message with a tool definition attached, streams the response, and prints each event as it arrives.

```bash
ANTHROPIC_API_KEY=sk-ant-... \
  ./_build/default/bin/drivers/provider_driver.exe [model_id [prompt [max_tokens]]]
```

**Arguments** (all optional, positional):

| Position | Default | Description |
|----------|---------|-------------|
| 1 | `claude-3-5-haiku-latest` | Model ID |
| 2 | `"What is the weather like in Sydney right now?"` | Prompt text |
| 3 | `4096` | `max_tokens` |

**Example:**

```bash
ANTHROPIC_API_KEY=sk-ant-... \
  ./_build/default/bin/drivers/provider_driver.exe claude-opus-4-8 "Summarise the water cycle"
```

Output is one line per SSE event (`[text_delta]`, `[tool_call_start]`, `[done]`, etc.), followed by a summary line.

---

## conversation_driver

Exercises the **provider layer** (not the agent loop) through a suite of multi-turn conversation scenarios. Each scenario makes one or more sequential requests and asserts that the response meets a basic correctness check.

```bash
# Run all scenarios with the first registered provider
ANTHROPIC_API_KEY=sk-ant-... \
  ./_build/default/bin/drivers/conversation_driver.exe

# Specify a provider (anthropic | openai-completions)
ANTHROPIC_API_KEY=sk-ant-... \
  ./_build/default/bin/drivers/conversation_driver.exe anthropic

# Run one named scenario
OPENAI_API_KEY=... OPENAI_COMPAT=go \
  ./_build/default/bin/drivers/conversation_driver.exe openai-completions simple_text
```

**Argument 1 — provider** (optional):

| Value | Needs | Model used |
|-------|-------|------------|
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5-20251001` |
| `openai-completions` | `OPENAI_API_KEY` | `kimi-k2.6` |
| _(omit)_ | whichever key is set | first registered |

**Argument 2 — scenario** (optional, runs all if omitted):

| Name | What it tests |
|------|---------------|
| `simple_text` | Single-turn text response |
| `echo_tool` | Single tool call, result fed back, final text |
| `multi_turn` | Two-turn exchange |
| `parallel_echo` | Multiple tool calls in one turn |

Output is a per-scenario `PASS` / `FAIL` summary. Exit code is 0 if all pass.

**Using the OpenCode Go endpoint:**

```bash
OPENAI_API_KEY=<zen-api-key> \
OPENAI_COMPAT=go \
  ./_build/default/bin/drivers/conversation_driver.exe openai-completions
```

---

## loop_driver

Exercises the **agent loop** (`pera_core`) end-to-end using a faux provider (no real network calls). Tests the orchestration layer: tool dispatch, result injection, cancellation, steering messages, and follow-up turns.

```bash
# Run all scenarios
./_build/default/bin/drivers/loop_driver.exe

# Run one named scenario
./_build/default/bin/drivers/loop_driver.exe parallel_tool_calls
```

No API keys are required — the faux provider is configured inline.

**Scenarios:**

| Name | What it tests |
|------|---------------|
| `single_text_turn` | One text response, no tools |
| `parallel_tool_calls` | Multiple tool calls dispatched in one turn |
| `sequential_tool_calls` | Tool calls across successive turns |
| `tool_error` | Tool returns an error, loop handles it |
| `mid_stream_cancel` | Stream cancelled mid-response |
| `steering_message` | Injected steering message mid-loop |
| `follow_up_message` | User follow-up after first assistant turn |

Output is a per-scenario `PASS` / `FAIL` table. Exit code is 0 if all pass.

---

## env_driver

Exercises the **harness layer** (`pera_harness`) standalone against a real OS. Tests `Sh.exec` (stdout, stderr, exit codes, timeout) and `Sh.find_executable`.

```bash
# Run all scenarios
./_build/default/bin/drivers/env_driver.exe
```

No API keys are required.

**Scenarios:**

| Name | What it tests |
|------|---------------|
| `exec stdout` | Basic command execution and stdout capture |
| `exec stderr` | Stdout / stderr separation |
| `exec exit code` | Non-zero exit code propagation |
| `exec timeout` | Timeout cancellation |
| `find sh` | PATH scan for an executable |

Output is a per-scenario `PASS` / `FAIL` / `SKIP` summary. Exit code is 0 if all non-skipped scenarios pass.

---

## session_driver

Exercises `Session_writer` directly (no agent loop). Writes sequences of session entries to a temp JSONL file and verifies structure and content chain integrity.

```bash
./_build/default/bin/drivers/session_driver.exe
```

No API keys are required.

**Scenarios:**

| Name | What it tests |
|------|---------------|
| `header_then_leaf` | Minimal session: session_info + leaf |
| `user_assistant_turn` | session_info → user message → assistant message → leaf |
| `tool_use_turn` | Turn with tool calls and tool results |
| `two_turns` | Two consecutive turns |
| `model_change` | `write_model_change` advances the tip |
| `crash_resilience` | Writer tolerates write errors without corrupting the file |
| `compaction` | `write_compaction` appends a compaction entry and advances the tip; synthetic message parents to it (M6) |

Output is a per-scenario `PASS` / `FAIL` summary. Exit code is 0 if all pass.

---

## harness_driver

Exercises the **full harness** (`pera_agent`) end-to-end using a faux provider and a real local filesystem. Runs all scenarios sequentially and writes session files to a temporary directory.

```bash
./_build/default/bin/drivers/harness_driver.exe
```

No API keys are required.

**Scenarios:**

| Name | What it tests |
|------|---------------|
| `text_only` | Single text-only turn, session written |
| `tool_use` | Turn with tool calls executed by `Local_env` |
| `subscriber_events` | Subscriber receives ordered `AE_*` events |
| `autonomous_compaction` | Context crosses `trigger_tokens`; one compaction fires mid-run; session contains compaction entry + synthetic message (M6) |

Output is a per-scenario `PASS` / `FAIL` summary. Exit code is 0 if all pass.

---

## compaction_driver

Exercises the **`Compaction` module** (`pera_harness`) directly — the §12 layer test for the compaction algorithm without instantiating a full harness. Useful both as a regression guard and as a prompt-tuning tool (the `real_model` scenario prints the produced summary).

```bash
./_build/default/bin/drivers/compaction_driver.exe
```

**Scenarios:**

| Name | Needs | What it tests |
|------|-------|---------------|
| `offline_faux` | — | `Compaction.compact` with `Faux_provider`; asserts shape of compacted message list |
| `real_model` | `ANTHROPIC_API_KEY` | `Compaction.compact` against a real Anthropic model; prints the summary for human inspection |

The `real_model` scenario is skipped (not failed) when `ANTHROPIC_API_KEY` is absent.

```bash
# Offline only
./_build/default/bin/drivers/compaction_driver.exe

# With real summarisation
ANTHROPIC_API_KEY=sk-ant-... ./_build/default/bin/drivers/compaction_driver.exe
```

Output is a per-scenario `PASS` / `FAIL` / `SKIP` summary. Exit code is 0 if all non-skipped scenarios pass.

---

## tool_driver

Exercises the **tool layer** (`pera_tools`) against a real OS using the harness. Tests all four tools (`read`, `write`, `bash`, `grep`) end-to-end.

```bash
# Run all scenarios
./_build/default/bin/drivers/tool_driver.exe
```

No API keys are required. A temporary directory is created for the test run and cleaned up afterward.

**Scenarios:**

| Tool | Name | What it tests |
|------|------|---------------|
| `read` | `basic read` | Write a file, read it back |
| `read` | `read with offset/limit` | Partial read with offset and line limit |
| `write` | `create file` | Create a new file |
| `write` | `overwrite + bytes` | Overwrite existing file, check bytes message |
| `bash` | `echo hello` | Simple command execution |
| `bash` | `exit code handling` | Non-zero exit code error message |
| `grep` | `pattern search` | Regex search with ripgrep (skipped if `rg` absent) |

Output is a per-scenario `PASS` / `FAIL` / `SKIP` summary grouped by tool. Exit code is 0 if all non-skipped scenarios pass.
