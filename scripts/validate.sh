#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

passed=0
failed=0
failed_names=()

record() {
  if [ "$1" -eq 0 ]; then
    passed=$((passed + 1)); echo "PASS $2"
  else
    failed=$((failed + 1)); failed_names+=("$2"); echo "FAIL $2 (exit $1)"
  fi
}

for tool in claude jq git curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL missing required tool: $tool"; exit 1; }
done

cd "$ROOT" || exit 1

run() {
  local name="$1"; shift
  local status=0 log="$LOG_DIR/${name//[^A-Za-z0-9._-]/_}.log"
  "$@" >"$log" 2>&1 || status=$?
  record "$status" "$name"
}

run "marketplace" claude plugin validate --strict .

sources="$(jq -r '.plugins[].source' .claude-plugin/marketplace.json 2>"$LOG_DIR/marketplace-sources.log")" || {
  record 1 "marketplace-sources"
  sources=""
}
while IFS= read -r src; do
  [ -n "$src" ] || continue
  run "plugin:$src" claude plugin validate --strict "$src"
done <<< "$sources"

for suite in "$ROOT"/tests/*/test-*.sh; do
  [ -f "$suite" ] || continue
  name="$(basename "$(dirname "$suite")")/$(basename "$suite")"
  run "$name" bash "$suite"
done

for name in "${failed_names[@]+"${failed_names[@]}"}"; do
  echo
  echo "===== output of $name ====="
  cat "$LOG_DIR/${name//[^A-Za-z0-9._-]/_}.log" 2>/dev/null
  echo "===== end of $name ====="
done

echo
echo "$passed passed, $failed failed"
[ "$passed" -gt 0 ] && [ "$failed" -eq 0 ]
