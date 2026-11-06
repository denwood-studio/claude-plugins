#!/usr/bin/env bash
# Rebase a ticket branch onto its base, push it, and open (or retarget) its PR.
#
# Everything here is deterministic shell except the ticket state change, which stays with
# the caller: it has tracker access where this script does not.
#
# The script never asks a question. A missing or malformed input is the caller's
# mistake and comes back as ERROR:; a choice only a human can make (two plausible
# bases, a conflict whose resolution changes behaviour) is the caller's to put to
# the user.
#
# Usage: create-pr.sh <worktree> <base> [--title <t>] [--body-file <f>]
#   <base> is required and is never assumed to be main. A stacked epic node whose
#   PR targets the trunk shows its blocker's unmerged commits in the diff and gets
#   reviewed on the wrong change, so an unresolvable base is an error, not a
#   fallback to main.
#
# Output on success:
#   PR: <url>
#   BASE: <branch>
#   STACKED: <branches>   only when other local branches sit on rewritten commits
#
# On a stop condition: `ERROR: <reason>` on stderr, and no PR is opened.
# Exit codes: 2 usage, 3 dirty tree / unresolvable base / nothing to open,
# 4 rebase conflict, 5 push or gh failure.

set -uo pipefail

die() {
  local code="$1"; shift
  echo "ERROR: $*" >&2
  exit "$code"
}

WT="${1:-}"; BASE="${2:-}"
shift $(( $# < 2 ? $# : 2 ))

TITLE=""
BODY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title)
      [ $# -ge 2 ] || die 2 "--title needs a value"
      TITLE="$2"; shift 2 ;;
    --body-file)
      [ $# -ge 2 ] || die 2 "--body-file needs a value"
      BODY_FILE="$2"; shift 2 ;;
    *)
      die 2 "unknown argument '$1'; usage: create-pr.sh <worktree> <base> [--title <t>] [--body-file <f>]" ;;
  esac
done

if [ -z "$WT" ] || [ -z "$BASE" ]; then
  die 2 "create-pr.sh needs <worktree> and <base>; usage: create-pr.sh <worktree> <base> [--title <t>] [--body-file <f>]"
fi
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || die 2 "$WT is not a git worktree"
if [ -n "$BODY_FILE" ] && [ ! -r "$BODY_FILE" ]; then
  die 2 "body file $BODY_FILE is not readable"
fi

BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null)
[ -n "$BRANCH" ] || die 3 "$WT has a detached HEAD; check out the ticket branch first"
[ -z "$(git -C "$WT" status --porcelain)" ] || die 3 "dirty worktree $WT; commit or stash before opening a PR"

PRE_ORIGIN=$(git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null)

git -C "$WT" fetch origin --quiet 2>/dev/null

if git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$BASE" >/dev/null 2>&1; then
  BASE_REF="origin/$BASE"
elif git -C "$WT" rev-parse --verify --quiet "refs/heads/$BASE" >/dev/null 2>&1; then
  BASE_REF="$BASE"
else
  die 3 "base origin/$BASE not found"
fi

OLD_HEAD=$(git -C "$WT" rev-parse HEAD)
if ! git -C "$WT" rebase "$BASE_REF" >/dev/null 2>&1; then
  CONFLICTS=$(git -C "$WT" diff --name-only --diff-filter=U | tr '\n' ' ')
  git -C "$WT" rebase --abort >/dev/null 2>&1
  die 4 "rebase of $BRANCH onto $BASE_REF conflicts on: ${CONFLICTS:-unknown}"
fi
NEW_HEAD=$(git -C "$WT" rev-parse HEAD)

STACKED=""
if [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
  STACKED=$(git -C "$WT" branch --format='%(refname:short)' --contains "$OLD_HEAD" 2>/dev/null \
    | grep -v "^${BRANCH}$" | tr '\n' ' ')
fi

COMMITS=$(git -C "$WT" log "$BASE_REF..HEAD" --format='%s')
[ -n "$COMMITS" ] || die 3 "$BRANCH has no commits above $BASE_REF; there is nothing to open a PR for"

# refs/remotes/origin/$BRANCH, never @{upstream} (a worktree's upstream is its base);
# the refspec is explicit so push.default cannot pick the destination; and the lease
# names the pre-fetch value, because the fetch above overwrote the ref it defaults to.
if [ -n "$PRE_ORIGIN" ]; then
  git -C "$WT" push "--force-with-lease=refs/heads/$BRANCH:$PRE_ORIGIN" origin "HEAD:refs/heads/$BRANCH" >/dev/null 2>&1 \
    || die 5 "push --force-with-lease rejected for $BRANCH; origin/$BRANCH moved since this worktree last saw it, and the lease refused rather than overwrite it — fetch and reconcile by hand"
else
  git -C "$WT" push -u origin "HEAD:refs/heads/$BRANCH" >/dev/null 2>&1 \
    || die 5 "push of $BRANCH to origin failed; if origin/$BRANCH already exists it was pushed by someone else and this push was refused as a non-fast-forward — fetch and reconcile by hand"
fi

REMOTE_URL=$(git -C "$WT" remote get-url origin 2>/dev/null)
REPO=$(printf '%s' "$REMOTE_URL" \
  | sed -E 's#^(git@[^:]+:|[a-zA-Z+]+://[^/]+/)##; s#\.git$##' \
  | awk -F/ '{ if (NF >= 2) print $(NF-1)"/"$NF; else print $0 }')
[ -n "$REPO" ] || die 5 "cannot derive owner/repo from the origin remote of $WT"

emit() {
  echo "PR: $1"
  echo "BASE: $BASE"
  [ -n "$STACKED" ] && echo "STACKED: ${STACKED% }"
  exit 0
}

ERRF=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$ERRF" "$BODY"' EXIT

# stderr goes to a file, never folded into the capture: gh writes its update
# notice there on a successful command, and 2>&1 would make that notice the
# parsed PR URL. Only the failure path reads it back.
EXISTING=$(cd "$WT" && gh pr list --repo "$REPO" --head "$BRANCH" --state open \
  --json url,baseRefName --jq '.[0] | select(.) | "\(.url)\t\(.baseRefName)"' 2>"$ERRF")
LIST_STATUS=$?
[ "$LIST_STATUS" -eq 0 ] \
  || die 5 "gh pr list exited $LIST_STATUS for $BRANCH in $REPO, so whether a PR is already open is unknown: $(cat "$ERRF")"

if [ -n "$EXISTING" ]; then
  PR_URL="${EXISTING%%$'\t'*}"
  PR_BASE="${EXISTING##*$'\t'}"
  if [ "$PR_BASE" != "$BASE" ]; then
    (cd "$WT" && gh pr edit "$PR_URL" --base "$BASE" >/dev/null 2>&1) \
      || die 5 "$PR_URL targets $PR_BASE, not $BASE, and could not be retargeted; its diff would misrepresent the change"
  fi
  emit "$PR_URL"
fi

if [ -z "$TITLE" ]; then
  TICKET=$(printf '%s' "$BRANCH" | grep -oE '[A-Za-z]+-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
  SUBJECT=$(printf '%s\n' "$COMMITS" | tail -1)
  TITLE="${TICKET:+$TICKET: }$SUBJECT"
fi

if [ -n "$BODY_FILE" ]; then
  cat "$BODY_FILE" > "$BODY"
else
  {
    echo "## Summary"
    printf '%s\n' "$COMMITS" | sed 's/^/- /'
  } > "$BODY"
fi

# An invariant of a stacked PR, not a property of the default body: the note is
# appended on the caller-supplied path too, which is the one ship-out now uses.
if [ "$BASE" != "main" ]; then
  {
    echo
    echo "> Stacked on \`$BASE\`. Review only the commits above that branch. GitHub retargets a PR to the trunk only when its base branch is *deleted*, so if this repo doesn't delete branches on merge this PR keeps pointing at \`$BASE\` and its diff widens once that branch lands — retarget it by hand at that point."
  } >> "$BODY"
fi

CREATED=$(cd "$WT" && gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" \
  --title "$TITLE" --body-file "$BODY" --assignee @me 2>&1)
STATUS=$?
PR_URL=$(printf '%s\n' "$CREATED" | grep -oE 'https://[^[:space:]]+/pull/[0-9]+' | tail -1)
if [ "$STATUS" -ne 0 ] || [ -z "$PR_URL" ]; then
  die 5 "gh pr create failed for $BRANCH against $BASE: $CREATED"
fi

emit "$PR_URL"
