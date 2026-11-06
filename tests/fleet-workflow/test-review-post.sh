#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REVIEW_POST_SH:-$REPO_ROOT/plugins/fleet-workflow/scripts/review-post.sh}"
[ -r "$SCRIPT" ] || { echo "FAIL: $SCRIPT not readable"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

SECRET="tok-9f3a1c7e-do-not-leak"

# The stub logs its argv and whether GH_TOKEN reached its environment, never the token itself.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
{
  echo "argv: $*"
  if [ -z "${GH_TOKEN+x}" ]; then echo "GH_TOKEN: unset"
  elif [ "$GH_TOKEN" = "$GH_STUB_EXPECT" ]; then echo "GH_TOKEN: set and matches the token file"
  else echo "GH_TOKEN: set but wrong"; fi
} >> "$GH_STUB_LOG"
echo "Approved pull request"
[ "${GH_STUB_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export GH_STUB_LOG="$tmp/gh.log"
export GH_STUB_EXPECT="$SECRET"

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "PASS [$1]"; else echo "FAIL [$1]: got '$2' want '$3'"; fail=1; fi
}
absent() {
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL [$1]: found '$3' in: $2"; fail=1; else echo "PASS [$1]"; fi
}

n=0
setup() {
  n=$((n + 1))
  CFG="$tmp/cfg$n"
  R="$tmp/repo$n"
  mkdir -p "$CFG" "$R/.claude"
  git -C "$R" init -q
  TOKEN="$tmp/token$n"
  printf '%s\n' "$SECRET" > "$TOKEN"
  BODYF="$tmp/body$n"
  printf 'the review\n' > "$BODYF"
  : > "$GH_STUB_LOG"
}
user() { printf '%s\n' "$1" > "$CFG/fleet-workflow.json"; }
repo() { printf '%s\n' "$1" > "$R/.claude/fleet-workflow.json"; }
post() { CLAUDE_CONFIG_DIR="$CFG" bash "$SCRIPT" "$R" 7 owner/repo "${1:---approve}" "${2:-$BODYF}"; }
calls() { grep -c '^argv:' "$GH_STUB_LOG"; }

configured() { user "{\"review\":{\"postToGitHub\":true,\"botLogin\":\"review-bot\",\"tokenFile\":\"$TOKEN\"}}"; }

expect_skip() {
  local name="$1" want="$2" out rc
  out="$(post)"; rc=$?
  check "$name-prints-exactly-the-line" "$out" "DAR_RESULT: $want"
  check "$name-exits-0" "$rc" "0"
  check "$name-makes-no-gh-call" "$(calls)" "0"
}

setup
expect_skip "defaults-skip-post-to-github-false" "skipped (postToGitHub false)"

setup; user '{"review":{"postToGitHub":false,"botLogin":"review-bot","tokenFile":"'"$TOKEN"'"}}'
expect_skip "explicit-false" "skipped (postToGitHub false)"

setup; user '{"review":{"postToGitHub":true}}'
expect_skip "no-bot-login" "skipped (no bot login)"

setup; user '{"review":{"postToGitHub":true,"botLogin":"review-bot"}}'
expect_skip "empty-token-file-setting" "skipped (no token)"

setup; user '{"review":{"postToGitHub":true,"botLogin":"review-bot","tokenFile":"'"$tmp"'/missing"}}'
expect_skip "missing-token-file" "skipped (no token)"

setup; : > "$TOKEN"; configured
expect_skip "empty-token-file-content" "skipped (no token)"

setup; configured; : > "$BODYF"
expect_skip "empty-body-file" "skipped (empty review body)"

setup; configured
out="$(post --approve "$tmp/no-such-body")"
check "missing-body-file" "$out" "DAR_RESULT: skipped (empty review body)"
check "missing-body-file-no-gh-call" "$(calls)" "0"

setup; configured
out="$(post --approve)"; rc=$?
check "approve-prints-posted" "$out" "DAR_RESULT: posted (--approve)"
check "approve-exits-0" "$rc" "0"
check "approve-makes-one-gh-call" "$(calls)" "1"
check "approve-argv" "$(grep '^argv:' "$GH_STUB_LOG")" "argv: pr review 7 --repo owner/repo --approve --body-file $BODYF"
check "approve-sets-gh-token-in-the-environment" "$(grep '^GH_TOKEN:' "$GH_STUB_LOG")" "GH_TOKEN: set and matches the token file"
absent "approve-token-not-in-the-argv-log" "$(cat "$GH_STUB_LOG")" "$SECRET"
absent "approve-token-not-on-stdout" "$out" "$SECRET"

setup; configured
out="$(post --request-changes)"
check "request-changes-prints-posted" "$out" "DAR_RESULT: posted (--request-changes)"
check "request-changes-argv" "$(grep '^argv:' "$GH_STUB_LOG")" "argv: pr review 7 --repo owner/repo --request-changes --body-file $BODYF"

setup; configured
out="$(GH_STUB_FAIL=1 post --approve 2>&1)"; rc=$?
check "gh-failure-prints-failed" "$out" "DAR_RESULT: failed (gh pr review error)"
check "gh-failure-exits-0" "$rc" "0"
absent "gh-failure-token-not-on-stdout" "$out" "$SECRET"

setup
mkdir -p "$tmp/home$n"; cp "$TOKEN" "$tmp/home$n/bot-token"
user '{"review":{"postToGitHub":true,"botLogin":"review-bot","tokenFile":"~/bot-token"}}'
out="$(HOME="$tmp/home$n" post --approve)"
check "leading-tilde-expands-to-home" "$out" "DAR_RESULT: posted (--approve)"
check "leading-tilde-token-reaches-gh" "$(grep '^GH_TOKEN:' "$GH_STUB_LOG")" "GH_TOKEN: set and matches the token file"

setup; configured
repo '{"review":{"postToGitHub":false}}'
expect_skip "repo-layer-can-turn-posting-off" "skipped (postToGitHub false)"

setup; user '{"review":{"postToGitHub":true,"botLogin":"review-bot"}}'
repo '{"review":{"tokenFile":"'"$TOKEN"'"}}'
expect_skip "token-file-only-in-the-repo-layer" "skipped (no token)"

setup; user '{"review":{"postToGitHub":true}}'
repo '{"review":{"botLogin":"review-bot","tokenFile":"'"$TOKEN"'"}}'
expect_skip "login-and-token-file-only-in-the-repo-layer" "skipped (no bot login)"

setup; configured
other="$tmp/other-token$n"; printf 'a-different-token\n' > "$other"
repo '{"review":{"tokenFile":"'"$other"'"}}'
out="$(post --approve)"
check "repo-layer-cannot-swap-the-token-file" "$(grep '^GH_TOKEN:' "$GH_STUB_LOG")" "GH_TOKEN: set and matches the token file"

setup; configured
out="$(CLAUDE_CONFIG_DIR="$CFG" bash "$SCRIPT" "$R" 7 owner/repo --comment "$BODYF")"; rc=$?
check "unknown-event-prints-failed-usage" "$out" "DAR_RESULT: failed (usage)"
check "unknown-event-exits-0" "$rc" "0"
check "unknown-event-makes-no-gh-call" "$(calls)" "0"

out="$(bash "$SCRIPT")"; rc=$?
check "no-args-prints-failed-usage" "$out" "DAR_RESULT: failed (usage)"
check "no-args-exits-0" "$rc" "0"

setup; configured
out="$(post --approve "$BODYF")"
check "output-is-one-line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"

exit "$fail"
