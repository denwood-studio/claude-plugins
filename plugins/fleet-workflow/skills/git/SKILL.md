---
name: git
description: Git and GitHub CLI operator. Use when working with branches, worktrees, commits, pull requests, or CI checks. One worktree per ticket, a script that opens the PR, and a script that cleans up after merge.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/create-pr.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/sweep-worktrees.sh:*)
---

# Git & GitHub Operator

Use when branching, committing, opening PRs, or checking CI.

---

## Git Worktrees

Every ticket gets its own worktree. Never work directly in the main repo checkout.

**Naming convention:** `../<repo-name>-<gitBranchName>`, a sibling of the main repo dir.
Example: `../my-app-ENG-214` alongside `my-app`. The branch name is the `gitBranchName` the tracker gives the ticket.

**Sanitize the path component:** if `gitBranchName` contains a `/` (for example `user/eng-123-slug`), replace each `/` with `-` in the **directory name** only, giving `../my-app-user-eng-123-slug`, so the worktree stays a flat sibling instead of nesting directories. The branch itself keeps its real name (`-b <gitBranchName>`).

### Create a worktree + new branch
```
git fetch origin main
git worktree add -b <gitBranchName> ../<repo-name>-<gitBranchName> origin/main
```

### Create a worktree for an existing branch
```
git worktree add ../<repo-name>-<gitBranchName> <gitBranchName>
```

### List / remove worktrees
```
git worktree list
git worktree remove ../<repo-name>-<gitBranchName>
git worktree prune
git branch -D <gitBranchName>  # force delete: safe after a confirmed PR merge
```

For a post-merge cleanup run the sweep from the main checkout instead:

```
${CLAUDE_PLUGIN_ROOT}/scripts/sweep-worktrees.sh [--repo <main checkout>] [<branch>]
```

It checks the PR is merged, removes the worktree, prunes, and deletes the branch. It never removes the worktree it runs in: a session inside a worktree cannot clean itself up, so run it from the main checkout or from another worktree. `--dry-run` lists what it would remove; `--base <branch>` sweeps worktrees whose merged PR targeted an integration branch.

### Agent isolation
When spawning an Agent that will make file edits, pass `isolation: "worktree"` so it runs in a clean copy and cannot clobber your working tree.

### Prefer worktrees over stash
Any context switch longer than a few minutes deserves its own worktree, not `git stash push/pop`. Stashes pile up, lose context, and don't carry across branches.

---

## Branch Workflows

Branches are always created inside a worktree, never with `git checkout -b` in the main repo checkout.

### Sync with main
```
git fetch origin main
git rebase origin/main
```
Prefer rebase over merge to keep history clean. `create-pr.sh` does this for you when it opens the PR.

### Push branch and set upstream
```
git push -u origin <branch-name>
```
Required for the first push of a new branch. Prefer an explicit refspec (`git push origin HEAD:refs/heads/<branch>`) so a bare push cannot land on the wrong branch.

---

## Commits

**Message rules:**

- Output as plain text, never inside a code block or quotes
- One line, subject only, unless the repo's own convention says otherwise
- No hard line wraps, no indentation, no punctuation at the end
- Describe what actually changed, not what was attempted or discussed

**Grouping:** one commit per coherent change. Test: "if someone reverts this commit, does exactly one thing get undone?" When in doubt, fewer larger commits beat tiny ones that don't stand alone.

**Staging:** name the paths you changed. Never `git add -A` or `git add .`: working trees carry edits from outside the session (a parallel session, a live-editing tool, a stray profile tweak), and a blanket add sweeps them into someone else's commit.

**Scope `git commit` by pathspec when the index isn't yours.** `git add <path>` is scoped; the `git commit` that follows is not: it commits the whole index, sweeping in anything staged earlier. Use `git commit -m "…" -- <path>` whenever you're committing a subset of a tree you don't exclusively control.

---

## Pull Requests

### Open a PR

```
${CLAUDE_PLUGIN_ROOT}/scripts/create-pr.sh <worktree> <base> [--title <t>] [--body-file <f>]
```

`<base>` is required and is never assumed to be `main`. The script rebases the branch onto `origin/<base>`, pushes it with `--force-with-lease` on an explicit refspec, and opens the PR (or reuses the open one, retargeting it if the base differs). It prints `PR: <url>` and `BASE: <branch>`, and `STACKED: <branches>` when other local branches sat on commits the rebase rewrote.

- The default title is the first ticket id in the branch name, upper-cased, then the last commit subject: branch `abc-12-x` gives `ABC-12: <subject>`. Put the ticket id in the title so the tracker's GitHub integration picks it up; pass `--title` to override.
- The default body is the commit list. Pass `--body-file` for a fuller one, for example:

```md
## Summary
- <bullet 1>
- <bullet 2>

## Details
<optional: include for larger PRs, omit for small/obvious ones>

## Risk
- <thing that could break or needs watching>
```

- The script never asks a question. A failure is `ERROR: <reason>` on stderr and a non-zero exit: 2 usage, 3 dirty tree / unresolvable base / nothing to open, 4 rebase conflict, 5 push or `gh` failure. The ticket's state change stays with the caller.

The PR opens ready for review, not as a draft.

### Mark a draft PR ready for review
```
gh pr ready
```
Only needed for a PR you opened manually with `--draft`.

### Check status and CI
```
gh pr view              # description, reviewers, labels
gh pr checks            # CI check run results
gh run list --branch <branch>
gh run watch <run-id>   # streams live until done
```

### Merge a PR
```
gh pr merge --squash --delete-branch
gh pr merge --merge --delete-branch
gh pr merge --rebase --delete-branch
```
Check the repo convention before picking a strategy.

---

## Resolving Merge Conflicts

1. `git fetch origin`
2. `git rebase origin/main` (a separate Bash call from step 1: chaining with `&&` after `git fetch` can land the rebase in the wrong cwd because the Bash tool's cwd is per-call in some harnesses)
3. Resolve markers (`<<<<`, `====`, `>>>>`) in each conflicted file
4. `git add <resolved-files>`
5. `git rebase --continue`
6. If the rebase gets messy: `git rebase --abort` and investigate before retrying

---

## Adding Screenshots to a PR (private repos)

Use the blob URL with `?raw=true`; it works for any authenticated GitHub user.

1. Copy images into `.github/screenshots/` in the repo
2. Commit and push on the current branch
3. Reference in the PR body:
```markdown
![description](https://github.com/{owner}/{repo}/blob/{branch}/.github/screenshots/{file}?raw=true)
```

---

## Red flags: you are about to commit someone else's work

| Thought | Reality |
| --- | --- |
| "`git add -A` is faster, it's all my work anyway" | Working trees carry edits from parallel sessions and live-editing tools. Name the paths you changed. |
| "`git push` will go to the right place" | A bare push can land on the base branch. Use an explicit refspec every time, and check the branch at push time, not before the work. |
| "I staged only my files, so the commit is scoped" | `git add` is scoped; `git commit` is not: it takes the whole index. Use `git commit -m "…" -- <path>`. |
| "I'll stash it and come back" | Any context switch longer than a few minutes gets a worktree. Stashes lose context and don't cross branches. |
| "One commit per file keeps it clean" | One commit per coherent change. Test: revert it and exactly one thing gets undone. |
