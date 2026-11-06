#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="${SETTINGS_SH:-$REPO/plugins/fleet-workflow/scripts/settings.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "PASS [$1]"; else echo "FAIL [$1]: got '$2' want '$3'"; fail=1; fi
}

n=0
newrepo() {
  n=$((n + 1))
  CFG="$tmp/cfg$n"
  R="$tmp/repo$n"
  mkdir -p "$CFG" "$R/.claude"
  git -C "$R" init -q
}
get() { CLAUDE_CONFIG_DIR="$CFG" bash "$SETTINGS" "$@"; }
all5() {
  echo "$(get "$1" tracker.team)|$(get "$1" tracker.project)|$(get "$1" check.command)|$(get "$1" worktree.setup)|$(get "$1" review.postToGitHub)"
}

newrepo
check "no-files-gives-all-five-defaults" "$(all5 "$R")" "|||scripts/worktree_setup.sh|false"

newrepo
echo '{"tracker":{"team":"T","project":"P"},"check":{"command":"make test"},"worktree":{"setup":"bin/setup"},"review":{"postToGitHub":true}}' > "$R/.claude/fleet-workflow.json"
check "repo-file-setting-all-five-gives-its-values" "$(all5 "$R")" "T|P|make test|bin/setup|true"

newrepo
echo '{"tracker":{"team":"UT","project":"UP"},"check":{"command":"u check"},"worktree":{"setup":"u/setup"},"review":{"postToGitHub":true}}' > "$CFG/fleet-workflow.json"
check "user-layer-only-gives-the-user-values" "$(all5 "$R")" "UT|UP|u check|u/setup|true"

newrepo
echo '{"tracker":{"team":"UT"},"check":{"command":"user cmd"}}' > "$CFG/fleet-workflow.json"
echo '{"check":{"command":"repo cmd"}}' > "$R/.claude/fleet-workflow.json"
check "repo-wins-over-user" "$(get "$R" check.command)" "repo cmd"
check "user-value-the-repo-leaves-alone-survives" "$(get "$R" tracker.team)" "UT"

newrepo
echo '{"tracker":{"team":"UT"}}' > "$CFG/fleet-workflow.json"
echo '{"tracker":{"project":"RP"}}' > "$R/.claude/fleet-workflow.json"
check "deep-merge-keeps-user-team-and-repo-project" "$(get "$R" tracker.team)|$(get "$R" tracker.project)" "UT|RP"

newrepo
echo '{"check":{"command":"root cmd"}}' > "$R/.claude/fleet-workflow.json"
mkdir -p "$R/sub/dir"
check "subdirectory-arg-reads-the-repo-file" "$(get "$R/sub/dir" check.command)" "root cmd"

newrepo
git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$R" worktree add -q -b wt "$tmp/linked$n"
echo '{"check":{"command":"main cmd"}}' > "$R/.claude/fleet-workflow.json"
mkdir -p "$tmp/linked$n/.claude"
echo '{"check":{"command":"linked cmd"}}' > "$tmp/linked$n/.claude/fleet-workflow.json"
check "linked-worktree-arg-reads-that-worktrees-file" "$(get "$tmp/linked$n" check.command)" "linked cmd"
check "main-checkout-still-reads-its-own-file" "$(get "$R" check.command)" "main cmd"

newrepo
echo '{"check":' > "$R/.claude/fleet-workflow.json"
err="$(get "$R" 2>&1 >/dev/null)"; rc=$?
check "invalid-repo-json-exits-1" "$rc" "1"
case "$err" in *"$R/.claude/fleet-workflow.json"*) check "invalid-repo-json-names-the-file" ok ok ;; *) check "invalid-repo-json-names-the-file" "$err" "message naming the file" ;; esac

newrepo
echo '[1,2]' > "$CFG/fleet-workflow.json"
err="$(get "$R" check.command 2>&1 >/dev/null)"; rc=$?
check "non-object-user-layer-exits-1" "$rc" "1"
case "$err" in *"$CFG/fleet-workflow.json"*) check "non-object-user-layer-names-the-file" ok ok ;; *) check "non-object-user-layer-names-the-file" "$err" "message naming the file" ;; esac

newrepo
get "$R" no.such.key >/dev/null 2>&1; check "unknown-key-exits-2" "$?" "2"

newrepo
get "$tmp" >/dev/null 2>&1; check "not-a-git-repo-exits-2" "$?" "2"
get >/dev/null 2>&1; check "no-args-exits-2" "$?" "2"

newrepo
printf '{"check":{"command":"$(touch %s/pwned)"}}\n' "$tmp" > "$R/.claude/fleet-workflow.json"
check "value-is-printed-not-executed" "$(get "$R" check.command)" "\$(touch $tmp/pwned)"
check "value-left-no-side-effect" "$([ -e "$tmp/pwned" ] && echo ran || echo clean)" "clean"

exit "$fail"
