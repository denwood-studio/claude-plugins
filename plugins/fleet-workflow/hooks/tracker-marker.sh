#!/usr/bin/env bash
# PostToolUse hook (matcher: Skill): when the tracker skill is loaded at runtime, touch a
# per-context marker that tracker-gate.sh checks before it allows a Linear write. Keyed
# identically to the gate: inside a subagent, transcript_path is the main session
# transcript and agent_id identifies the subagent. Change both marker paths together.

set -u

input="$(cat)"
skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // empty' 2>/dev/null || true)"
[ "$skill" = "fleet-workflow:tracker" ] || exit 0

transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null || true)"
[ -n "$transcript_path" ] || exit 0

base="${transcript_path%.jsonl}"
if [ -n "$agent_id" ]; then
  marker="${base}.agent-${agent_id}.fleet-workflow-tracker-loaded"
else
  marker="${base}.fleet-workflow-tracker-loaded"
fi

touch "$marker" 2>/dev/null || true
exit 0
