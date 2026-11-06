#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="${PUBLIC_CONTENT_PLUGIN_DIR:-$REPO/plugins/fleet-workflow}"
MARKETPLACE="${PUBLIC_CONTENT_MARKETPLACE:-$REPO/.claude-plugin/marketplace.json}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

PATTERNS=(
  '(?i)denwood'
  'NAR-[0-9]'
  'studio-memory'
  '\b(gp|area):[a-z]'
  '(?i)storyfolio|digibooks'
  'dar-github-token'
  '\.secrets'
  '(?i)\b(bob|georgia|igor|carla|priya|patricia|frank|boris|tim|robert|grill)\b'
)

# prints "<file>: <pattern>" per hit; returns 1 on any hit
scan_file() {
  local f="$1" p hit=0
  for p in "${PATTERNS[@]}"; do
    if perl -ne 's/denwood-studio//g; s/Denwood Studio//g; $m = 1 if /'"$p"'/; END { exit($m ? 0 : 1) }' "$f"; then
      echo "$f: $p"
      hit=1
    fi
  done
  return $hit
}

scan_dir() {
  local d="$1" f rc=0
  while IFS= read -r f; do
    scan_file "$f" || rc=1
  done < <(find "$d" -type f ! -name .DS_Store | sort)
  return $rc
}

fail=0
report() {
  local name="$1" want="$2" rc="$3" out="$4"
  if { [ "$want" = clean ] && [ "$rc" -eq 0 ]; } || { [ "$want" = dirty ] && [ "$rc" -ne 0 ]; }; then
    echo "PASS [$name]"
  else
    echo "FAIL [$name]: wanted $want"
    [ -z "$out" ] || echo "$out"
    fail=1
  fi
}

rc=0; out="$(scan_dir "$PLUGIN")" || rc=$?
report "plugin-files-are-public-clean" clean "$rc" "$out"

jq '.plugins[] | select(.name == "fleet-workflow")' "$MARKETPLACE" > "$tmp/entry.json"
[ -s "$tmp/entry.json" ] || { echo "FAIL [marketplace-has-fleet-workflow-entry]"; fail=1; }
rc=0; out="$(scan_file "$tmp/entry.json")" || rc=$?
report "marketplace-entry-is-public-clean" clean "$rc" "$out"

jq 'del(.plugins)' "$MARKETPLACE" > "$tmp/marketplace-top.json"
rc=0; out="$(scan_file "$tmp/marketplace-top.json")" || rc=$?
report "marketplace-top-level-fields-are-public-clean" clean "$rc" "$out"

probe() {
  local name="$1" text="$2" f="$tmp/probe-$1.txt"
  printf '%s\n' "$text" > "$f"
  rc=0; out="$(scan_file "$f")" || rc=$?
  report "scanner-flags-$name" dirty "$rc" "$out"
}
probe ticket-id "see NAR-1234"
probe org-name "Denwood-DAR"
probe persona "ask patricia"
probe brain "studio-memory/projects.md"
probe label "gp:launch"
probe product "storyfolio"
probe token "dar-github-token"
probe secrets "~/.secrets/x"

printf '%s\n' "denwood-studio/claude-plugins by Denwood Studio" > "$tmp/ok.txt"
rc=0; out="$(scan_file "$tmp/ok.txt")" || rc=$?
report "scanner-allows-the-publisher-tokens" clean "$rc" "$out"

exit "$fail"
