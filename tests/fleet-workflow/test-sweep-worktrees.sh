#!/usr/bin/env bash
# Smoke test for sweep-worktrees.sh. Builds a repo with linked worktrees, stubs `gh` per
# branch, and asserts which worktrees are removed and which are kept, including the
# self-worktree case that motivated the script.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../plugins/fleet-workflow/scripts" && pwd)/sweep-worktrees.sh"
[ -r "$SCRIPT" ] || { echo "FAIL: $SCRIPT not readable"; exit 1; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
# gh pr view <branch> --json state,baseRefName --jq '...'
branch="$3"
case "$branch" in
  merged-main)  printf 'MERGED main' ;;
  merged-coord) printf 'MERGED coord/set' ;;
  merged-coord-done) printf 'MERGED coord/done' ;;
  stacked-b)    printf 'MERGED node-a' ;;
  node-a)       printf 'MERGED coord/done' ;;
  stacked-live) printf 'MERGED node-live' ;;
  node-live)    printf 'MERGED coord/set' ;;
  orphan-base)  printf 'MERGED coord/ghost' ;;
  deep-node)    printf 'MERGED d1' ;;
  d1)           printf 'MERGED d2' ;;
  d2)           printf 'MERGED d3' ;;
  d3)           printf 'MERGED d4' ;;
  d4)           printf 'MERGED d5' ;;
  d5)           printf 'MERGED main' ;;
  abc-1801)     printf 'MERGED abc-1800' ;;
  abc-1800)     printf 'MERGED main' ;;
  coord/set)    printf 'OPEN main' ;;
  coord/done)   printf 'MERGED main' ;;
  open-main)    printf 'OPEN main' ;;
  dirty-main)   printf 'MERGED main' ;;
  self-main)    printf 'MERGED main' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
echo a > "$repo/f.txt"; git -C "$repo" add f.txt; git -C "$repo" commit -q -m a

for b in merged-main merged-coord merged-coord-done stacked-b stacked-live orphan-base deep-node abc-1801 open-main dirty-main self-main no-pr; do
  git -C "$repo" worktree add -q -b "$b" "$tmp/wt-$b" main
done
echo dirty > "$tmp/wt-dirty-main/g.txt"

fail=0
check() { # <desc> <expected-substring> <output>
  if printf '%s\n' "$3" | grep -qF -- "$2"; then echo "ok   $1"; else echo "FAIL $1: expected '$2' in:"; printf '%s\n' "$3" | sed 's/^/     /'; fail=1; fi
}
exists() { [ -d "$tmp/wt-$1" ]; }

out="$("$SCRIPT" --dry-run --repo "$repo")"
check "dry-run names the merged-main worktree" "would remove $tmp/wt-merged-main (merged-main)" "$out"
exists merged-main || { echo "FAIL dry-run removed a worktree"; fail=1; }

out="$("$SCRIPT" --repo "$tmp/wt-self-main")"
check "self worktree kept" "kept $tmp/wt-self-main: current worktree" "$out"
check "merged onto main removed" "removed $tmp/wt-merged-main (merged-main)" "$out"
check "merged onto live coord kept by default" "kept $tmp/wt-merged-coord: PR merged into coord/set, that set is still live" "$out"
check "merged onto merged coord removed" "removed $tmp/wt-merged-coord-done (merged-coord-done)" "$out"
check "merged coord chain on its own line" "  PR merged into coord/done, coord/done merged into main" "$out"
check "stacked node removed" "removed $tmp/wt-stacked-b (stacked-b)" "$out"
check "stacked chain on its own line" "  PR merged into node-a, node-a merged into coord/done, coord/done merged into main" "$out"
check "stacked node on a live chain kept" "kept $tmp/wt-stacked-live: PR merged into node-live, that set is still live" "$out"
check "base with no PR keeps the old wording" "kept $tmp/wt-orphan-base: PR targets coord/ghost, not main" "$out"
check "chain past the depth cap kept" "kept $tmp/wt-deep-node: PR merged into d1, that set is still live" "$out"
check "open PR kept" "kept $tmp/wt-open-main: PR OPEN" "$out"
check "dirty worktree kept" "kept $tmp/wt-dirty-main: uncommitted changes" "$out"
check "no PR kept" "kept $tmp/wt-no-pr: no PR" "$out"
exists merged-main && { echo "FAIL merged-main still on disk"; fail=1; }
exists merged-coord-done && { echo "FAIL merged-coord-done still on disk"; fail=1; }
exists merged-coord || { echo "FAIL merged-coord removed"; fail=1; }
exists stacked-b && { echo "FAIL stacked-b still on disk"; fail=1; }
exists stacked-live || { echo "FAIL stacked-live removed"; fail=1; }
exists orphan-base || { echo "FAIL orphan-base removed"; fail=1; }
exists deep-node || { echo "FAIL deep-node removed"; fail=1; }
exists abc-1801 && { echo "FAIL abc-1801 still on disk"; fail=1; }
tickets="$(printf '%s\n' "$out" | grep '^removed ' | sed 's/^removed //' | grep -oiE '[a-z]+-[0-9]+' | tr '[:lower:]' '[:upper:]' | sort -u | tr '\n' ' ' | sed 's/ $//')"
[ "$tickets" = "ABC-1801" ] || { echo "FAIL ticket extraction saw '$tickets', expected 'ABC-1801'"; fail=1; }
exists self-main || { echo "FAIL self-main removed"; fail=1; }
git -C "$repo" rev-parse --verify -q merged-main >/dev/null && { echo "FAIL merged-main branch not deleted"; fail=1; }

out="$("$SCRIPT" --repo "$repo" --base coord/set)"
check "--base sweeps coord nodes" "removed $tmp/wt-merged-coord (merged-coord)" "$out"
check "--base keeps a main-merged worktree with the old wording" "kept $tmp/wt-self-main: PR targets main, not coord/set" "$out"
check "--base does not escalate a stacked node" "kept $tmp/wt-stacked-live: PR targets node-live, not coord/set" "$out"
exists self-main || { echo "FAIL --base removed a main-merged worktree"; fail=1; }
exists stacked-live || { echo "FAIL --base removed a stacked node"; fail=1; }

out="$("$SCRIPT" --repo "$repo" --base main --dry-run)"
check "--base main behaves like the default sweep" "would remove $tmp/wt-self-main (self-main)" "$out"
check "--base main still escalates" "kept $tmp/wt-stacked-live: PR merged into node-live, that set is still live" "$out"

out="$("$SCRIPT" --repo "$repo" self-main)"
check "explicit branch from main checkout removed" "removed $tmp/wt-self-main (self-main)" "$out"
[ -z "$(printf '%s' "$out" | grep -v self-main)" ] || { echo "FAIL explicit branch list touched other worktrees"; fail=1; }

"$SCRIPT" --repo "$tmp" >/dev/null 2>&1 && { echo "FAIL non-repo did not exit non-zero"; fail=1; }

[ "$fail" -eq 0 ] && echo "all passed" || exit 1
