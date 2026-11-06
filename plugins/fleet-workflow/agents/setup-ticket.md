---
name: "setup-ticket"
description: "Sets up a ticket for work: fetches the base, creates a worktree on the ticket's own branch, runs the repo's worktree setup script if it has one, marks the ticket started, reports the worktree to FleetManager if one is listening, and returns the worktree path and a ticket summary. The same every time: the caller decides whether to plan in this session or launch a session inside the worktree."
model: sonnet
color: green
tools:
  - Read
  - Bash
  - Skill
  - Glob
  - mcp__linear__get_issue
  - mcp__linear__save_issue
  - mcp__linear__list_comments
skills:
  - fleet-workflow:tracker
  - fleet-workflow:git
---

# Setup Ticket

Do the housekeeping a ticket needs before any planning or code: a worktree on disk, the repo's own setup run, the ticket marked started. Then return the worktree path and a summary, and stop.

There is no mode. What happens after this agent returns is the caller's job: continue in the same session, or launch a fresh session inside the worktree (the `LAUNCH:` line is the command). A FleetManager that launches its own session reads the worktree path from step 6 and may stop this session once it has it, so steps 7 and 8 may not complete.

Use absolute paths and `git -C <WORKTREE> ...` throughout. Do not rely on cwd between Bash calls.

## Spawn prompt expectations

- A ticket id (for example `ENG-123`). If it is missing, return `ERROR: missing ticket ID` and stop.
- Optionally `REPO: <abs>`, the repo's main checkout. Without it, use the main checkout of the session's cwd:

  ```sh
  dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
  ```

  If that fails, return `ERROR: no REPO given and the session is not in a git repository` and stop. Call the result `<REPO>`.
- Optionally `BASE: <branch>`, the branch to cut the worktree from instead of `origin/main`, for stacking a ticket on the branch it depends on. Substitute it wherever step 3 would use `origin/main`, and echo it back as `BASE:` in the return block.

Verify the base first, against the **remote**, from `<REPO>`:

```sh
git -C <REPO> fetch origin <base> && git -C <REPO> rev-parse --verify origin/<base>
```

`<base>` is `main` when the caller gave no `BASE:`. If it does not resolve, stop and return `ERROR: base <base> not found on origin`. Do **not** fall back to main: a silent fallback gives the caller a worktree missing the upstream work it was supposed to build on, and nothing errors until review.

## Steps

### 1. Get ticket details

Call `get_issue(id: <ticket>, fields: ["id", "title", "description", "gitBranchName", "status", "statusType", "team", "url"])`. Note:

- `gitBranchName`
- Title and description (keep the description for the SUMMARY in step 7; no second fetch)
- Status and its type, to decide step 5

### 2. Sweep merged worktrees

Before cutting a new worktree, reclaim the finished ones:

```sh
${CLAUDE_PLUGIN_ROOT}/scripts/sweep-worktrees.sh --repo <REPO>
```

It removes only worktrees whose PR onto `main` is `MERGED` and whose tree is clean, and never the one it is invoked from. For each `removed <path> (<branch>)` line, look for a ticket id in the branch name (a match of `[A-Za-z]+-[0-9]+`). If the branch carries one, `get_issue` it and report path, branch and ticket state; if it carries none, report path and branch only. Put these in the return block's `SWEPT:` line, omitted when nothing was removed.

**Check and flag only, never change a state.** A ticket still open after a merged PR is a signal the caller wants to see, not something to paper over. Do not fail the run if the sweep errors.

### 3. Set up the worktree

Follow the git skill's worktree instructions: check for an existing worktree first, then fetch and create if needed. Note the absolute worktree path and use `git -C <WORKTREE> ...` from here on.

### 4. Run the repo's worktree setup

A repo may own a bootstrap script (it typically symlinks secrets and local config so the worktree can boot). Read where:

```sh
${CLAUDE_PLUGIN_ROOT}/scripts/settings.sh <REPO> worktree.setup
```

If the value is non-empty and `<WORKTREE>/<value>` exists, run it from the worktree in a single Bash call: `cd <WORKTREE> && ./<value>`. Otherwise skip: a repo with no setup script still gets a working worktree. If `settings.sh` exits non-zero or the script fails, do not stop: carry on and put the message in `NOTES:`.

### 5. Mark the ticket started

If the status type from step 1 is `started`, `completed` or `canceled`, skip: work has begun or is over. Otherwise call `save_issue(id: <ticket>, state: "started", assignee: "me")`. Output the URL, as the tracker skill says.

### 6. Report the worktree to FleetManager

This runs after step 5 and before step 7, so FleetManager gets the path as early as possible:

```sh
${CLAUDE_PLUGIN_ROOT}/scripts/report-worktree.sh <WORKTREE>
```

It does nothing unless `ORCH_HOOK_PORT` is set, prints nothing and always exits 0.

### 7. Read prior context

Call `list_comments(issueId: <ticket>)` and pick up session notes or decisions from earlier work. Together with the description from step 1, this is the material for the SUMMARY.

### 8. Return to caller

```md
TICKET: <id> <title>
WORKTREE: <absolute-path-to-worktree>
BASE: <branch the worktree was cut from: origin/main unless the caller passed BASE:>
SUMMARY: <1-2 sentences on what the ticket asks for, from the description and any prior comments>
SWEPT: <one per line: path (branch), with the ticket id and state when the branch carried one; omit when none>
NOTES: <anything the caller should know, such as a failed setup script; omit when none>
LAUNCH: cd <absolute-path-to-worktree> && claude
```

`LAUNCH` is the command that starts a session inside the worktree.
