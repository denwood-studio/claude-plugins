#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="${CA_AUDIT_PLUGIN_DIR:-$REPO/plugins/ca-distrust-audit}"
SCRIPT="$PLUGIN/scripts/audit.sh"
FIXTURES="$REPO/tests/ca-distrust-audit/fixtures"
EMUDHRA="$PLUGIN/data/emudhra-2026-10.tsv"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail=0
pass() { echo "PASS [$1]"; }
bad() { echo "FAIL [$1]: $2"; fail=1; }
show() { printf '%s\n' "$1" | sed 's/^/    | /'; }

# prints one problem per line; nothing when the file is well formed
lint() {
  awk -F'\t' '
    function problem(m) { print FILENAME ":" FNR ": " m }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    {
      d = $1
      if (d == "event" || d == "as-of" || d == "source") want = 2
      else if (d == "cert" || d == "fixed" || d == "line") want = 3
      else { problem("unknown directive \"" d "\""); next }
      if (NF != want) { problem(d " needs " want " fields, has " NF); next }
      for (i = 2; i <= NF; i++) if ($i == "") problem(d " has an empty field " i)
      if (d == "event") nevent++
      if (d == "as-of") {
        nasof++
        if ($2 !~ /^[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/) problem("as-of is not YYYY-MM-DD: " $2)
      }
      if (d == "source") { nsource++; if ($2 !~ /^https?:\/\//) problem("source is not a URL: " $2) }
      if (d == "cert") {
        if (length($2) != 64 || $2 !~ /^[0-9A-F]+$/) problem("cert is not 64 uppercase hex: " $2)
        if ($2 in seen) problem("duplicate cert " $2)
        seen[$2] = 1
      }
      if (d == "fixed" && $2 !~ /^[a-z0-9:_-]+$/) problem("component name looks wrong: " $2)
    }
    END {
      if (nevent != 1) problem("needs exactly one event line, has " nevent + 0)
      if (nasof != 1) problem("needs exactly one as-of line, has " nasof + 0)
      if (nsource < 1) problem("needs at least one source line")
    }
  ' "$1" 2>&1
}

lint_regex() {
  awk -F'\t' '$1 == "line" { print $3 }' "$1" | while IFS= read -r re; do
    RE="$re" awk 'BEGIN { x = ("" ~ ENVIRON["RE"]) }' 2> /dev/null || echo "$1: line ERE does not compile in awk: $re"
  done
}

shopt -s nullglob
files=("$PLUGIN"/data/*.tsv)
[ "${#files[@]}" -gt 0 ] && pass "there-is-at-least-one-data-file" || bad "there-is-at-least-one-data-file" "none in $PLUGIN/data"

for f in "${files[@]}"; do
  n="$(basename "$f")"
  problems="$(lint "$f"; lint_regex "$f")"
  if [ -z "$problems" ]; then pass "lint-$n"; else bad "lint-$n" "malformed"; show "$problems"; fi
done

bad_data="$tmp/bad.tsv"
printf 'event\tone\nevent\ttwo\nas-of\t26-11-11\nbogus\tx\ncert\tabc\tlabel\nfixed\tnode\nline\tnode\t(\n' > "$bad_data"
problems="$(lint "$bad_data"; lint_regex "$bad_data")"
for want in 'unknown directive "bogus"' 'exactly one event' 'as-of is not YYYY-MM-DD' 'needs at least one source' 'cert is not 64' 'fixed needs 3 fields' 'ERE does not compile'; do
  if printf '%s\n' "$problems" | grep -qF -- "$want"; then pass "lint-rejects-$(printf '%s' "$want" | tr -c 'A-Za-z0-9' '-')"; else bad "lint-rejects-$want" "not reported"; show "$problems"; fi
done

der_sha() {
  sed -e '1d;$d' "$1" | tr -d '\n' | openssl base64 -d -A | openssl dgst -sha256 | awk '{ print toupper($NF) }'
}

aaa="$(der_sha "$FIXTURES/aaa-certificate-services.pem")"
if awk -F'\t' -v h="$aaa" '$1 == "cert" && $2 == h && $3 ~ /AAA Certificate Services/ { found = 1 } END { exit !found }' "$EMUDHRA"; then
  pass "the-aaa-root-fixture-hash-is-in-the-emudhra-file"
else
  bad "the-aaa-root-fixture-hash-is-in-the-emudhra-file" "$aaa is not a cert line"
fi

roots="$(awk -F'\t' '$1 == "cert" && $3 ~ /\(root\)$/' "$EMUDHRA" | wc -l | tr -d ' ')"
all="$(awk -F'\t' '$1 == "cert"' "$EMUDHRA" | wc -l | tr -d ' ')"
[ "$roots" = 4 ] && [ "$all" = 20 ] && pass "emudhra-file-has-4-roots-and-16-intermediates" || bad "emudhra-file-has-4-roots-and-16-intermediates" "roots $roots, certs $all"

for comp in macos node electron dpkg:ca-certificates apk:ca-certificates; do
  awk -F'\t' -v c="$comp" '$1 == "fixed" && $2 == c { n++ } END { exit !n }' "$EMUDHRA" && pass "emudhra-file-has-fixed-$comp" || bad "emudhra-file-has-fixed-$comp" "no fixed line"
done

synth_sha="$(der_sha "$FIXTURES/synthetic-test-ca.pem")"
data="$tmp/data"
mkdir -p "$data"
cp "$EMUDHRA" "$data/emudhra-2026-10.tsv"
printf '# a synthetic event added as data only\nevent\tSynthetic test event\nas-of\t2031-01-02\nsource\thttps://example.invalid/synthetic\ncert\t%s\tSynthetic Test CA (root)\nfixed\tnode\t99.1.0\n' \
  "$synth_sha" > "$data/synthetic-2031-01.tsv"
problems="$(lint "$data/synthetic-2031-01.tsv")"
[ -z "$problems" ] && pass "lint-synthetic-event" || { bad "lint-synthetic-event" "malformed"; show "$problems"; }

emu_asof="$(awk -F'\t' '$1 == "as-of" { print $2 }' "$EMUDHRA")"

section() {
  printf '%s\n' "$1" | awk -v start="$2" '
    /^Checked against: / { on = (index($0, start) == 1); if (on) print; next }
    /^Not checked: / { on = 0 }
    on { print }
  '
}

repo="$tmp/repo"
mkdir -p "$repo/a" "$repo/b"
cp "$FIXTURES/synthetic-test-ca.pem" "$repo/a/synthetic.pem"
cp "$FIXTURES/aaa-certificate-services.pem" "$repo/b/aaa.pem"
out="$(CA_AUDIT_DATA_DIR="$data" "$SCRIPT" repo "$repo")"
printf '%s\n' "$out" | grep -Fq "Checked against: eMudhra intermediate CA compromise, October 2026 — fixed-version list as of $emu_asof (" && pass "repo-names-the-emudhra-list-and-its-date" || { bad "repo-names-the-emudhra-list-and-its-date" "missing"; show "$out"; }
printf '%s\n' "$out" | grep -Fq "Checked against: Synthetic test event — fixed-version list as of 2031-01-02 (https://example.invalid/synthetic)" && pass "repo-names-the-synthetic-list-and-its-date" || { bad "repo-names-the-synthetic-list-and-its-date" "missing"; show "$out"; }
n="$(printf '%s\n' "$out" | grep -c '^Checked against: ')"
[ "$n" -eq 2 ] && pass "one-checked-against-line-per-data-file" || bad "one-checked-against-line-per-data-file" "$n lines"

emu="$(section "$out" 'Checked against: eMudhra')"
syn="$(section "$out" 'Checked against: Synthetic')"
printf '%s\n' "$syn" | grep -q '^FLAG a/synthetic\.pem: contains Synthetic Test CA (root)' && pass "synthetic-cert-is-flagged-under-the-synthetic-event" || { bad "synthetic-cert-is-flagged-under-the-synthetic-event" "no flag"; show "$syn"; }
printf '%s\n' "$emu" | grep -q 'synthetic\.pem' && bad "synthetic-cert-is-not-flagged-under-the-emudhra-event" "flagged" || pass "synthetic-cert-is-not-flagged-under-the-emudhra-event"
printf '%s\n' "$emu" | grep -q '^FLAG b/aaa\.pem: contains AAA Certificate Services' && pass "aaa-root-is-flagged-under-the-emudhra-event" || { bad "aaa-root-is-flagged-under-the-emudhra-event" "no flag"; show "$emu"; }
printf '%s\n' "$syn" | grep -q 'aaa\.pem' && bad "aaa-root-is-not-flagged-under-the-synthetic-event" "flagged" || pass "aaa-root-is-not-flagged-under-the-synthetic-event"
printf '%s\n' "$syn" | grep -q 'container build files' && bad "an-event-without-image-versions-skips-dockerfiles" "reported" || pass "an-event-without-image-versions-skips-dockerfiles"

if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$tmp/home" "$tmp/n98" "$tmp/apps"
  printf '#!/bin/sh\necho v98.2.0\n' > "$tmp/n98/node"
  chmod +x "$tmp/n98/node"
  out="$(env HOME="$tmp/home" PATH=/usr/bin:/bin CA_AUDIT_DATA_DIR="$data" CA_AUDIT_NODE_DIRS="$tmp/n98" CA_AUDIT_APP_DIRS="$tmp/apps" CA_AUDIT_MACOS_VERSION=27.3 "$SCRIPT" machine)"
  n="$(printf '%s\n' "$out" | grep -c '^Checked against: ')"
  [ "$n" -eq 2 ] && pass "machine-prints-both-dated-checked-against-lines" || bad "machine-prints-both-dated-checked-against-lines" "$n lines"
  printf '%s\n' "$out" | grep -Fq "fixed-version list as of 2031-01-02" && pass "machine-names-the-synthetic-date" || bad "machine-names-the-synthetic-date" "missing"
  emu="$(section "$out" 'Checked against: eMudhra')"
  syn="$(section "$out" 'Checked against: Synthetic')"
  printf '%s\n' "$syn" | grep -q "^FLAG $tmp/n98/node: Node 98\\.2\\.0 .* move to 99\\.1\\.0\$" && pass "v98-node-is-flagged-under-the-synthetic-event" || { bad "v98-node-is-flagged-under-the-synthetic-event" "no flag"; show "$syn"; }
  printf '%s\n' "$emu" | grep -q "^CLEAR $tmp/n98/node: " && pass "v98-node-is-clear-under-the-emudhra-event" || { bad "v98-node-is-clear-under-the-emudhra-event" "not clear"; show "$emu"; }
  printf '%s\n' "$syn" | grep -q 'macOS' && bad "an-event-without-macos-versions-skips-macos" "reported" || pass "an-event-without-macos-versions-skips-macos"
else
  echo "PASS [synthetic-event-on-machine-skipped] skipped: machine mode runs on macOS only"
fi

vdata="$tmp/vdata"
mkdir -p "$vdata" "$tmp/vrepo"
printf 'event\tVersion rule\nas-of\t2031-01-02\nsource\thttps://example.invalid/v\nfixed\tdpkg:ca-certificates\t1.10\nfixed\tdpkg:ca-certificates\t3.0~beta2\n' > "$vdata/v.tsv"
version_status() {
  printf 'FROM debian:12\nRUN dpkg --compare-versions "$(dpkg-query -W -f='"'"'${Version}'"'"' ca-certificates)" ge %s\n' "$1" > "$tmp/vrepo/Dockerfile"
  CA_AUDIT_DATA_DIR="$vdata" "$SCRIPT" repo "$tmp/vrepo" | awk '$2 == "Dockerfile:" && ($1 == "FLAG" || $1 == "UNCONFIRMED" || $1 == "CLEAR") { print $1 }'
}
for pair in 1.9:FLAG 1.10:CLEAR 1.10~rc1:FLAG 1.10a:CLEAR 1.10+b1:CLEAR 1.011:CLEAR 2.5:FLAG 3.0~beta1:FLAG 3.0~beta2:CLEAR 3.0:CLEAR 4.0:CLEAR 0.9:FLAG; do
  v="${pair%%:*}"; want="${pair##*:}"
  got="$(version_status "$v")"
  [ "$got" = "$want" ] && pass "version-rule-$v-is-$want" || bad "version-rule-$v-is-$want" "got '$got'"
done

mkdir -p "$tmp/undated"
printf 'event\tNo date\nsource\thttps://example.invalid/x\n' > "$tmp/undated/x.tsv"
rc=0; CA_AUDIT_DATA_DIR="$tmp/undated" "$SCRIPT" repo "$repo" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "a-data-file-without-an-as-of-date-is-refused" || bad "a-data-file-without-an-as-of-date-is-refused" "exit $rc"

exit "$fail"
