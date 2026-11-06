#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REVIEW_CONTEXT_SH:-$REPO_ROOT/plugins/fleet-workflow/scripts/review-context.sh}"
[ -r "$SCRIPT" ] || { echo "FAIL: $SCRIPT not readable"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_contains() {
  local label="$1" out="$2" want="$3"
  if printf '%s' "$out" | grep -qF "$want"; then
    echo "PASS [$label]: found '$want'"
  else
    echo "FAIL [$label]: expected '$want' in:"; printf '%s\n' "$out"; exit 1
  fi
}

assert_absent() {
  local label="$1" out="$2" unwant="$3"
  if printf '%s' "$out" | grep -qF "$unwant"; then
    echo "FAIL [$label]: did not expect '$unwant' in:"; printf '%s\n' "$out"; exit 1
  else
    echo "PASS [$label]: no '$unwant'"
  fi
}

MATCH_HEADING="## 2026-01-01 — foo_job retries are capped at three"
OTHER_HEADING="## 2026-01-02 — unrelated widget cache eviction"
CTX_MATCH="## foo_job runs on the async tier"
CTX_OTHER="## billing surface talks to the ledger"

repo="$tmp/repo"
mkdir -p "$repo/.claude/memory"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"

printf '%s\n\nbody one.\n\n%s\n\nbody two.\n' "$MATCH_HEADING" "$OTHER_HEADING" \
  > "$repo/.claude/memory/decisions.md"
printf '%s\n\nbody one.\n\n%s\n\nbody two.\n' "$CTX_MATCH" "$CTX_OTHER" \
  > "$repo/.claude/memory/context.md"
echo "seed" > "$repo/README.md"
git -C "$repo" add .claude README.md
git -C "$repo" commit -q -m "seed"
A=$(git -C "$repo" rev-parse HEAD)

mkdir -p "$repo/app/jobs"
echo "class FooJob; end" > "$repo/app/jobs/foo_job.rb"
git -C "$repo" add app
git -C "$repo" commit -q -m "add job"
B=$(git -C "$repo" rev-parse HEAD)

out=$(bash "$SCRIPT" "$repo" "$A..$B")

# 1. The changed file is reported with its status letter, and the stat summary follows.
assert_contains "files" "$out" "A	app/jobs/foo_job.rb"
assert_contains "stat" "$out" "1 file changed"

# 2. Terms: extension-stripped basename plus the second path segment.
assert_contains "term basename" "$out" "foo_job"
assert_contains "term segment" "$out" "jobs"

# 3. Memory sizes list the store's markdown files.
assert_contains "memory sizes" "$out" "decisions.md"

# 4. Decisions grep carries the matching heading and not the unrelated one.
assert_contains "decisions hit" "$out" "$MATCH_HEADING"
assert_absent "decisions miss" "$out" "$OTHER_HEADING"

# 4b. context.md is term-filtered like the rest, not dumped whole.
assert_contains "context hit" "$out" "$CTX_MATCH"
assert_absent "context miss" "$out" "$CTX_OTHER"

# 5. Absent patterns.md / conventions.md degrade rather than fail.
assert_contains "patterns none" "$out" "PATTERNS: none"
assert_contains "conventions none" "$out" "CONVENTIONS: none"

# 6. An empty term list must never become an empty grep pattern dumping the file.
out=$(bash "$SCRIPT" "$repo" "$B..$B")
assert_contains "empty terms" "$out" "TERMS: none"
assert_contains "empty decisions" "$out" "DECISIONS: none"
assert_absent "empty no dump" "$out" "$OTHER_HEADING"
assert_absent "empty no dump 2" "$out" "$MATCH_HEADING"

# 7. No .claude/memory/ at all.
bare="$tmp/bare"
mkdir -p "$bare"
git -C "$bare" init -q -b main
git -C "$bare" config user.email "test@example.com"
git -C "$bare" config user.name "Test"
echo "seed" > "$bare/README.md"
git -C "$bare" add README.md
git -C "$bare" commit -q -m "seed"
BA=$(git -C "$bare" rev-parse HEAD)
mkdir -p "$bare/lib/util"
echo "x" > "$bare/lib/util/thing.rb"
git -C "$bare" add lib
git -C "$bare" commit -q -m "add thing"
BB=$(git -C "$bare" rev-parse HEAD)
out=$(bash "$SCRIPT" "$bare" "$BA..$BB")
assert_contains "no memory terms" "$out" "util"
assert_contains "no memory dir" "$out" "MEMORY-SIZES: none"
assert_contains "no memory decisions" "$out" "DECISIONS: none"
assert_contains "no memory context" "$out" "CONTEXT: none"

# 8. Paths under .claude/memory/ contribute no terms.
echo "extra line" >> "$repo/.claude/memory/decisions.md"
git -C "$repo" add .claude/memory/decisions.md
git -C "$repo" commit -q -m "touch memory store"
C=$(git -C "$repo" rev-parse HEAD)
out=$(bash "$SCRIPT" "$repo" "$B..$C")
terms=$(printf '%s\n' "$out" | awk '/^TERMS:/{f=1; next} /^[A-Z-]+:/{f=0} f')
assert_contains "memory-path file listed" "$out" ".claude/memory/decisions.md"
assert_contains "memory-path terms none" "$out" "TERMS: none"
assert_absent "memory-path no decisions term" "$terms" "decisions"
assert_absent "memory-path no memory term" "$terms" "memory"
assert_contains "memory-path decisions none" "$out" "DECISIONS: none"

# 9. Bad invocation: missing args / not a repo.
if bash "$SCRIPT" 2>/dev/null; then echo "FAIL [usage]: expected exit 2"; exit 1; else echo "PASS [usage]: non-zero on missing args"; fi
if bash "$SCRIPT" "$repo" 2>/dev/null; then echo "FAIL [usage-range]: expected exit 2"; exit 1; else echo "PASS [usage-range]: non-zero on missing range"; fi
if bash "$SCRIPT" "$tmp" "HEAD" 2>/dev/null; then echo "FAIL [not-a-repo]: expected exit 2"; exit 1; else echo "PASS [not-a-repo]: non-zero outside a repo"; fi

echo "All review-context tests passed."
