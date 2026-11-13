# claude-plugins

Denwood Studio's Claude Code plugins.

## Plugins

| Plugin | What it is |
| --- | --- |
| [ca-distrust-audit](plugins/ca-distrust-audit/README.md) | A read-only audit of whether your machine or repo still trusts a distrusted certificate authority chain, starting with the October 2026 eMudhra compromise. |

## Install

```
claude plugin marketplace add denwood-studio/claude-plugins
claude plugin install ca-distrust-audit@denwood-studio
```

## Validate

```
make validate
```

Needs claude, jq, git and curl on your PATH. It validates the marketplace and every plugin with `claude plugin validate --strict`, then runs every `tests/*/test-*.sh`.
