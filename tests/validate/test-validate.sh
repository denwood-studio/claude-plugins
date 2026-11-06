#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "PASS [$1]"; else echo "FAIL [$1]: got '$2' want '$3'"; fail=1; fi
}

root="$tmp/root"
mkdir -p "$root/scripts" "$root/.claude-plugin"
cp "$REPO/scripts/validate.sh" "$root/scripts/validate.sh"
printf '%s\n' '{"name":"fixture","owner":{"name":"fixture"},"metadata":{"description":"fixture"},"plugins":[{"name":"gone","source":"./plugins/gone","description":"fixture"}]}' \
  > "$root/.claude-plugin/marketplace.json"

rc=0; out="$(bash "$root/scripts/validate.sh" 2>&1)" || rc=$?
check "marketplace-with-missing-plugin-source-fails-validate" "$([ "$rc" -ne 0 ] && echo failed || echo passed)" "failed"
check "missing-plugin-source-is-the-named-failure" "$(printf '%s\n' "$out" | grep -E '^(PASS|FAIL) ' | sort | tr '\n' ';')" "FAIL plugin:./plugins/gone (exit 1);PASS marketplace;"

exit "$fail"
