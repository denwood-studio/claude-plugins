#!/usr/bin/env bash
set -uo pipefail

result() { echo "DAR_RESULT: $1"; exit 0; }

[ $# -eq 5 ] || result "failed (usage)"
WT="$1"; PR="$2"; REPO="$3"; EVENT="$4"; BODY="$5"
case "$EVENT" in --approve|--request-changes) ;; *) result "failed (usage)" ;; esac

setting() { "$(dirname "${BASH_SOURCE[0]}")/settings.sh" "$WT" "$1" 2>/dev/null; }

[ "$(setting review.postToGitHub)" = "true" ] || result "skipped (postToGitHub false)"

[ -n "$(setting review.botLogin)" ] || result "skipped (no bot login)"

TOKEN_FILE="$(setting review.tokenFile)"
case "$TOKEN_FILE" in
  "~") TOKEN_FILE="$HOME" ;;
  "~/"*) TOKEN_FILE="$HOME/${TOKEN_FILE#"~/"}" ;;
esac
[ -n "$TOKEN_FILE" ] && [ -f "$TOKEN_FILE" ] || result "skipped (no token)"
TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
[ -n "$TOKEN" ] || result "skipped (no token)"

[ -s "$BODY" ] || result "skipped (empty review body)"

if GH_TOKEN="$TOKEN" gh pr review "$PR" --repo "$REPO" "$EVENT" --body-file "$BODY" >/dev/null 2>&1; then
  result "posted ($EVENT)"
fi
result "failed (gh pr review error)"
