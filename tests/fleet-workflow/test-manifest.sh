#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="${MANIFEST_PLUGIN_DIR:-$REPO/plugins/fleet-workflow}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check_manifest() {
  local dir="$1" f="$1/fleetmanager-workflow.json" key prompt skill
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "$f is not a JSON object"; return 1; }
  [ "$(jq '.contract' "$f")" = "1" ] || { echo "contract is not 1"; return 1; }
  jq -e '(keys - ["contract","startTicket","coordinate"]) == []' "$f" >/dev/null ||
    { echo "unknown keys: $(jq -c 'keys - ["contract","startTicket","coordinate"]' "$f")"; return 1; }
  for key in startTicket coordinate; do
    jq -e --arg k "$key" 'has($k)' "$f" >/dev/null || continue
    prompt="$(jq -r --arg k "$key" '.[$k].prompt // ""' "$f")"
    skill="$(printf '%s' "$prompt" | sed -nE 's#^/fleet-workflow:([a-z0-9-]+)( .*)?$#\1#p')"
    [ -n "$skill" ] || { echo "$key prompt '$prompt' is not /fleet-workflow:<skill>"; return 1; }
    [ -f "$dir/skills/$skill/SKILL.md" ] || { echo "$key points at skill '$skill' with no skills/$skill/SKILL.md"; return 1; }
  done
  if jq -e 'has("startTicket")' "$f" >/dev/null; then
    jq -r '.startTicket.prompt' "$f" | grep -qF '{ticket}' || { echo "startTicket prompt lacks {ticket}"; return 1; }
  fi
  if jq -e 'has("coordinate")' "$f" >/dev/null; then
    jq -r '.coordinate.prompt' "$f" | grep -qF '{work}' || { echo "coordinate prompt lacks {work}"; return 1; }
  fi
  return 0
}

fail=0
expect() {
  local name="$1" want="$2" dir="$3" out rc=0
  out="$(check_manifest "$dir" 2>&1)" || rc=$?
  if { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } || { [ "$want" = reject ] && [ "$rc" -ne 0 ]; }; then
    echo "PASS [$name]"
  else
    echo "FAIL [$name]: wanted $want, rc=$rc ${out}"
    fail=1
  fi
}

fixture() {
  local name="$1" json="$2" skill="${3:-}"
  local d="$tmp/$name"
  mkdir -p "$d"
  printf '%s\n' "$json" > "$d/fleetmanager-workflow.json"
  [ -z "$skill" ] || { mkdir -p "$d/skills/$skill"; : > "$d/skills/$skill/SKILL.md"; }
  echo "$d"
}

expect "real-plugin-manifest" ok "$PLUGIN"

expect "fixture-valid-startTicket-with-skill" ok \
  "$(fixture good '{"contract":1,"startTicket":{"prompt":"/fleet-workflow:do-ticket {ticket}"}}' do-ticket)"
expect "fixture-valid-coordinate-with-skill" ok \
  "$(fixture good2 '{"contract":1,"coordinate":{"prompt":"/fleet-workflow:coordinator {work}"}}' coordinator)"
expect "rejects-release-key" reject \
  "$(fixture rel '{"contract":1,"release":{"prompt":"/fleet-workflow:release"}}' release)"
expect "rejects-bare-prompt-without-plugin-prefix" reject \
  "$(fixture bare '{"contract":1,"startTicket":{"prompt":"/do-ticket {ticket}"}}' do-ticket)"
expect "rejects-command-with-no-skill" reject \
  "$(fixture noskill '{"contract":1,"startTicket":{"prompt":"/fleet-workflow:do-ticket {ticket}"}}')"
expect "rejects-contract-2" reject \
  "$(fixture c2 '{"contract":2}')"
expect "rejects-startTicket-without-placeholder" reject \
  "$(fixture noph '{"contract":1,"startTicket":{"prompt":"/fleet-workflow:do-ticket"}}' do-ticket)"
expect "rejects-coordinate-without-placeholder" reject \
  "$(fixture nowork '{"contract":1,"coordinate":{"prompt":"/fleet-workflow:coordinator"}}' coordinator)"
expect "rejects-prefix-lookalike-skill-name" reject \
  "$(fixture look '{"contract":1,"startTicket":{"prompt":"/fleet-workflow:do-ticketx {ticket}"}}' do-ticket)"

exit "$fail"
