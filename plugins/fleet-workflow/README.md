# fleet-workflow

A ticket workflow for Claude Code sessions run under FleetManager, with per-repo settings.

Status: early. The plugin ships its FleetManager contract and its settings, but no commands yet. Each command arrives together with the skill that backs it.

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

## FleetManager

The plugin ships `fleetmanager-workflow.json`, a contract 1 manifest. A command appears in it only once its skill exists.

Two installed workflow plugins that each ship a manifest cancel each other out: FleetManager offers neither's commands until a trusted repo's `.fleetmanager.json` picks one with `"workflow": "fleet-workflow@denwood-studio"`.

`${CLAUDE_PLUGIN_ROOT}/scripts/announce.sh <key=value>...` tells FleetManager about the session. It does nothing without `ORCH_HOOK_PORT`, prints nothing and always exits 0, so no session ever sees an error from it.

## License

MIT
