# Commit Message Guidelines

Use Conventional Commits format with the module in parentheses:

```
<type>(<module>): <description>
```

## Types

| Type | Use for |
|------|---------|
| `feat` | New functionality |
| `fix` | Bug fix |
| `test` | Adding or fixing tests |
| `docs` | Documentation or guidelines |
| `chore` | Build, CI, tooling, dependencies |
| `refactor` | Restructuring without behaviour change |
| `perf` | Performance improvements |

## Module

Use the opam package or library name where the change lives: `pera_types`, `pera_provider`, `pera_harness`, etc. For cross-cutting changes use the closest enclosing scope. For repo-level changes (CI, guidelines, project config) use the directory name: `docs`, `ci`, `.claude`.

## Examples

```
feat(pera_provider): add SSE chunk parser
fix(anthropic_interpreter): handle unknown events after message_stop
test(json_repair): port escaping edge cases from pi test suite
chore(ci): add opam cache to GitHub Actions workflow
docs(.claude): add commit message guideline
refactor(pera_types): consolidate assistant_message_event variants
```

## Rules

- Description in imperative mood, lowercase, no trailing period
- Keep the description under 72 characters total
- Body (if needed) separated by a blank line; explain *why*, not *what*
