#!/usr/bin/env bash
# Remove linked worktrees whose PR is merged. Runs from anywhere inside a repo and never
# removes the worktree it is invoked from, which is why a worktree session cannot clean
# itself up and the main checkout does it.
#
# usage: sweep-worktrees.sh [--dry-run] [--base <branch>] [--repo <path>] [<branch> ...]
#   default: sweep worktrees whose merged PR targets main, plus nodes whose merged PR
#     targets a branch that has itself merged into main (directly or up a stack)
#   --base <b>: sweep worktrees whose merged PR targets <b> (an integration branch)
#   <branch> ...: sweep only these branches, whatever their PR base
# Exit 0 on success (nothing to do included), 1 on usage error, 2 outside a git repo.

set -u

dry_run=0
base="main"
repo="."
branches=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --base) base="$2"; shift ;;
    --repo) repo="$2"; shift ;;
    --*) echo "usage: sweep-worktrees.sh [--dry-run] [--base <branch>] [--repo <path>] [<branch> ...]" >&2; exit 1 ;;
    *) branches+=("$1") ;;
  esac
  shift
done

common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 2
root="$(cd "$(dirname "$common")" && pwd -P)"
self="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"
self="$(cd "$self" && pwd -P)"

wanted() {
  [ "${#branches[@]}" -eq 0 ] && return 0
  local b
  for b in "${branches[@]}"; do [ "$b" = "$1" ] && return 0; done
  return 1
}

pr_cache=""
pr_target=""
pr_reason=""
pr_lookup() {
  local pr entry=""
  case "$pr_cache" in
    *"|$1>"*) entry="${pr_cache#*"|$1>"}"; entry="${entry%%|*}" ;;
  esac
  if [ -z "$entry" ]; then
    pr="$(cd "$root" && gh pr view "$1" --json state,baseRefName --jq '.state + " " + .baseRefName' 2>/dev/null)"
    if [ -z "$pr" ]; then entry="nopr"
    elif [ "${pr%% *}" = "MERGED" ]; then entry="merged ${pr#* }"
    else entry="live"
    fi
    pr_cache="$pr_cache|$1>$entry|"
  fi
  pr_reason="${entry%% *}"
  pr_target="${entry#merged }"
  [ "$pr_reason" = "merged" ]
}

max_chain_hops=4
chain_out=""
stop_reason=""
resolve_chain() {
  local b="$1" depth=0
  chain_out="PR merged into $1"; stop_reason=""
  while [ "$depth" -lt "$max_chain_hops" ]; do
    pr_lookup "$b" || { stop_reason="$pr_reason"; return 1; }
    chain_out="$chain_out, $b merged into $pr_target"
    [ "$pr_target" = "$base" ] && return 0
    b="$pr_target"
    depth=$((depth + 1))
  done
  stop_reason="live"
  return 1
}

removed=0
path=""
branch=""
flush() {
  [ -z "$path" ] && return
  local p b chain=""
  p="$(cd "$path" 2>/dev/null && pwd -P)" || { echo "kept $path: missing on disk (run git worktree prune)"; return; }
  b="$branch"
  path=""; branch=""
  [ "$p" = "$root" ] && return
  [ -z "$b" ] && { echo "kept $p: detached HEAD"; return; }
  wanted "$b" || return
  [ "$p" = "$self" ] && { echo "kept $p: current worktree, sweep it from the main checkout"; return; }
  local pr state prbase
  pr="$(cd "$root" && gh pr view "$b" --json state,baseRefName --jq '.state + " " + .baseRefName' 2>/dev/null)" || { echo "kept $p: no PR for $b"; return; }
  state="${pr%% *}"; prbase="${pr#* }"
  [ "$state" = "MERGED" ] || { echo "kept $p: PR $state"; return; }
  if [ "${#branches[@]}" -eq 0 ] && [ "$prbase" != "$base" ]; then
    if [ "$base" = "main" ] && resolve_chain "$prbase"; then
      chain="$chain_out"
    elif [ "$base" = "main" ] && [ "$stop_reason" = "live" ]; then
      echo "kept $p: PR merged into $prbase, that set is still live"; return
    else
      echo "kept $p: PR targets $prbase, not $base"; return
    fi
  fi
  if [ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]; then
    echo "kept $p: uncommitted changes"; return
  fi
  if [ "$dry_run" -eq 1 ]; then
    echo "would remove $p ($b)"
    [ -n "$chain" ] && echo "  $chain"
    return
  fi
  git -C "$root" worktree remove "$p" || { echo "kept $p: git worktree remove failed"; return; }
  git -C "$root" branch -D "$b" >/dev/null 2>&1
  echo "removed $p ($b)"
  [ -n "$chain" ] && echo "  $chain"
  removed=$((removed + 1))
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*) flush; path="${line#worktree }" ;;
    "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
    "") ;;
  esac
done < <(git -C "$root" worktree list --porcelain; echo)
flush
[ "$dry_run" -eq 1 ] || git -C "$root" worktree prune

exit 0
