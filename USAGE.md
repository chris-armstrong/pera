# Driver Usage

The `bin/drivers/` directory contains three executable drivers for exercising the provider and agent layers during development. None of them is a production CLI — they are test harnesses.

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
