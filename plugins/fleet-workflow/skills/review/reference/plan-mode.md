# `MODE: plan` — the plan pass

A read of a plan before any code exists. Inputs are the `MODE: plan` block of `spawn.md`: `MODE`,
`WORKTREE`, `TICKET`, `ACCEPTANCE-CRITERIA`, `CONSTRAINTS`, and `PLAN` (its header, its steps, its
`Pattern:` line where it has one). With `TICKET: none` there is no tracker read; the criteria come
from the block alone.

## Procedure

Read `<WORKTREE>/.claude/memory/context.md`, `decisions.md` and `patterns.md` where they exist.
Then, for every step of the plan, Grep/Read the files, functions and patterns it names at `HEAD`.
You are checking the plan against the repo as it actually is.

## What fails

Exactly three things return `BOUNCE`:

1. **An acceptance criterion no step covers** — the plan header's `Outcome:` line included: a plan
   whose steps cannot reach the stated outcome is the same failure.
2. **A step that contradicts the existing codebase** — it names a file, function or pattern that
   does not exist or behaves the opposite way, or it breaks a `decisions.md` / `patterns.md`
   convention.
3. **A named `CONSTRAINTS` entry broken.**

Everything else is a note: a better approach, a missing test, style, the header's own calls. A
note never moves the verdict.

## Output

```
PLAN-VERDICT: PASS | BOUNCE
UNCOVERED: <criterion> — <why no step reaches it> | none
CONTRADICTS: <step> — <file:identifier and what it actually does> | none
BREAKS: <constraint> — <step> | none
NOTES: <bullets, or none>
```

## Absolute rules

- **No GitHub.** There is no PR. Step 5 part A does not run and nothing is posted.
- **No test ticket.** Step 5 part B does not run. There is no approval here, only a verdict on a plan.
- **No memory.** Step 6 does not run and `dar-memory` is never loaded.
- Steps 1–4 do not run; this file replaces them.
- `review-scope.sh` and `review-context.sh` are not run — no range exists.
- Budget: the output block plus at most five notes.
- Re-spawned after a bounce you re-read the whole plan. **Plan mode never resumes.**
