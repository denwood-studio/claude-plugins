---
name: tracker
description: Operates the Linear MCP server for ticket work (read and write issues, comments, labels, statuses and documents) with the exact tool signatures and the rules every write follows. Load before any Linear write; the plugin's write gate denies a write until this skill is loaded.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/settings.sh:*)
---

# Tracker

Linear through the `linear` MCP server (tools named `mcp__linear__*`). Read this before you write, and never state a ticket's details from memory: fetch them.

The plugin's gate lets a Linear read through always and denies a write (`save_*`, `create_*`, `delete_*`) until this skill is loaded in your context. If a write is denied, load this skill and retry.

## Team and project

They come from the repo's settings, not from this file:

```
${CLAUDE_PLUGIN_ROOT}/scripts/settings.sh <repo> tracker.team
${CLAUDE_PLUGIN_ROOT}/scripts/settings.sh <repo> tracker.project
```

`<repo>` is the repo checkout you are working in. An empty `tracker.team` means the ticket's own team when you are updating a ticket, and the caller's to name when you are creating one: ask, or return the gap. An empty `tracker.project` means no project.

A team's own constants (project ids, label sets, house rules for labels) belong in its user-layer settings or its own skill, not here.

## Priority

`1` Urgent, `2` High, `3` Medium, `4` Low, `0` None. Set one when you create an issue; avoid `0`.

## States

Teams name their states differently, so do not hardcode a name. Pass a state **type** (`backlog`, `unstarted`, `started`, `completed`, `canceled`) or read the team's own states and pass one of those:

```
list_issue_statuses(team: <team>)
```

A team may have several states of one type (two `started` states, say). The type then resolves to one of them; pass the state's name or id when it matters which. Check the spelling of a name against that list: a name that does not exist silently does nothing.

Linear has no `Blocked` state by default. Say it in a comment and leave the state, or move the ticket back with a note.

## Labels

Check a label against `list_issue_labels(team: <team>)` before you use it: labels are team-scoped, so a lookup without `team` reports a valid label as absent. Never create a label to make a write pass. `labels` on `save_issue` replaces the whole set; use `addLabels` and `removeLabels` to change one.

## Writes

- **Output the URL after every write.** After every `save_issue` (create or update), `save_comment` or `save_status_update`, print the Linear URL from the response: `**<ID>** — <title> → <url>`.
- **Call as the state changes.** Do not batch a state change to the end of the work.
- **Reconcile the Outcome.** A `save_issue` that changes what the ticket is asking for (its scope, its acceptance criteria, a settled decision) reconciles the ticket's `## Outcome` in the same write: not a follow-up, the same call. Update it, or deliberately confirm it still holds. Silence is not confirmation: an edit that rewrites the ask and leaves the Outcome untouched by default is the failure. This binds everyone who edits a ticket. Exempt are edits that plainly cannot change the ask: a label, a priority, a state, a typo, a broken link. A substantive edit that leaves the Outcome untouched is incomplete.

## Tool reference

Exact signatures for every read and write are in `reference/mcp-tools.md`. Read it before calling anything: a guessed signature is the main source of failed writes.
