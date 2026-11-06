#!/usr/bin/env bash
set -u

usage() { echo "usage: settings.sh <dir> [<dot.key>]" >&2; exit 2; }
[ $# -eq 1 ] || [ $# -eq 2 ] || usage
command -v jq >/dev/null 2>&1 || { echo "settings.sh: jq is required" >&2; exit 2; }

root="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || { echo "settings.sh: $1 is not inside a git repository" >&2; exit 2; }
defaults="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/defaults.json"
layers=("$defaults" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/fleet-workflow.json" "$root/.claude/fleet-workflow.json")

present=()
for f in "${layers[@]}"; do
  [ -e "$f" ] || continue
  jq -s -e 'length == 1 and (.[0] | type == "object")' "$f" >/dev/null 2>&1 || { echo "settings.sh: $f is not a valid JSON object" >&2; exit 1; }
  present+=("$f")
done

merged="$(jq -s 'reduce .[] as $l ({}; . * $l)' "${present[@]}")" || exit 1

if [ $# -eq 1 ]; then
  printf '%s\n' "$merged"
  exit 0
fi

[ -n "$2" ] || { echo "settings.sh: unknown key" >&2; exit 2; }
printf '%s\n' "$merged" | jq -r --arg k "$2" '(try getpath($k | split(".")) catch null) | if . == null then error("unknown key") else . end' 2>/dev/null || { echo "settings.sh: unknown key $2" >&2; exit 2; }
