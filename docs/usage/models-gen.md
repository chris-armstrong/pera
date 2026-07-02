# models-gen — Model Database Generator

## Synopsis

```
pera-models-gen <api.json> [--augment <augmentations.json>]
```

## Description

`pera-models-gen` converts the [models.dev](https://models.dev) API JSON into
Pera's native `models.sexp` format. It maps each provider's npm package to a
Pera connector protocol, extracts model metadata (context window, max tokens,
cost), and applies optional augmentations for provider-specific quirks
(thinking budgets, API field compatibility, base URL overrides).

The output is written to stdout as a human-readable S-expression. Redirect it
to `share/pera/models.sexp` to update the packaged model database.

## Arguments

| Argument | Description |
|----------|-------------|
| `api.json` | Path to the models.dev API JSON (see [Obtaining api.json](#obtaining-apijson)). |
| `--augment augmentations.json` | Optional path to an augmentations file (see [Augmentations](#augmentations)). |

## Obtaining api.json

Download the latest model database from models.dev:

```bash
curl -s https://models.dev/api.json > /tmp/api.json
```

## Typical invocation

```bash
dune exec bin/models_gen/main.exe -- /tmp/api.json \
  --augment share/pera/augmentations.json \
  > share/pera/models.sexp
```

Or, if installed as a public executable:

```bash
pera-models-gen /tmp/api.json --augment share/pera/augmentations.json \
  > share/pera/models.sexp
```

## How it works

### Protocol mapping

Each provider in the models.dev JSON declares an `npm` package name (e.g.
`@ai-sdk/anthropic`). `models-gen` maps these to Pera connector protocols:

| npm package | Protocol |
|-------------|----------|
| `@ai-sdk/anthropic` | `anthropic` |
| `@ai-sdk/openai` | `openai-completions` |
| `@ai-sdk/openai-compatible` | `openai-completions` |
| `@ai-sdk/groq` | `openai-completions` |
| `@ai-sdk/togetherai` | `openai-completions` |
| `@ai-sdk/mistral` | `openai-completions` |
| `@ai-sdk/vercel` | `openai-completions` |
| `@openrouter/ai-sdk-provider` | `openrouter` |

Providers whose npm package is not in this table are silently skipped.

### Model metadata

For each model, the following fields are extracted from the models.dev JSON:

| Field | Source | Description |
|-------|--------|-------------|
| `name` | Model key in the provider's `models` object | Model identifier (e.g. `claude-sonnet-4-6`). |
| `context_window` | `limit.context` | Maximum context window in tokens. |
| `max_tokens` | `limit.output` | Maximum output tokens. |
| `cost` | `cost.input`, `cost.output`, `cost.cache_read`, `cost.cache_write` | USD pricing per million tokens. Absent if the model has no cost data. |

### Model filtering

If an augmentation entry for a provider includes a `model_filter` list, only
models whose names appear in that list are emitted. This is useful for
restricting a provider with hundreds of models (e.g. OpenRouter) to a curated
subset.

## Augmentations

The augmentations file (`share/pera/augmentations.json`) provides
provider-specific overrides that the models.dev API does not supply. It is a
JSON object with a single `providers` key:

```json
{
  "providers": {
    "<provider-name>": {
      "api": "<base-url>",
      "compat": { … },
      "thinking_models": { … },
      "model_filter": [ … ]
    }
  }
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `api` | string | Override the base URL for this provider. |
| `compat` | object | Compatibility configuration for non-standard API fields (see below). |
| `thinking_models` | object | Per-model thinking budget overrides (see below). |
| `model_filter` | array of strings | If present, only emit models whose names are in this list. |

### compat

The `compat` object tunes the connector for provider-specific API quirks:

| Field | Type | Description |
|-------|------|-------------|
| `reasoning_field` | string | Field name for reasoning content in streaming deltas (e.g. `reasoning_content`). |
| `max_tokens_field` | string | Field name for max tokens in the request body (e.g. `max_completion_tokens`). |
| `require_tool_result_name` | bool | If `false`, the tool result `name` field is omitted. |
| `enable_thinking_field` | string | Field name for the enable-thinking toggle in the request body. |

### thinking_models

A map from model name to thinking budget configuration:

```json
{
  "thinking_models": {
    "claude-sonnet-4-6": {
      "budget_medium": 8000,
      "budget_high": 32000
    }
  }
}
```

| Field | Description |
|-------|-------------|
| `budget_medium` | Token budget for Medium effort. |
| `budget_high` | Token budget for High effort. |

Models not listed in `thinking_models` will have no thinking configuration
emitted.

## Output format

The output is an S-expression in the format defined by
[`Models_config.models_file`](../lib/pera_cli/models_config.mli). Example:

```lisp
((providers
  ((name anthropic)
   (protocol anthropic)
   (api_key_env (ANTHROPIC_API_KEY))
   (models
    ((name claude-sonnet-4-6)
     (context_window 200000)
     (max_tokens 32768)
     (thinking (budget_medium 8000) (budget_high 32000))
     (cost (input_per_mtok "3.00")
           (output_per_mtok "15.00")
           (cache_read_per_mtok "0.30")
           (cache_write_per_mtok "3.75")))))))
```

## Exit status

| Code | Meaning |
|------|---------|
| 0 | Success. |
| 1 | Input file not found, unparseable JSON, or usage error. |

## See also

- [CLI usage](cli.md) — the main `pera` command.
- [USAGE.md](../../USAGE.md) — development driver usage.
- [`Models_config` module](../lib/pera_cli/models_config.mli) — S-expression type definitions.
