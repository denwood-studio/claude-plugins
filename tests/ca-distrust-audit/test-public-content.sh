#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="${PUBLIC_CONTENT_PLUGIN_DIR:-$REPO/plugins/ca-distrust-audit}"
MARKETPLACE="${PUBLIC_CONTENT_MARKETPLACE:-$REPO/.claude-plugin/marketplace.json}"
README="${PUBLIC_CONTENT_README:-$REPO/README.md}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

PATTERNS=(
  'NAR-[0-9]'
  '(?i)storyfolio|digibooks'
  'studio-memory'
  '\.secrets'
  '(?i)co-authored-by'
  '(?i)generated with.*claude'
  '/Users/[A-Za-z]'
)

# prints "<file>: <pattern>" per hit; returns 1 on any hit or scanner error
scan_file() {
  local f="$1" p hit=0 prc
  for p in "${PATTERNS[@]}"; do
    prc=0
    perl -ne '$m = 1 if m{'"$p"'}; END { exit($m ? 0 : 1) }' "$f" 2> /dev/null || prc=$?
    if [ "$prc" -eq 0 ]; then
      echo "$f: $p"
      hit=1
    elif [ "$prc" -ne 1 ]; then
      echo "$f: scanner error on $p"
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

jq '.plugins[] | select(.name == "ca-distrust-audit")' "$MARKETPLACE" > "$tmp/entry.json"
[ -s "$tmp/entry.json" ] || { echo "FAIL [marketplace-has-ca-distrust-audit-entry]"; fail=1; }
rc=0; out="$(scan_file "$tmp/entry.json")" || rc=$?
report "marketplace-entry-is-public-clean" clean "$rc" "$out"

rc=0; out="$(scan_file "$README")" || rc=$?
report "root-readme-is-public-clean" clean "$rc" "$out"

probe() {
  local name="$1" text="$2" f="$tmp/probe-$1.txt"
  printf '%s\n' "$text" > "$f"
  rc=0; out="$(scan_file "$f")" || rc=$?
  report "scanner-flags-$name" dirty "$rc" "$out"
}
probe ticket-id "see NAR-1234"
probe product "Storyfolio"
probe product-two "digibooks"
probe brain "studio-memory/projects.md"
probe secrets "~/.secrets/x"
probe coauthor "Co-Authored-By: someone"
probe generated "Generated with Claude Code"
probe home-path "/Users/someone/project"

printf '%s\n' "ca-distrust-audit by Denwood Studio, an unofficial plugin" > "$tmp/ok.txt"
rc=0; out="$(scan_file "$tmp/ok.txt")" || rc=$?
report "scanner-allows-ordinary-text" clean "$rc" "$out"

exit "$fail"
