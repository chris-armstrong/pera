# /orchestrate — Pera Implementation Orchestrator

Drives the full plan → execute → review → commit loop for pera.

Usage:
```
/orchestrate <task description or path to spec section>
/orchestrate SPECIFICATION.md §4 provider layer M1
```

## Phase 0 — Baseline

Run `dune build` and `dune runtest`. Record results. Pass them to the planner.

## Phase 1 — Planning

Invoke `@planner` with the task and baseline results.

The planner reads `docs/guidelines/index.md` and all mandatory guidelines, reads `SPECIFICATION.md`, and produces `.claude/plans/<plan_id>.json`.

Present the plan summary to the user and **wait for approval** before proceeding.

## Phase 2 — Execution Loop

For each stage in the plan (in dependency order):

### 2a. Execute

Invoke `@executor` with:
- Path to the plan file
- Stage number
- Path to guidelines index: `docs/guidelines/index.md`

### 2b. Route the result

Commit the stage
```bash
git add <files from stage>
git commit -m "<change>(<module>): <stage title>\n\n<stage description>\n"
```

where;
* `<change>` is one of feat, fix, docs, refactor, test, chore, etc.
* `<module>` is the name of the modified module (or if several, the main one)
* `<stage title>` is the title of the stage (absent any stage or epoch numbers)
* `<stage description>` is 1-2 sentences describing the change


## Phase 3 — Epoch Review
After all stages in an epoch complete, run all three reviewers in parallel over the entire epoch's changes as a batch. This catches issues that span stage boundaries.

- `@structure-reviewer` — reads `docs/guidelines/index.md`, focuses on abstractions, module boundaries, nesting, naming
- `@correctness-reviewer` — reads `docs/guidelines/index.md`, focuses on error handling, partial functions, patterns, type safety, pera-specific
- `@test-reviewer` — reads `docs/guidelines/index.md`, focuses on TDD discipline, test completeness, test quality

Each reviewer independently returns PASS, FAIL, or REPLAN.

**Any FAIL** → invoke `@executor` again with the failing reviewer's feedback. Max 3 attempts per stage. If still failing after 3, pause and ask the user.

**Any REPLAN** → invoke `@planner` with the REPLAN feedback. Update the plan in place. Resume from the replanned stage.

If any changes are made during the epoch review, commit


## Phase 4 — Reflection

After all epochs complete, summarise:
- What was built
- Any issues that caused replans or extra executor passes
- Decisions made that differ from the plan
- Suggested follow-up work

## Important Notes

- Never skip the test-reviewer even if the stage has "no tests" — the test-reviewer will verify that claim
- If the user intervenes mid-loop, pause and incorporate their feedback before continuing
- Plan files live in `.claude/plans/` — do not use `.opencode/plans/`
