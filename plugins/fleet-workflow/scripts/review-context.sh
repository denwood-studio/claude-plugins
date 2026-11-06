#!/usr/bin/env bash
set -uo pipefail

WT="${1:-}"; RANGE="${2:-}"
if [ -z "$WT" ] || [ -z "$RANGE" ]; then
  echo "usage: review-context.sh <worktree> <range>" >&2
  exit 2
fi
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "review-context: $WT is not a git worktree" >&2
  exit 2
}

emit() {
  local key="$1" body="$2"
  if [ -z "$body" ]; then
    echo "${key}: none"
  else
    echo "${key}:"
    printf '%s\n' "$body"
  fi
}

emit "FILES" "$(git -C "$WT" diff --name-status "$RANGE" 2>/dev/null)"
emit "STAT" "$(git -C "$WT" diff --stat "$RANGE" 2>/dev/null | tail -1)"

PATHS=$(git -C "$WT" diff --name-only "$RANGE" 2>/dev/null)
TERMS=""
if [ -n "$PATHS" ]; then
  # Memory-store paths yield `decisions`/`memory`, which match most of decisions.md and crowd the caps.
  TERMS=$(printf '%s\n' "$PATHS" | awk -F/ '
    {
      if ($0 ~ /^\.claude\/memory\//) next
      base = $NF
      sub(/\.[^.]*$/, "", base)
      if (base != "") print base
      if (NF >= 3 && $2 != "") print $2
    }' | sort -u)
fi
emit "TERMS" "$TERMS"

MEM="$WT/.claude/memory"
SIZES=""
if [ -d "$MEM" ]; then
  for f in "$MEM"/*.md; do
    [ -f "$f" ] || continue
    SIZES="${SIZES}$(wc -c < "$f" | tr -d ' ') $(basename "$f")"$'\n'
  done
fi
emit "MEMORY-SIZES" "${SIZES%$'\n'}"

# An empty term list must never reach grep: `grep -E ""` matches every line and dumps the whole store.
PATTERN=""
if [ -n "$TERMS" ]; then
  PATTERN=$(printf '%s\n' "$TERMS" \
    | sed 's/[][\.^$*+?(){}|]/\\&/g' \
    | paste -sd '|' -)
fi

emit_hits() {
  local key="$1" file="$2" cap="$3"
  if [ -z "$PATTERN" ] || [ ! -f "$file" ]; then
    echo "${key}: none"
    return
  fi
  emit "$key" "$(grep -n -i -E "$PATTERN" "$file" 2>/dev/null | head -n "$cap")"
}

emit_hits "DECISIONS" "$MEM/decisions.md" 60
emit_hits "PATTERNS" "$MEM/patterns.md" 40
emit_hits "CONVENTIONS" "$MEM/conventions.md" 40
emit_hits "CONTEXT" "$MEM/context.md" 40
