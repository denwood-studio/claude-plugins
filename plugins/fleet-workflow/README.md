# fleet-workflow

A ticket workflow for Claude Code sessions run under FleetManager, with per-repo settings.

Status: early. The ticket lifecycle ships as agents and skills (start a ticket, open its PR, clean up after merge). Commands arrive with do-ticket, each together with the skill that backs it.

## Requirements

bash, git, jq, curl and [gh](https://cli.github.com) (logged in) on your PATH.

A Linear MCP server connected under the name `linear`, so its tools are named `mcp__linear__*`. Add it with your own Linear API key:

```
claude mcp add --transport http linear https://mcp.linear.app/mcp --header "Authorization: Bearer <your Linear API key>"
```

The name matters: the agents and the write gate look for `mcp__linear__*`.

## Install

```
/plugin marketplace add denwood-studio/claude-plugins
/plugin install fleet-workflow@denwood-studio
```

## Settings

Settings are plain JSON. A repo that sets nothing gets the defaults.

| Key | Default | Meaning |
| --- | --- | --- |
| `tracker.team` | `""` | The tracker team new tickets go to. Empty means the ticket's own team. |
| `tracker.project` | `""` | The tracker project new tickets go to. Empty means none. |
| `check.command` | `""` | The command that checks a change. Empty means the check step reports skipped. |
| `worktree.setup` | `"scripts/worktree_setup.sh"` | A repo-relative path, run from the new worktree if it exists. Empty means none. |
| `review.postToGitHub` | `false` | Whether a review is posted to the pull request. `false` means the review is returned in the session. |

### Layers

Three layers are deep-merged, and a later layer wins:

1. The plugin's own defaults (`defaults.json`).
2. Your user layer: `fleet-workflow.json` in your Claude config directory (`$CLAUDE_CONFIG_DIR`, default `$HOME/.claude`). This is where a team's distributed configuration drops its values.
3. The repo layer: `.claude/fleet-workflow.json` at the repo root.

Read them with the bundled script:

```
${CLAUDE_PLUGIN_ROOT}/scripts/settings.sh <dir> [key]
```

With no key it prints the merged JSON. With a dotted key it prints that value. A layer that is not a valid JSON object makes it exit 1 and name the file. An unknown key exits 2.

Values are commands your sessions run: review a change to this file like a change to a Makefile. Never put secrets in the committed repo file. Logins and tokens belong in the user layer.

## Ticket lifecycle

The lifecycle is three agents and two skills. Spawn an agent by its namespaced name, for example `fleet-workflow:setup-ticket`.

| Step | Agent | What it does |
| --- | --- | --- |
| Start | `fleet-workflow:setup-ticket` | Takes a ticket id, optionally `REPO: <abs>` and `BASE: <branch>`. Sweeps worktrees whose PR has merged, cuts a worktree on the ticket's own branch, runs the repo's worktree setup, marks the ticket started and assigns it to you, reports the worktree to FleetManager, and returns the path and a summary. |
| PR | `${CLAUDE_PLUGIN_ROOT}/scripts/create-pr.sh <worktree> <base>` | Rebases the branch onto its base, pushes it, and opens the PR (or reuses the open one). Prints `PR: <url>`. |
| Clean up | `fleet-workflow:cleanup-ticket` | Verifies the PR is merged, marks the ticket completed, posts your session summary as a comment, and returns a `SWEEP:` command. Run that from the main checkout: it removes the worktree and the branch. |
| File | `fleet-workflow:create-ticket` | Writes a ticket from a complete brief, or returns `INCOMPLETE:` naming what is missing. |

The `tracker` skill carries the Linear tool signatures and write rules; the `git` skill carries the worktree, commit and PR conventions.

### Worktree setup

A repo can bootstrap its own worktrees, for example by linking `.env` files. `setup-ticket` reads the `worktree.setup` setting; if the file it names exists in the new worktree it runs it from there, and otherwise it skips. A repo with no setup script still gets a working worktree.

### Tracker write gate

A Linear write (`save_*`, `create_*`, `delete_*`) is denied until the `tracker` skill is loaded in that session or subagent; reads always pass. Loading `fleet-workflow:tracker` unlocks writes for the context that loaded it, and no other. The plugin's agents preload the skill, so they are never denied. The gate keeps its own marker, so a hook of your own on `mcp__linear__.*` neither satisfies it nor is satisfied by it, and neither fires twice.

## FleetManager

The plugin ships `fleetmanager-workflow.json`, a contract 1 manifest. A command appears in it only once its skill exists.

Two installed workflow plugins that each ship a manifest cancel each other out: FleetManager offers neither's commands until a trusted repo's `.fleetmanager.json` picks one with `"workflow": "fleet-workflow@denwood-studio"`.

`${CLAUDE_PLUGIN_ROOT}/scripts/announce.sh <key=value>...` tells FleetManager about the session. It does nothing without `ORCH_HOOK_PORT`, prints nothing and always exits 0, so no session ever sees an error from it.

`${CLAUDE_PLUGIN_ROOT}/scripts/report-worktree.sh <path>` tells FleetManager where a session's worktree is. It behaves the same way: nothing without `ORCH_HOOK_PORT`, no output, always exit 0.

## License

MIT
