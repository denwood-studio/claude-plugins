# claude-plugins

Denwood Studio's Claude Code plugins.

## Plugins

| Plugin | What it is |
| --- | --- |
| [fleet-workflow](plugins/fleet-workflow/README.md) | A ticket workflow for Claude Code sessions run under FleetManager, with per-repo settings. |

## Install

```
/plugin marketplace add denwood-studio/claude-plugins
/plugin install fleet-workflow@denwood-studio
```

## Validate

```
make validate
```

Needs claude, jq, git and curl on your PATH. It validates the marketplace and every plugin with `claude plugin validate --strict`, then runs every `tests/*/test-*.sh`.

## Developing

- A command enters a plugin's `fleetmanager-workflow.json` in the same change as its skill. `tests/fleet-workflow/test-manifest.sh` enforces it.
- A setting enters `defaults.json` in the same change as the code that reads it.
- Skills reach plugin scripts as `${CLAUDE_PLUGIN_ROOT}/scripts/...`. Claude Code substitutes that in skill and agent markdown, in a skill's `allowed-tools` frontmatter and in hooks. It is not in the Bash environment, and not in workflow scripts: a skill that launches a workflow passes the root in `args`. Name a skill and a workflow differently, or the workflow shadows the skill.
- Plugin agents are called `<plugin>:<agent>`, for example `subagent_type: fleet-workflow:<agent>`. A workflow's `agent()` takes the same name as `agentType`, and a plugin workflow launches as `fleet-workflow:<workflow>`.
- Plugin agents ignore the `hooks`, `mcpServers` and `permissionMode` frontmatter.
- Do not name a defaults file `settings.json` at a plugin root: Claude Code reads that name as the plugin's own settings.
- With another workflow plugin installed, develop with `claude --plugin-dir plugins/fleet-workflow`, not a user-scope install. Two installed workflow plugins cancel out in FleetManager.
