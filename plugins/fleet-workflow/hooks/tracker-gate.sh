#!/usr/bin/env bash
# PreToolUse hook (matcher: mcp__linear__.*): block Linear MCP write tools unless the
# tracker skill has been loaded in the current session or subagent. Only save_*, create_*
# and delete_* are gated; the case below is the one place that scope is defined.
#
# Detection is marker-based: tracker-marker.sh touches a per-context marker when
# Skill(fleet-workflow:tracker) runs, before the next tool's PreToolUse. A subagent that
# preloads the skill through its `skills:` frontmatter never makes a Skill call, so for
# those the gate resolves the agentType from subagents/agent-<id>.meta.json and reads the
# agent's frontmatter: a plugin agent (fleet-workflow:<name>) from this plugin's agents/,
# any other from the user agents directory under $HOME or the project .claude/agents.
#
# The marker name differs from any other gate's, so a user's own settings-registered hook
# and this one never satisfy or overwrite each other.

set -u

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

deny() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Load the tracker skill before calling Linear write tools. Invoke Skill(fleet-workflow:tracker) first."}}'
  exit 0
}

frontmatter_lists_skill() {
  awk -v pat="$2" '
    BEGIN { fm=0; in_skills=0; found=0 }
    /^---[[:space:]]*$/ { fm++; if (fm==2) exit; next }
    fm==1 && /^skills:[[:space:]]*$/ { in_skills=1; next }
    fm==1 && /^[A-Za-z]/ { in_skills=0 }
    fm==1 && in_skills && $0 ~ pat { found=1; exit }
    END { exit !found }
  ' "$1"
}

agent_has_tracker_skill() {
  local agent_type="$1" f name
  case "$agent_type" in
    fleet-workflow:*)
      name="${agent_type#fleet-workflow:}"
      case "$name" in */*|.*) return 1 ;; esac
      f="$PLUGIN_ROOT/agents/$name.md"
      [ -r "$f" ] && frontmatter_lists_skill "$f" '^[[:space:]]+-[[:space:]]+(fleet-workflow:)?tracker[[:space:]]*$'
      return
      ;;
  esac
  for f in "$HOME/.claude/agents/$agent_type.md" ".claude/agents/$agent_type.md"; do
    [ -r "$f" ] || continue
    frontmatter_lists_skill "$f" '^[[:space:]]+-[[:space:]]+fleet-workflow:tracker[[:space:]]*$' && return 0
  done
  return 1
}

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null || true)"

case "$tool_name" in
  mcp__linear__save_*|mcp__linear__create_*|mcp__linear__delete_*) ;;
  '') deny ;;
  *) exit 0 ;;
esac

[ -n "$transcript_path" ] || deny

base="${transcript_path%.jsonl}"
if [ -n "$agent_id" ]; then
  marker="${base}.agent-${agent_id}.fleet-workflow-tracker-loaded"
else
  marker="${base}.fleet-workflow-tracker-loaded"
fi
[ -f "$marker" ] && exit 0

if [ -n "$agent_id" ]; then
  meta_file="${base}/subagents/agent-${agent_id}.meta.json"
  agent_type="$(jq -r '.agentType // empty' "$meta_file" 2>/dev/null || true)"
  if [ -n "$agent_type" ] && agent_has_tracker_skill "$agent_type"; then
    exit 0
  fi
fi

deny
