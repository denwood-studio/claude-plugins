#!/usr/bin/env bash
# Feeds crafted hook payloads to the tracker marker and gate hooks and asserts allow or deny.
# Write tools are used wherever the gate is the thing under test: a read is always allowed,
# so an allow-case on a read proves nothing.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$REPO/plugins/fleet-workflow"
HOOK="$PLUGIN/hooks/tracker-gate.sh"
MARKER_HOOK="$PLUGIN/hooks/tracker-marker.sh"
SKILL="fleet-workflow:tracker"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to run this test"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

transcript="$tmp/session.jsonl"
: > "$transcript"
base="${transcript%.jsonl}"

run_hook() { printf '%s' "$1" | bash "$HOOK"; }
run_marker_hook() { printf '%s' "$1" | bash "$MARKER_HOOK"; }

# Takes the payload rather than the hook's output, so the exit status is asserted too.
# Optional third arg overrides HOME for the user-agent frontmatter cases.
assert_allow() {
  local label="$1" payload="$2" home="${3-}" hook="${4-$HOOK}" out rc
  set +e
  if [ -n "$home" ]; then
    out="$(printf '%s' "$payload" | HOME="$home" bash "$hook" 2>/dev/null)"
  else
    out="$(printf '%s' "$payload" | bash "$hook" 2>/dev/null)"
  fi
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { echo "FAIL [$label]: hook exited $rc"; exit 1; }
  [ -z "$out" ] || { echo "FAIL [$label]: expected allow (no output), got: $out"; exit 1; }
  echo "PASS [$label]: allowed"
}

assert_deny() {
  local label="$1" out="$2" decision
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null || true)"
  [ "$decision" = "deny" ] \
    || { echo "FAIL [$label]: expected permissionDecision=deny, got: $out"; exit 1; }
  echo "PASS [$label]: denied"
}

payload() { # tool_name [transcript_path] [agent_id]
  jq -nc --arg t "$1" --arg p "${2-}" --arg a "${3-}" \
    '{tool_name: $t} + (if $p == "" then {} else {transcript_path: $p} end)
                     + (if $a == "" then {} else {agent_id: $a} end)'
}

skill_payload() { # skill transcript_path [agent_id]
  jq -nc --arg s "$1" --arg p "$2" --arg a "${3-}" \
    '{tool_input:{skill:$s}, transcript_path:$p} + (if $a == "" then {} else {agent_id: $a} end)'
}

# --- Scope: only writes are gated ---

assert_allow "non-linear-tool" "$(payload Read "$transcript")"

for t in mcp__linear__get_issue mcp__linear__list_issues mcp__linear__search_documentation; do
  assert_allow "read-$t" "$(payload "$t" "$transcript")"
done

for t in mcp__linear__save_issue mcp__linear__create_issue_label mcp__linear__delete_comment; do
  assert_deny "write-$t-no-marker" "$(run_hook "$(payload "$t" "$transcript")")"
done

# --- Fail-closed inputs ---

assert_deny "empty-tool-name" "$(run_hook '{"transcript_path":"'"$transcript"'"}')"
assert_deny "malformed-stdin" "$(run_hook 'not valid json at all')"

# Without the guard, `base` is empty, the marker path becomes a bare relative name, and the
# gate resolves it against cwd: the directory holds exactly that file.
collide="$tmp/marker-collision"
mkdir -p "$collide"
: > "$collide/.fleet-workflow-tracker-loaded"
assert_deny "no-transcript-path" \
  "$(cd "$collide" && printf '%s' '{"tool_name":"mcp__linear__save_issue"}' | bash "$HOOK")"

# --- Deny reason names the skill that unlocks the gate ---

reason="$(run_hook "$(payload mcp__linear__save_issue "$transcript")" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$reason" in
  *"Skill($SKILL)"*) echo "PASS [deny-reason-names-the-skill]" ;;
  *) echo "FAIL [deny-reason-names-the-skill]: $reason"; exit 1 ;;
esac

# --- Marker detection, main session ---

# The marker hook writes where the gate looks: the two derivations must stay identical.
run_marker_hook "$(skill_payload "$SKILL" "$transcript")"
[ -f "${base}.fleet-workflow-tracker-loaded" ] \
  || { echo "FAIL [marker-hook-writes-where-gate-looks]: no marker at ${base}.fleet-workflow-tracker-loaded"; exit 1; }
echo "PASS [marker-hook-writes-where-gate-looks]: marker present"
assert_allow "write-after-marker" "$(payload mcp__linear__save_issue "$transcript")"

# Other skills, and a bare name that is not ours, never unlock the gate.
for s in linear git tracker fleet-workflow:git other:tracker; do
  t="$tmp/skill-$(printf '%s' "$s" | tr -c 'A-Za-z0-9' '_').jsonl"; : > "$t"
  run_marker_hook "$(skill_payload "$s" "$t")"
  assert_deny "write-after-skill-$s" "$(run_hook "$(payload mcp__linear__save_issue "$t")")"
done

# A marker left by another gate's naming scheme does not satisfy this one.
foreign="$tmp/foreign.jsonl"; : > "$foreign"
: > "${foreign%.jsonl}.linear-skill-loaded"
assert_deny "other-gates-marker-does-not-unlock" "$(run_hook "$(payload mcp__linear__save_issue "$foreign")")"

# And this gate's marker is not the name another gate looks for.
case "${base}.fleet-workflow-tracker-loaded" in
  *.linear-skill-loaded) echo "FAIL [marker-name-distinct]"; exit 1 ;;
  *) echo "PASS [marker-name-distinct]" ;;
esac

# --- Marker keying is per-context ---

assert_deny "main-marker-does-not-cover-subagent" \
  "$(run_hook "$(payload mcp__linear__save_issue "$transcript" agent-one)")"

run_marker_hook "$(skill_payload "$SKILL" "$transcript" agent-one)"
assert_allow "subagent-own-marker" "$(payload mcp__linear__save_issue "$transcript" agent-one)"

assert_deny "sibling-subagent-not-covered" \
  "$(run_hook "$(payload mcp__linear__save_issue "$transcript" agent-two)")"

other="$tmp/other.jsonl"; : > "$other"
run_marker_hook "$(skill_payload "$SKILL" "$other" agent-one)"
assert_deny "subagent-marker-does-not-cover-main" "$(run_hook "$(payload mcp__linear__save_issue "$other")")"

# --- Frontmatter fallback: plugin agents ---
# A plugin agent that preloads the skill never makes a Skill call, so no marker exists. The
# gate reads <plugin root>/agents/<name>.md, the plugin root being derived from the hook's
# own path, so a synthetic plugin tree beside a copy of the hooks stands in for it.

mkdir -p "${base}/subagents"
write_meta() { printf '{"agentType":"%s"}\n' "$2" > "${base}/subagents/agent-$1.meta.json"; }

for a in setup-ticket cleanup-ticket create-ticket; do
  write_meta "real-$a" "fleet-workflow:$a"
  assert_allow "shipped-agent-$a-is-allowed" "$(payload mcp__linear__save_issue "$transcript" "real-$a")"
done

fake="$tmp/fake-plugin"
mkdir -p "$fake/hooks" "$fake/agents"
cp "$HOOK" "$fake/hooks/tracker-gate.sh"
agent_file() { # name, skills...
  local n="$1"; shift
  { printf -- '---\nname: "%s"\nmodel: sonnet\n' "$n"; if [ $# -gt 0 ]; then printf 'skills:\n'; printf '  - %s\n' "$@"; fi; printf -- '---\nbody\n'; } > "$fake/agents/$n.md"
}
agent_file qualified fleet-workflow:tracker git
agent_file bare tracker
agent_file wrong-skill linear git
agent_file none
{ printf -- '---\nname: "body-only"\nskills:\n  - git\n---\nIn the body:\n  - tracker\n  - fleet-workflow:tracker\n'; } > "$fake/agents/body-only.md"
{ printf -- '---\nname: "other-key"\nskills:\n  - git\nmcpServers:\n  - tracker\n  - fleet-workflow:tracker\n---\nbody\n'; } > "$fake/agents/other-key.md"

fake_allow() { assert_allow "$1" "$(payload mcp__linear__save_issue "$transcript" "$2")" "" "$fake/hooks/tracker-gate.sh"; }
fake_deny() { assert_deny "$1" "$(printf '%s' "$(payload mcp__linear__save_issue "$transcript" "$2")" | bash "$fake/hooks/tracker-gate.sh")"; }

write_meta p-qualified fleet-workflow:qualified; fake_allow "plugin-agent-qualified-skill-entry" p-qualified
write_meta p-bare fleet-workflow:bare;           fake_allow "plugin-agent-bare-skill-entry" p-bare
write_meta p-wrong fleet-workflow:wrong-skill;   fake_deny "plugin-agent-without-the-skill" p-wrong
write_meta p-none fleet-workflow:none;           fake_deny "plugin-agent-with-no-skills" p-none
write_meta p-body fleet-workflow:body-only;      fake_deny "plugin-agent-body-mention-does-not-count" p-body
write_meta p-key fleet-workflow:other-key;       fake_deny "plugin-agent-skill-under-another-key-does-not-count" p-key
write_meta p-missing fleet-workflow:no-such;     fake_deny "plugin-agent-with-no-file" p-missing
write_meta p-trav "fleet-workflow:../agents/qualified"; fake_deny "plugin-agent-name-with-a-slash" p-trav
write_meta p-foreign other:qualified;            fake_deny "another-plugin-agent-is-not-resolved-here" p-foreign
printf 'not json\n' > "${base}/subagents/agent-p-badmeta.meta.json"; fake_deny "unparseable-meta-file" p-badmeta
fake_deny "no-meta-file" p-nometa

# --- Frontmatter fallback: user agents ---

fake_home="$tmp/home"
mkdir -p "$fake_home/.claude/agents"
user_agent() { # dir name, skills...
  local d="$1" n="$2"; shift 2
  { printf -- '---\nname: "%s"\nmodel: sonnet\nskills:\n' "$n"; printf '  - %s\n' "$@"; printf -- '---\nbody\n'; } > "$d/$n.md"
}
user_agent "$fake_home/.claude/agents" u-qualified fleet-workflow:tracker git
user_agent "$fake_home/.claude/agents" u-bare tracker
user_agent "$fake_home/.claude/agents" u-linear linear

write_meta u1 u-qualified
assert_allow "user-agent-qualified-skill-entry" "$(payload mcp__linear__save_issue "$transcript" u1)" "$fake_home"
write_meta u2 u-bare
assert_deny "user-agent-bare-name-could-be-any-skill" \
  "$(HOME="$fake_home" run_hook "$(payload mcp__linear__save_issue "$transcript" u2)")"
write_meta u3 u-linear
assert_deny "user-agent-preloading-another-skill" \
  "$(HOME="$fake_home" run_hook "$(payload mcp__linear__save_issue "$transcript" u3)")"

proj="$tmp/project"
empty_home="$tmp/empty-home"
mkdir -p "$proj/.claude/agents" "$empty_home"
user_agent "$proj/.claude/agents" proj-agent fleet-workflow:tracker
write_meta u4 proj-agent
set +e
out="$(cd "$proj" && printf '%s' "$(payload mcp__linear__save_issue "$transcript" u4)" | HOME="$empty_home" bash "$HOOK" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "FAIL [project-local-agents-path]: hook exited $rc"; exit 1; }
[ -z "$out" ] || { echo "FAIL [project-local-agents-path]: expected allow, got: $out"; exit 1; }
echo "PASS [project-local-agents-path]: allowed"

# --- Registration ---

hooks_json="$PLUGIN/hooks/hooks.json"
jq -e . "$hooks_json" >/dev/null || { echo "FAIL [hooks-json-valid]"; exit 1; }
echo "PASS [hooks-json-valid]"

jq -e '.hooks.PostToolUse | length == 1 and .[0].matcher == "Skill"' "$hooks_json" >/dev/null \
  || { echo "FAIL [post-tool-use-matches-skill]"; exit 1; }
jq -e '.hooks.PreToolUse | length == 1 and .[0].matcher == "mcp__linear__.*"' "$hooks_json" >/dev/null \
  || { echo "FAIL [pre-tool-use-matches-linear]"; exit 1; }
echo "PASS [matchers]"

while IFS= read -r cmd; do
  path="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN}"
  path="${path#\"}"; path="${path%\"}"
  case "$path" in "$PLUGIN"/hooks/*) ;; *) echo "FAIL [hook-command-under-plugin]: $cmd"; exit 1 ;; esac
  [ -x "$path" ] || { echo "FAIL [hook-command-resolves]: $cmd -> $path is not an executable file"; exit 1; }
done < <(jq -r '.hooks[][].hooks[].command' "$hooks_json")
echo "PASS [hook-commands-resolve-to-executables]"

jq -e 'has("hooks") | not' "$PLUGIN/.claude-plugin/plugin.json" >/dev/null \
  || { echo "FAIL [plugin-json-has-no-hooks-key]: hooks/hooks.json loads on its own; declaring it again registers it twice"; exit 1; }
echo "PASS [plugin-json-has-no-hooks-key]"

echo "All tracker gate tests passed."
