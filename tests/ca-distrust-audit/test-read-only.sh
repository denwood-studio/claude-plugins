#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="${CA_AUDIT_PLUGIN_DIR:-$REPO/plugins/ca-distrust-audit}"
SCRIPT="$PLUGIN/scripts/audit.sh"
FIXTURES="$REPO/tests/ca-distrust-audit/fixtures"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail=0
pass() { echo "PASS [$1]"; }
bad() { echo "FAIL [$1]: $2"; fail=1; }

PROFILE='(version 1)(allow default)(deny file-write*)(allow file-write-data (literal "/dev/null"))'

manifest() {
  if [ "$(uname -s)" = Darwin ]; then
    find "$1" -exec stat -f '%N %p %z %m %c' {} + | sort
  else
    find "$1" -exec stat -c '%n %a %s %Y %Z' {} + | sort
  fi
  find "$1" -type f -exec cksum {} + | sort
}

if grep -nE '<<|mktemp|(^|[^A-Za-z0-9_.-])(tee|curl|wget|npm|npx|brew|git|pip|pip3|gem|yarn|pnpm|nvm|mise|asdf|volta)[ \t]' "$SCRIPT" > "$tmp/static.out"; then
  bad "script-has-no-heredoc-temp-file-network-or-package-manager-command" "$(cat "$tmp/static.out")"
else
  pass "script-has-no-heredoc-temp-file-network-or-package-manager-command"
fi
if [ "$(stat -f '%Lp' "$SCRIPT" 2> /dev/null || stat -c '%a' "$SCRIPT")" = 755 ] || [ -x "$SCRIPT" ]; then pass "script-is-executable"; else bad "script-is-executable" "not executable"; fi

repo="$tmp/repo"
mkdir -p "$repo/certs" "$repo/node_modules/dep" "$repo/svc"
printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$repo/Dockerfile"
printf 'FROM debian:12\nRUN apt-get install -y ca-certificates\n' > "$repo/svc/Dockerfile.dev"
printf 'FROM scratch\n' > "$repo/svc/Containerfile"
cp "$FIXTURES/aaa-certificate-services.pem" "$repo/certs/bundle.pem"
cp "$FIXTURES/aaa-certificate-services.pem" "$repo/node_modules/dep/cacert.pem"
: > "$repo/certs/trust.jks"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m "fixture"
printf 'untracked\n' > "$repo/untracked.txt"
printf 'FROM debian:12\n# edited\n' >> "$repo/Dockerfile"

status_before="$(git -C "$repo" status --porcelain)"
head_before="$(git -C "$repo" rev-parse HEAD)"
before="$(manifest "$repo")"
plain="$("$SCRIPT" repo "$repo" 2> "$tmp/plain.err")"
after="$(manifest "$repo")"
status_after="$(git -C "$repo" status --porcelain)"
head_after="$(git -C "$repo" rev-parse HEAD)"

[ "$before" = "$after" ] && pass "repo-file-stat-manifest-is-unchanged" || bad "repo-file-stat-manifest-is-unchanged" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
[ "$status_before" = "$status_after" ] && pass "git-status-is-unchanged" || bad "git-status-is-unchanged" "status changed"
[ "$head_before" = "$head_after" ] && pass "git-head-is-unchanged" || bad "git-head-is-unchanged" "head changed"
[ ! -s "$tmp/plain.err" ] && pass "repo-run-prints-nothing-on-stderr" || bad "repo-run-prints-nothing-on-stderr" "$(cat "$tmp/plain.err")"
printf '%s\n' "$plain" | grep -q '^FLAG certs/bundle.pem' && pass "fixture-repo-produces-findings" || bad "fixture-repo-produces-findings" "no bundle finding"

mkdir -p "$tmp/home" "$tmp/nodes" "$tmp/apps/Sample.app/Contents/Frameworks/Electron Framework.framework/Resources"
printf '#!/bin/sh\necho v24.9.0\n' > "$tmp/nodes/node"
chmod +x "$tmp/nodes/node"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleVersion</key><string>39.8.3</string></dict></plist>\n' \
  > "$tmp/apps/Sample.app/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"

machine() {
  env HOME="$tmp/home" CA_AUDIT_NODE_DIRS="$tmp/nodes" CA_AUDIT_APP_DIRS="$tmp/apps" CA_AUDIT_MACOS_VERSION=26.4.1 "$@"
}

if [ "$(uname -s)" != Darwin ] || ! command -v sandbox-exec > /dev/null 2>&1; then
  echo "PASS [sandboxed-runs-skipped] skipped: needs macOS sandbox-exec"
  exit "$fail"
fi

if sandbox-exec -p "$PROFILE" sh -c "echo x > '$tmp/probe'" 2> /dev/null; then
  bad "sandbox-profile-denies-writes" "the probe write succeeded"
else
  pass "sandbox-profile-denies-writes"
fi
[ ! -e "$tmp/probe" ] || bad "sandbox-profile-denies-writes" "probe file exists"

sandboxed="$(sandbox-exec -p "$PROFILE" "$SCRIPT" repo "$repo" 2> "$tmp/sandbox-repo.err")"
[ "$sandboxed" = "$plain" ] && pass "sandboxed-repo-stdout-is-identical" || bad "sandboxed-repo-stdout-is-identical" "outputs differ"
[ ! -s "$tmp/sandbox-repo.err" ] && pass "sandboxed-repo-stderr-is-empty" || bad "sandboxed-repo-stderr-is-empty" "$(cat "$tmp/sandbox-repo.err")"

plain_machine="$(machine "$SCRIPT" machine 2> "$tmp/plain-machine.err")"
sandboxed_machine="$(machine sandbox-exec -p "$PROFILE" "$SCRIPT" machine 2> "$tmp/sandbox-machine.err")"
[ "$sandboxed_machine" = "$plain_machine" ] && pass "sandboxed-machine-stdout-is-identical" || bad "sandboxed-machine-stdout-is-identical" "outputs differ"
[ ! -s "$tmp/sandbox-machine.err" ] && pass "sandboxed-machine-stderr-is-empty" || bad "sandboxed-machine-stderr-is-empty" "$(cat "$tmp/sandbox-machine.err")"
printf '%s\n' "$plain_machine" | grep -q "^FLAG $tmp/nodes/node: " && pass "fixture-machine-produces-findings" || bad "fixture-machine-produces-findings" "no node finding"

[ "$(manifest "$repo")" = "$before" ] && pass "repo-is-unchanged-after-sandboxed-runs" || bad "repo-is-unchanged-after-sandboxed-runs" "manifest changed"

exit "$fail"
