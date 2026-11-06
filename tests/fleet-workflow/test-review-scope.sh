#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REVIEW_SCOPE_SH:-$REPO_ROOT/plugins/fleet-workflow/scripts/review-scope.sh}"
[ -r "$SCRIPT" ] || { echo "FAIL: $SCRIPT not readable"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The stub answers the base lookup, and for the reviews lookup emits a payload
# that the script's own jq filter runs over, so the login filter is exercised
# rather than assumed. Every call is logged to $GH_STUB_LOG.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:-/dev/null}"
[ "${GH_STUB_FAIL:-0}" = 1 ] && exit 1
case "$*" in
  *baseRefName*) printf '%s' "${GH_STUB_BASE:-main}"; exit 0 ;;
esac
if [ -n "${GH_STUB_BODY:-}" ]; then
  BODY="$GH_STUB_BODY" \
    AT="${GH_STUB_AT-2026-09-04T07:33:52Z}" \
    LOGIN="${GH_STUB_LOGIN:-review-bot}" \
    jq -n '{reviews:[{author:{login:env.LOGIN},submittedAt:(if env.AT == "" then null else env.AT end),body:env.BODY}]}'
else
  echo '{"reviews":[]}'
fi
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

export CLAUDE_CONFIG_DIR="$tmp/cfg"
mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{"review":{"botLogin":"review-bot"}}' > "$CLAUDE_CONFIG_DIR/fleet-workflow.json"

export GH_STUB_LOG="$tmp/gh.log"

# Repo: main A -> B -> C (HEAD), plus S on a side branch (never an ancestor of C).
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
commit() { echo "$1" > "$repo/f.txt"; git -C "$repo" add f.txt; git -C "$repo" commit -q -m "$1"; git -C "$repo" rev-parse HEAD; }
A=$(commit a)
B=$(commit b)
C=$(commit c)
git -C "$repo" checkout -q -b side "$A"
S=$(commit s)
git -C "$repo" checkout -q main

run() { : > "$GH_STUB_LOG"; GH_STUB_BODY="${1:-}" GH_STUB_FAIL="${2:-0}" bash "$SCRIPT" "$repo" 42 owner/repo; }

assert_contains() {
  local label="$1" out="$2" want="$3"
  if printf '%s' "$out" | grep -qF -- "$want"; then
    echo "PASS [$label]: found '$want'"
  else
    echo "FAIL [$label]: expected '$want' in:"; printf '%s\n' "$out"; exit 1
  fi
}

assert_absent() {
  local label="$1" out="$2" unwant="$3"
  if printf '%s' "$out" | grep -qF -- "$unwant"; then
    echo "FAIL [$label]: did not expect '$unwant' in:"; printf '%s\n' "$out"; exit 1
  else
    echo "PASS [$label]: no '$unwant'"
  fi
}

out=$(run "")
assert_contains "first-pass scope" "$out" "SCOPE: full"
assert_contains "first-pass reason" "$out" "REASON: first-pass"
assert_contains "first-pass range" "$out" "RANGE: origin/main...HEAD"
assert_absent "first-pass no body" "$out" "PRIOR_REVIEW:"

out=$(run "" 1)
assert_contains "lookup-failed scope" "$out" "SCOPE: full"
assert_contains "lookup-failed reason" "$out" "REASON: lookup-failed"
assert_contains "lookup-failed base" "$out" "RANGE: origin/main...HEAD"

out=$(GH_STUB_BASE=develop run "")
assert_contains "non-main base" "$out" "RANGE: origin/develop...HEAD"

out=$(run "**Verdict:** APPROVE

Some findings.")
assert_contains "no-anchor reason" "$out" "REASON: no-anchor"
assert_contains "no-anchor body" "$out" "Some findings."

out=$(run "**Verdict:** REQUEST CHANGES

Findings here.

<!-- DAR-STATE sha=$B -->")
assert_contains "trailer scope" "$out" "SCOPE: delta"
assert_contains "trailer range" "$out" "RANGE: $B..HEAD"

out=$(run "🤖 **Automated review**

**Verdict:** REQUEST CHANGES
**Reviewed at:** \`$(git -C "$repo" rev-parse --short "$B")\`

Findings here.")
assert_contains "header scope" "$out" "SCOPE: delta"
assert_contains "header range" "$out" "RANGE: $(git -C "$repo" rev-parse --short "$B")..HEAD"

out=$(run "**Verdict:** APPROVE
2
3
4
5
6
7
8
9
10
**Reviewed at:** \`$B\`")
assert_contains "quoted-header reason" "$out" "REASON: no-anchor"

out=$(run "Earlier pass said <!-- DAR-STATE sha=$A --> which is quoted prose.

<!-- DAR-STATE sha=$B -->")
assert_contains "last-trailer-wins" "$out" "RANGE: $B..HEAD"

out=$(run "<!-- DAR-STATE sha=$C -->")
assert_contains "unchanged scope" "$out" "SCOPE: unchanged"
assert_absent "unchanged no range" "$out" "RANGE:"

out=$(run "<!-- DAR-STATE sha=$S -->")
assert_contains "rebase scope" "$out" "SCOPE: full"
assert_contains "rebase reason" "$out" "REASON: rebase"
assert_contains "rebase body carried" "$out" "PRIOR_REVIEW:"

out=$(run "<!-- DAR-STATE sha=0123abc456789def0123abc456789def01234567 -->")
assert_contains "anchor-not-found reason" "$out" "REASON: anchor-not-found"

# The value is unique in this file, so a pass cannot come from the stub's default.
out=$(GH_STUB_AT=2031-02-03T04:05:06Z run "<!-- DAR-STATE sha=$B -->")
assert_contains "prior timestamp" "$out" "PRIOR_REVIEWED_AT: 2031-02-03T04:05:06Z"

out=$(GH_STUB_AT= run "<!-- DAR-STATE sha=$B -->")
assert_contains "null-timestamp scope" "$out" "SCOPE: delta"
assert_absent "null-timestamp no line" "$out" "PRIOR_REVIEWED_AT"

out=$(run "")
assert_absent "first-pass no timestamp" "$out" "PRIOR_REVIEWED_AT"

out=$(GH_STUB_LOGIN=someone-else run "<!-- DAR-STATE sha=$B -->")
assert_contains "foreign-login reason" "$out" "REASON: first-pass"
assert_absent "foreign-login no timestamp" "$out" "PRIOR_REVIEWED_AT"
assert_absent "foreign-login no body" "$out" "PRIOR_REVIEW:"

# Anchored delta from the configured login, while a later review by another login is ignored.
out=$(GH_STUB_LOGIN=review-bot run "<!-- DAR-STATE sha=$A -->")
assert_contains "configured-login anchors the delta" "$out" "RANGE: $A..HEAD"
assert_contains "configured-login reason" "$out" "REASON: anchored at $A"

echo '{"review":{"botLogin":"other-bot"}}' > "$CLAUDE_CONFIG_DIR/fleet-workflow.json"
out=$(GH_STUB_LOGIN=review-bot run "<!-- DAR-STATE sha=$B -->")
assert_contains "login-change-ignores-the-old-bot" "$out" "REASON: first-pass"
out=$(GH_STUB_LOGIN=other-bot run "<!-- DAR-STATE sha=$B -->")
assert_contains "login-change-follows-the-new-bot" "$out" "RANGE: $B..HEAD"

# No login: a full pass, and the reviews lookup is never made.
rm "$CLAUDE_CONFIG_DIR/fleet-workflow.json"
out=$(run "<!-- DAR-STATE sha=$B -->")
assert_contains "no-login scope" "$out" "SCOPE: full"
assert_contains "no-login reason" "$out" "REASON: no-bot-login"
assert_contains "no-login range" "$out" "RANGE: origin/main...HEAD"
assert_absent "no-login no prior review" "$out" "PRIOR_REVIEW:"
assert_absent "no-login no timestamp" "$out" "PRIOR_REVIEWED_AT"
assert_absent "no-login makes no reviews call" "$(cat "$GH_STUB_LOG")" "reviews"
assert_contains "no-login still resolves the base" "$(cat "$GH_STUB_LOG")" "baseRefName"

out=$(GH_STUB_BASE=develop run "")
assert_contains "no-login keeps the PR base" "$out" "RANGE: origin/develop...HEAD"

echo '{"review":{"botLogin":""}}' > "$CLAUDE_CONFIG_DIR/fleet-workflow.json"
out=$(run "")
assert_contains "empty-login reason" "$out" "REASON: no-bot-login"

# A login committed in the repo layer is ignored, so it cannot opt a repo into a lookup.
rm "$CLAUDE_CONFIG_DIR/fleet-workflow.json"
mkdir -p "$repo/.claude"
echo '{"review":{"botLogin":"review-bot"}}' > "$repo/.claude/fleet-workflow.json"
out=$(run "<!-- DAR-STATE sha=$B -->")
assert_contains "repo-layer-login-reason" "$out" "REASON: no-bot-login"
rm -r "$repo/.claude"

if bash "$SCRIPT" 2>/dev/null; then echo "FAIL [usage]: expected exit 2"; exit 1; else echo "PASS [usage]: non-zero on missing args"; fi
if bash "$SCRIPT" "$tmp" 42 owner/repo 2>/dev/null; then echo "FAIL [not-a-repo]: expected exit 2"; exit 1; else echo "PASS [not-a-repo]: non-zero outside a repo"; fi

echo "All review-scope tests passed."
