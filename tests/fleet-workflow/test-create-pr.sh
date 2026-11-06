#!/usr/bin/env bash
# Smoke test for create-pr.sh. Builds a throwaway clone of a local bare repo and
# puts a `gh` shim first on PATH that logs its argv and prints a fake PR URL, so
# the cases the prose can't guard are pinned: the happy path, a dirty tree, an
# unresolvable base, a rebase conflict that leaves the tree clean, a re-run that
# reuses the open PR instead of opening a second one, a never-pushed branch whose
# @{upstream} is its base branch, a first push of a branch with no upstream at
# all, a foreign commit pushed to the branch behind the worktree's back, gh's
# update notice on stderr, a caller-supplied body with and without a base that makes
# the PR stacked, and the default title's ticket id.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../plugins/fleet-workflow/scripts" && pwd)/create-pr.sh"
[ -r "$SCRIPT" ] || { echo "FAIL: $SCRIPT not readable"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS [$1]: $2"; }
fail() { echo "FAIL [$1]: $2"; exit 1; }

mkdir -p "$tmp/bin"
export GH_LOG="$tmp/gh.log"
export GH_BODY="$tmp/gh.body"
: > "$GH_LOG"
: > "$GH_BODY"
cat > "$tmp/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
# Real gh prints this on stderr from a *successful* command, on the first run
# after any release. Every invocation emits it so no case can regress on it.
echo "A new release of gh is available: 2.40.0 -> 2.62.0" >&2
head=""
prev=""
body_file=""
for a in "$@"; do
  [ "$prev" = "--head" ] && head="$a"
  [ "$prev" = "--body-file" ] && body_file="$a"
  prev="$a"
done
case "${1:-} ${2:-}" in
  "pr list")
    if grep -q "^pr create .*--head $head " "$GH_LOG"; then
      printf 'https://github.com/acme/repo/pull/1\tmain\n'
    fi
    ;;
  "pr create")
    [ -n "$body_file" ] && cat "$body_file" > "$GH_BODY"
    echo "https://github.com/acme/repo/pull/1"
    ;;
esac
exit 0
SHIM
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

origin="$tmp/origin.git"
wt="$tmp/wt"
git init -q --bare -b main "$origin"
git clone -q "$origin" "$wt" 2>/dev/null
git -C "$wt" config user.email "test@example.com"
git -C "$wt" config user.name "Test"
# Pinned, not ambient: under push.default=current a bare `git push` lands on the
# branch's own name, which is what the tracks-base case exists to prove the script
# does by refspec — leaving it unset makes that assertion pass for the wrong reason.
git -C "$wt" config push.default upstream
echo "seed" > "$wt/README.md"
git -C "$wt" add README.md
git -C "$wt" commit -q -m "seed"
git -C "$wt" push -q -u origin main
git -C "$wt" switch -q -c abc-9999
echo "branch work" > "$wt/f.txt"
git -C "$wt" add f.txt
git -C "$wt" commit -q -m "add f"

# 1. Happy path: rebase, push, create, and report the URL and the base.
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "happy" "expected exit 0, got $code: $out"
printf '%s' "$out" | grep -qF "PR: https://github.com/acme/repo/pull/1" \
  || fail "happy" "no PR line in: $out"
printf '%s' "$out" | grep -qF "BASE: main" || fail "happy" "no BASE line in: $out"
grep -q '^pr create .*--assignee @me' "$GH_LOG" || fail "happy" "pr create missing --assignee @me"
grep -q 'Stacked on' "$GH_BODY" && fail "happy" "a main-based PR body carries the stacked note"
pass "happy" "opened the PR and printed PR:/BASE:"

# 2. A dirty tree stops before anything is pushed.
echo "uncommitted" >> "$wt/f.txt"
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "dirty" "expected exit 3, got $code: $out"
printf '%s' "$out" | grep -qF "ERROR: dirty worktree" \
  || fail "dirty" "exit 3 came from some other stop condition: $out"
git -C "$wt" checkout -q -- f.txt
pass "dirty" "exit 3 on an uncommitted change"

# 3. An unresolvable base is an error, never a fallback to main.
out=$(bash "$SCRIPT" "$wt" no-such-base 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "base" "expected exit 3, got $code: $out"
printf '%s' "$out" | grep -qF "base origin/no-such-base not found" \
  || fail "base" "unexpected message: $out"
pass "base" "exit 3 on a base that does not resolve"

# 4. A re-run reuses the open PR rather than opening a second one.
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "idempotent" "expected exit 0, got $code: $out"
printf '%s' "$out" | grep -qF "PR: https://github.com/acme/repo/pull/1" \
  || fail "idempotent" "no PR line in: $out"
creates=$(grep -c '^pr create' "$GH_LOG")
[ "$creates" -eq 1 ] || fail "idempotent" "expected 1 pr create, got $creates"
pass "idempotent" "second run reused the open PR"

# 5. A conflicting rebase aborts, errors, and leaves the tree clean.
git -C "$wt" switch -q main
echo "main work" > "$wt/f.txt"
git -C "$wt" add f.txt
git -C "$wt" commit -q -m "add f on main"
git -C "$wt" push -q origin main
git -C "$wt" switch -q abc-9999
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 4 ] || fail "conflict" "expected exit 4, got $code: $out"
printf '%s' "$out" | grep -qF "conflicts on: f.txt" \
  || fail "conflict" "exit 4 did not name the conflicted file: $out"
[ -z "$(git -C "$wt" status --porcelain)" ] || fail "conflict" "tree left dirty"
rebase_dir=$(git -C "$wt" rev-parse --git-path rebase-merge)
case "$rebase_dir" in
  /*) ;;
  *) rebase_dir="$wt/$rebase_dir" ;;
esac
[ ! -e "$rebase_dir" ] || fail "conflict" "rebase left in progress at $rebase_dir"
pass "conflict" "exit 4, tree clean, no rebase in progress"

# 6. A never-pushed branch tracking its base pushes to its own ref, not the base.
git -C "$wt" switch -q main
git -C "$wt" switch -q -c coord/base
git -C "$wt" push -q -u origin coord/base
git -C "$wt" fetch -q origin
git -C "$wt" checkout -q -b abc-8888 --track origin/coord/base
echo "node work" > "$wt/g.txt"
git -C "$wt" add g.txt
git -C "$wt" commit -q -m "add g"
upstream=$(git -C "$wt" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
[ "$upstream" = "origin/coord/base" ] \
  || fail "tracks-base" "precondition: upstream is '$upstream', not origin/coord/base"
git -C "$wt" rev-parse --verify --quiet refs/remotes/origin/abc-8888 >/dev/null 2>&1 \
  && fail "tracks-base" "precondition: origin/abc-8888 already exists"
base_before=$(git -C "$wt" ls-remote origin refs/heads/coord/base)
out=$(bash "$SCRIPT" "$wt" coord/base 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "tracks-base" "expected exit 0, got $code: $out"
printf '%s' "$out" | grep -qF "PR: https://github.com/acme/repo/pull/1" \
  || fail "tracks-base" "no PR line in: $out"
base_after=$(git -C "$wt" ls-remote origin refs/heads/coord/base)
[ "$base_before" = "$base_after" ] \
  || fail "tracks-base" "origin/coord/base moved: '$base_before' -> '$base_after'"
[ -n "$(git -C "$wt" ls-remote origin refs/heads/abc-8888)" ] \
  || fail "tracks-base" "abc-8888 was not pushed to origin"
grep -qF 'Stacked on `coord/base`' "$GH_BODY" \
  || fail "tracks-base" "no stacked note in the generated body: $(cat "$GH_BODY")"
pass "tracks-base" "first push landed on its own ref, left the base untouched, and the generated body carries the stacked note"

# 7. A branch with no upstream and no remote ref pushes to its own ref.
git -C "$wt" switch -q main
git -C "$wt" switch -q -c abc-7777
echo "fresh work" > "$wt/h.txt"
git -C "$wt" add h.txt
git -C "$wt" commit -q -m "add h"
git -C "$wt" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 \
  && fail "first-push" "precondition: abc-7777 already has an upstream"
git -C "$wt" rev-parse --verify --quiet refs/remotes/origin/abc-7777 >/dev/null 2>&1 \
  && fail "first-push" "precondition: origin/abc-7777 already exists"
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "first-push" "expected exit 0, got $code: $out"
[ -n "$(git -C "$wt" ls-remote origin refs/heads/abc-7777)" ] \
  || fail "first-push" "abc-7777 was not pushed to origin"
pass "first-push" "an untracked branch's first push landed on its own ref"

# 8. A commit pushed to the branch by another clone is never overwritten: the lease
# is qualified with the ref this worktree saw *before* its own fetch, so the fetch
# cannot satisfy it. An unqualified --force-with-lease destroys the commit here.
clone2="$tmp/clone2"
git clone -q "$origin" "$clone2" 2>/dev/null
git -C "$clone2" config user.email "other@example.com"
git -C "$clone2" config user.name "Other"
git -C "$clone2" checkout -q -B abc-7777 origin/abc-7777
echo "suggestion from the github ui" > "$clone2/i.txt"
git -C "$clone2" add i.txt
git -C "$clone2" commit -q -m "apply review suggestion"
git -C "$clone2" push -q origin HEAD:refs/heads/abc-7777
foreign=$(git -C "$clone2" rev-parse HEAD)
echo "more work" >> "$wt/h.txt"
git -C "$wt" add h.txt
git -C "$wt" commit -q -m "more h"
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 5 ] || fail "foreign-commit" "expected exit 5, got $code: $out"
printf '%s' "$out" | grep -qF "force-with-lease" \
  || fail "foreign-commit" "exit 5 came from some other failure than the lease: $out"
remote_tip=$(git -C "$wt" ls-remote origin refs/heads/abc-7777 | cut -f1)
[ "$remote_tip" = "$foreign" ] \
  || fail "foreign-commit" "origin/abc-7777 was overwritten: expected $foreign, got $remote_tip"
pass "foreign-commit" "the lease refused and the foreign commit survived"

# 9. gh's update notice on stderr never reaches the parsed PR URL. Folding stderr
# into the `pr list` capture makes the notice the URL and the base, which then
# retargets the PR to a nonsense ref and prints the notice as the result.
git -C "$wt" switch -q main
git -C "$wt" switch -q -c abc-6666
echo "notice work" > "$wt/j.txt"
git -C "$wt" add j.txt
git -C "$wt" commit -q -m "add j"
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "update-notice" "expected exit 0, got $code: $out"
printf '%s\n' "$out" | grep -qx "PR: https://github.com/acme/repo/pull/1" \
  || fail "update-notice" "the PR line is not the URL alone: $out"
grep -q '^pr edit' "$GH_LOG" && fail "update-notice" "retargeted a PR that did not exist"
pass "update-notice" "gh's stderr stayed out of the PR URL"

# 10. A caller-supplied body is passed through verbatim on a main-based PR.
git -C "$wt" switch -q main
git -C "$wt" switch -q -c abc-5555
echo "body work" > "$wt/k.txt"
git -C "$wt" add k.txt
git -C "$wt" commit -q -m "add k"
printf '## Summary\n- caller wrote this\n' > "$tmp/body.md"
out=$(bash "$SCRIPT" "$wt" main --body-file "$tmp/body.md" 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "body-file" "expected exit 0, got $code: $out"
diff -q "$tmp/body.md" "$GH_BODY" >/dev/null \
  || fail "body-file" "body was not passed through verbatim: $(cat "$GH_BODY")"
pass "body-file" "the caller's body reached gh unchanged"

# 11. The stacked note is an invariant of a non-main base, so it is appended to a
# caller-supplied body too — the path every ship-out now takes.
git -C "$wt" fetch -q origin
git -C "$wt" switch -q -c abc-4444 origin/coord/base
echo "stacked work" > "$wt/l.txt"
git -C "$wt" add l.txt
git -C "$wt" commit -q -m "add l"
out=$(bash "$SCRIPT" "$wt" coord/base --body-file "$tmp/body.md" 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "body-file-stacked" "expected exit 0, got $code: $out"
grep -qF "caller wrote this" "$GH_BODY" \
  || fail "body-file-stacked" "the caller's body was dropped: $(cat "$GH_BODY")"
grep -qF 'Stacked on `coord/base`' "$GH_BODY" \
  || fail "body-file-stacked" "no stacked note in: $(cat "$GH_BODY")"
pass "body-file-stacked" "the stacked note was appended to the caller's body"

# 12. The default title leads with the first ticket id in the branch name, upper-cased,
# whatever the tracker's team key is.
git -C "$wt" switch -q main
git -C "$wt" switch -q -c abc-12-x
echo "title work" > "$wt/m.txt"
git -C "$wt" add m.txt
git -C "$wt" commit -q -m "add m"
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "title-ticket" "expected exit 0, got $code: $out"
grep -qF -- '--title ABC-12: add m ' "$GH_LOG" \
  || fail "title-ticket" "default title is not 'ABC-12: add m': $(grep '^pr create' "$GH_LOG" | tail -1)"
pass "title-ticket" "branch abc-12-x got the default title ABC-12: add m"

# 13. A branch carrying no ticket id gets the commit subject alone.
git -C "$wt" switch -q main
git -C "$wt" switch -q -c scratch
echo "plain work" > "$wt/n.txt"
git -C "$wt" add n.txt
git -C "$wt" commit -q -m "add n"
out=$(bash "$SCRIPT" "$wt" main 2>&1)
code=$?
[ "$code" -eq 0 ] || fail "title-no-ticket" "expected exit 0, got $code: $out"
grep -qF -- '--title add n ' "$GH_LOG" \
  || fail "title-no-ticket" "default title is not 'add n': $(grep '^pr create' "$GH_LOG" | tail -1)"
pass "title-no-ticket" "a branch without a ticket id got the bare subject"

echo "All create-pr tests passed."
