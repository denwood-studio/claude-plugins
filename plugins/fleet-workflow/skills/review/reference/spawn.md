# The spawn contract

The caller starts the reviewer as `fleet-workflow:reviewer` (an Agent `subagent_type`, or a workflow
`agentType`) with a prompt of `KEY: value` lines. **Every field is optional.** A plain session that
passes only a PR still works: the reviewer discovers what is missing (see *An incomplete block*).

| Field | Meaning | Default when absent |
| --- | --- | --- |
| `WORKTREE` | Absolute path of the checkout holding the PR's head. | The session's working directory, resolved with `git rev-parse --show-toplevel`. |
| `PR` | The pull request number. | The PR for the checked-out branch (`gh pr view --json number`). None found: no PR yet, and nothing is posted. |
| `REPO` | `<owner>/<repo>`. | `gh pr view --json headRepositoryOwner,headRepository`, else the `origin` remote. |
| `BASE` | The ref the PR is diffed against, for example `origin/release`. A stacked PR sits on another branch, not on the default one. | The PR's base branch, else `origin/main`. |
| `TICKET` | The tracker id of the implementation ticket, or `none`. | `none`. |
| `ACCEPTANCE-CRITERIA` | The ticket's criteria verbatim, tier tags included. | `none`. |
| `PLAN` | The approved plan, header included. In review mode it is context; in `MODE: plan` it is the subject. | `none`. |
| `CONSTRAINTS` | Prohibitions and settled decisions the diff must respect. | `none`. |
| `SETTLED-CALLS` | Decisions the caller already made; do not re-report them. | `none`. |
| `SCOPE-OUTPUT` | The stdout of `review-scope.sh` for the current HEAD. | Absent: run `review-scope.sh` yourself once. |
| `MEMORY-SYNC` | The state of the shared memory store, including its entry count. An `INDEX: ceiling <n>/45` line means it is over the ceiling. | `none`: the review writes no memory entry. |
| `MODE` | `review`, or `plan` for the plan pass. | `review`. Any other value is treated as `review` and noted. |

A minimal block:

```
WORKTREE: /abs/path/to/checkout
PR: 123
REPO: owner/repo
```

## An incomplete block

Missing `WORKTREE`, `PR`, `REPO`, `BASE` or `SCOPE-OUTPUT:` is not an error. Discover it first:
`git worktree list`, `gh pr view --json number,baseRefName,headRepositoryOwner,headRepository`,
then `git -C <WORKTREE> fetch origin --quiet` and
`${CLAUDE_PLUGIN_ROOT}/scripts/review-scope.sh <WORKTREE> <PR> <REPO>`. **With no PR to be found,
`review-scope.sh` cannot run** (it needs a PR number): make it a full pass over `<BASE>...HEAD`
(`origin/main` when `BASE` is absent), post nothing, and say "no PR yet" in the review and the return.

## The return block

```
VERDICT: APPROVE | APPROVE WITH SUGGESTIONS | REQUEST CHANGES | BLOCK
REVIEWED-AT: <full HEAD sha>
OUTCOME-LEVEL: 1 | 2 | 3 — <one line: where the outcome came from>
Tracker: ok | skipped, no tracker | failed: <why>
DAR_RESULT: <the line review-post.sh printed, verbatim>   (no PR: write `GitHub post skipped (no PR)` instead, with no DAR_RESULT prefix)
Test ticket: written | skipped, no tracker | not applicable: <why> | failed: <why>
Memory: none | proposed: <what> | written: <what>
JUDGMENT-CALLS: <the review's Judgment calls section, or none>
REVIEW:
<the full review text>
```

`MODE: plan` returns the `PLAN-VERDICT` block of `plan-mode.md` instead.
