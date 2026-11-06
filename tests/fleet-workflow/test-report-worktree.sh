#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/plugins/fleet-workflow/scripts/report-worktree.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
[ -z "${CURL_NOISY:-}" ] || { echo "curl-stdout"; echo "curl-stderr" >&2; }
exit "${CURL_EXIT:-0}"
SH
chmod +x "$tmp/bin/curl"
log="$tmp/curl.log"

report() {
  env -u ORCH_HOOK_PORT -u ORCH_HOOK_TOKEN -u ORCH_SESSION_ID \
    PATH="$tmp/bin:$PATH" CURL_LOG="$log" "$@"
}

assert_eq() {
  [ "$2" = "$3" ] || { echo "FAIL [$1]: got '$2' want '$3'"; exit 1; }
  echo "PASS [$1]"
}

rc=0
report "$SCRIPT" /abs/wt || rc=$?
assert_eq "unset-port-exits-zero" "$rc" "0"
assert_eq "unset-port-calls-no-curl" "$([ -e "$log" ] && echo called || echo silent)" "silent"

rc=0
report ORCH_HOOK_PORT=1234 CURL_EXIT=7 "$SCRIPT" /abs/wt || rc=$?
assert_eq "unreachable-endpoint-still-exits-zero" "$rc" "0"

out="$(report ORCH_HOOK_PORT=1234 CURL_NOISY=1 "$SCRIPT" /abs/wt 2>&1)"
assert_eq "prints-nothing-even-when-curl-does" "$out" ""

: > "$log"
report ORCH_HOOK_PORT=1234 ORCH_HOOK_TOKEN=tok ORCH_SESSION_ID=sess "$SCRIPT" "/abs/my wt"
assert_eq "exactly-one-call" "$(wc -l < "$log" | tr -d ' ')" "1"
assert_eq "request-is-a-get-to-worktree-with-token-session-and-path" "$(cat "$log")" \
  "-s -m 1 -G http://127.0.0.1:1234/worktree -H x-orch-token: tok --data-urlencode session=sess --data-urlencode path=/abs/my wt"

echo "All report-worktree tests passed."
