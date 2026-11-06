# fleet-workflow

A ticket workflow for Claude Code sessions run under FleetManager, with per-repo settings.

Status: early. The plugin ships its FleetManager contract, its settings and a PR reviewer agent. It adds no FleetManager commands yet: each command arrives together with the skill that backs it.

## Requirements

bash, git, jq and curl on your PATH.

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
| `review.botLogin` | `""` | The GitHub login the review is posted under. Empty means no posting, and every review pass is a full one. User layer only. |
| `review.tokenFile` | `""` | A path to a file holding that login's token. A leading `~` is expanded. Empty or missing means no posting. User layer only. |

### Layers

Three layers are deep-merged, and a later layer wins:

1. The plugin's own defaults (`defaults.json`).
2. Your user layer: `${CLAUDE_CONFIG_DIR:-~/.claude}/fleet-workflow.json`. This is where a team's distributed configuration drops its values.
3. The repo layer: `.claude/fleet-workflow.json` at the repo root.

Read them with the bundled script:

```
${CLAUDE_PLUGIN_ROOT}/scripts/settings.sh <dir> [key]
```

With no key it prints the merged JSON. With a dotted key it prints that value. A layer that is not a valid JSON object makes it exit 1 and name the file. An unknown key exits 2.

Values are commands your sessions run: review a change to this file like a change to a Makefile. Never put secrets in the committed repo file. Logins and tokens belong in the user layer.

## Review

The plugin ships a PR reviewer. Start it by its name, `fleet-workflow:reviewer`: as the `subagent_type` of the Agent tool, or as the `agentType` of a workflow. It checks first whether the diff delivered the ticket's outcome and acceptance criteria, then reviews craft: Rails, React, security and clean code.

A minimal spawn block:

```
WORKTREE: /abs/path/to/checkout
PR: 123
REPO: owner/repo
```

Every field is optional. A missing one is discovered from the checkout and its PR. The full block, with its defaults and the return shape, is in [skills/review/reference/spawn.md](skills/review/reference/spawn.md).

The review always comes back in the session. It is posted to the PR only when all three of these are set in your user layer (`${CLAUDE_CONFIG_DIR:-~/.claude}/fleet-workflow.json`):

```json
{
  "review": {
    "postToGitHub": true,
    "botLogin": "my-review-bot",
    "tokenFile": "~/.config/my-review-bot/token"
  }
}
```

The repo layer cannot set `review.botLogin` or `review.tokenFile`, so a committed file can never choose the identity or the token. The bot account must not be the PR's author, because GitHub does not let an account review its own PR. The token is read by `scripts/review-post.sh`, which prints one `DAR_RESULT:` line: `posted`, `skipped` or `failed`. Any `skipped` line means nothing was written to GitHub. With a `botLogin` set, a second pass reviews only what changed since that login's last review.

Without a tracker connected, the steps that read the ticket and write the test ticket report `skipped, no tracker`, and the review still completes. The reviewer cannot edit files. It is an agent, not a command, so it adds nothing to `fleetmanager-workflow.json`.

## FleetManager

The plugin ships `fleetmanager-workflow.json`, a contract 1 manifest. A command appears in it only once its skill exists.

Two installed workflow plugins that each ship a manifest cancel each other out: FleetManager offers neither's commands until a trusted repo's `.fleetmanager.json` picks one with `"workflow": "fleet-workflow@denwood-studio"`.

`${CLAUDE_PLUGIN_ROOT}/scripts/announce.sh <key=value>...` tells FleetManager about the session. It does nothing without `ORCH_HOOK_PORT`, prints nothing and always exits 0, so no session ever sees an error from it.

## License

MIT
