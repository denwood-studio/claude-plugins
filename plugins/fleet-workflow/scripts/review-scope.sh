#!/usr/bin/env bash
set -uo pipefail

WT="${1:-}"; PR="${2:-}"; REPO="${3:-}"
if [ -z "$WT" ] || [ -z "$PR" ] || [ -z "$REPO" ]; then
  echo "usage: review-scope.sh <worktree> <pr-number> <owner>/<repo>" >&2
  exit 2
fi
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "review-scope: $WT is not a git worktree" >&2
  exit 2
}

HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
echo "HEAD: $HEAD_SHA"

BASE=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq .baseRefName 2>/dev/null) || BASE=""
BASE="${BASE:-main}"

emit_full() {
  echo "SCOPE: full"
  echo "REASON: $1"
  echo "RANGE: origin/${BASE}...HEAD"
}

LOGIN=$("$(dirname "${BASH_SOURCE[0]}")/settings.sh" "$WT" review.botLogin 2>/dev/null) || LOGIN=""
if [ -z "$LOGIN" ]; then
  emit_full "no-bot-login"
  exit 0
fi

if ! PRIOR_RAW=$(gh pr view "$PR" --repo "$REPO" --json reviews 2>/dev/null \
    | jq -r --arg login "$LOGIN" \
        '[.reviews[] | select(.author.login == $login)] | last
         | select((.body // "") != "") | "\(.submittedAt // "")\n\(.body)"' 2>/dev/null); then
  # A transient gh failure must never read as a first pass.
  emit_full "lookup-failed"
  exit 0
fi

PRIOR_AT="${PRIOR_RAW%%$'\n'*}"
PRIOR_BODY="${PRIOR_RAW#*$'\n'}"

if [ -z "$PRIOR_BODY" ]; then
  emit_full "first-pass"
  exit 0
fi

PRIOR_SHA=$(printf '%s\n' "$PRIOR_BODY" \
  | grep -oE '<!-- DAR-STATE sha=[0-9a-f]{7,40} -->' | tail -1 \
  | grep -oE 'sha=[0-9a-f]{7,40}' | cut -d= -f2)
if [ -z "$PRIOR_SHA" ]; then
  PRIOR_SHA=$(printf '%s\n' "$PRIOR_BODY" | head -10 \
    | grep -m1 '^\*\*Reviewed at:\*\*' | grep -oE '[0-9a-f]{7,40}')
fi

if [ -z "$PRIOR_SHA" ]; then
  emit_full "no-anchor"
elif ! git -C "$WT" rev-parse --verify --quiet "${PRIOR_SHA}^{commit}" >/dev/null; then
  emit_full "anchor-not-found"
elif [ "$(git -C "$WT" rev-parse "${PRIOR_SHA}^{commit}")" = "$HEAD_SHA" ]; then
  echo "SCOPE: unchanged"
  echo "REASON: HEAD is the reviewed SHA"
elif ! git -C "$WT" merge-base --is-ancestor "$PRIOR_SHA" HEAD; then
  # <prior>..HEAD after a rebase re-absorbs everything that came in from the base: a 1-file change reported as 4 files.
  emit_full "rebase"
else
  echo "SCOPE: delta"
  echo "REASON: anchored at $PRIOR_SHA"
  echo "RANGE: ${PRIOR_SHA}..HEAD"
fi

[ -n "$PRIOR_AT" ] && echo "PRIOR_REVIEWED_AT: $PRIOR_AT"
echo "PRIOR_REVIEW:"
printf '%s\n' "$PRIOR_BODY"
