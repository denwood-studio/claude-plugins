#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="${CA_AUDIT_PLUGIN_DIR:-$REPO/plugins/ca-distrust-audit}"
SCRIPT="$PLUGIN/scripts/audit.sh"
FIXTURES="$REPO/tests/ca-distrust-audit/fixtures"
DATA="$PLUGIN/data/emudhra-2026-10.tsv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
pass() { echo "PASS [$1]"; }
bad() { echo "FAIL [$1]: $2"; fail=1; }

show() { printf '%s\n' "$1" | sed 's/^/    | /'; }

has() {
  if printf '%s\n' "$2" | grep -Eq -- "$3"; then pass "$1"; else bad "$1" "no line matching: $3"; show "$2"; fi
}

lacks() {
  if printf '%s\n' "$2" | grep -Eq -- "$3"; then bad "$1" "unexpected line matching: $3"; show "$2"; else pass "$1"; fi
}

audit() { "$SCRIPT" repo "$1"; }

newrepo() {
  mkdir -p "$tmp/$1"
  printf '%s\n' "$tmp/$1"
}

CHECK='ge 20250419~deb12u2'
ASSERT_PREFIX='RUN dpkg --compare-versions "$(dpkg-query -W -f='"'"'${Version}'"'"' ca-certificates)"'

asof="$(awk -F'\t' '$1 == "as-of" { print $2 }' "$DATA")"
case "$asof" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) pass "data-has-an-as-of-date" ;;
  *) bad "data-has-an-as-of-date" "got '$asof'" ;;
esac

d="$(newrepo unpatched)"
printf 'FROM ruby:3.3-slim\nRUN apt-get update && apt-get install -y --no-install-recommends curl\nCMD ["ruby"]\n' > "$d/Dockerfile"
out="$(audit "$d")"; rc=$?
[ "$rc" -eq 0 ] && pass "exit-0-on-a-flagged-audit" || bad "exit-0-on-a-flagged-audit" "exit $rc"
has "unpatched-single-stage-is-flagged" "$out" '^FLAG Dockerfile: .*ca-certificates'
has "flag-names-the-from-image-as-written" "$out" '^FLAG Dockerfile: stage FROM ruby:3\.3-slim '
has "flag-lists-the-fixed-versions" "$out" '^FLAG Dockerfile: .*move to ca-certificates 20250419~deb12u2, '
has "unpatched-verdict-is-flagged" "$out" '^Verdict: FLAGGED$'
has "report-opens-with-the-read-only-header" "$out" "^CA distrust audit \\(read-only\\): repo $d\$"
has "report-states-the-list-date" "$out" "^Checked against: .* — fixed-version list as of $asof \\(https://"
has "report-has-a-not-checked-line" "$out" '^Not checked: lockfiles and version pins'

d="$(newrepo multistage)"
cat > "$d/Dockerfile" <<EOF
FROM debian:12 AS base
RUN apt-get update && apt-get install -y ca-certificates \\
  # the assertion fails the build on an old store
  && $ASSERT_PREFIX $CHECK
FROM base AS build
RUN echo build
FROM BASE AS runtime
RUN echo run
EOF
out="$(audit "$d")"
has "multi-stage-assertion-in-base-is-clear" "$out" '^CLEAR Dockerfile: .*20250419~deb12u2'
lacks "multi-stage-has-no-flag" "$out" '^(FLAG|UNCONFIRMED) '
has "multi-stage-verdict-is-clear" "$out" '^Verdict: CLEAR$'
has "clear-report-states-the-list-date" "$out" "^Checked against: .* as of $asof "

d="$(newrepo prod-patched-dev-not)"
printf 'FROM debian:12\n%s %s\n' "$ASSERT_PREFIX" "$CHECK" > "$d/Dockerfile"
printf 'FROM debian:12\nRUN apt-get update && apt-get install -y curl\n' > "$d/Dockerfile.dev"
out="$(audit "$d")"
has "prod-patched-is-clear" "$out" '^CLEAR Dockerfile: '
has "dev-unpatched-is-flagged" "$out" '^FLAG Dockerfile\.dev: .*ca-certificates'
lacks "prod-patched-is-not-flagged" "$out" '^FLAG Dockerfile: '
has "one-flagged-file-makes-the-verdict-flagged" "$out" '^Verdict: FLAGGED$'

d="$(newrepo install-only)"
printf 'FROM debian:12\nRUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl\n' > "$d/Dockerfile"
out="$(audit "$d")"
has "install-without-assertion-is-unconfirmed" "$out" '^UNCONFIRMED Dockerfile: .*ca-certificates.*docker run --rm <your-image> dpkg-query'
lacks "install-without-assertion-is-not-flagged" "$out" '^FLAG '
has "unconfirmed-verdict" "$out" '^Verdict: UNCONFIRMED$'

d="$(newrepo full-upgrade)"
printf 'FROM debian:12\nRUN apt-get update && apt-get -y upgrade\n' > "$d/Dockerfile"
printf 'FROM fedora:44\nRUN dnf -y update\n' > "$d/Containerfile"
out="$(audit "$d")"
has "apt-full-upgrade-is-unconfirmed" "$out" '^UNCONFIRMED Dockerfile: '
has "dnf-update-is-unconfirmed" "$out" '^UNCONFIRMED Containerfile: '

d="$(newrepo apt-update-alone)"
printf 'FROM debian:12\nRUN apt-get update && apt-get install -y curl\n' > "$d/Dockerfile"
out="$(audit "$d")"
has "apt-update-and-an-unrelated-install-is-flagged" "$out" '^FLAG Dockerfile: '

for pair in "20250419:old-year-month" "20240203:older-year-month"; do
  v="${pair%%:*}"; n="${pair##*:}"
  d="$(newrepo "assert-$n")"
  printf 'FROM debian:12\n%s ge %s\n' "$ASSERT_PREFIX" "$v" > "$d/Dockerfile"
  out="$(audit "$d")"
  has "assertion-ge-$v-is-flagged" "$out" '^FLAG Dockerfile: '
done

d="$(newrepo assert-deb12)"
printf 'FROM debian:12\n%s ge 20250419~deb12u2\n' "$ASSERT_PREFIX" > "$d/Dockerfile"
has "assertion-ge-20250419-tilde-deb12u2-is-clear" "$(audit "$d")" '^CLEAR Dockerfile: '

d="$(newrepo assert-deb13)"
printf 'FROM debian:13\n%s ge 20250419+deb13u1\n' "$ASSERT_PREFIX" > "$d/Dockerfile"
has "assertion-ge-20250419-plus-deb13u1-is-clear" "$(audit "$d")" '^CLEAR Dockerfile: '

d="$(newrepo assert-ubuntu)"
printf 'FROM ubuntu:24.04\n%s gt 20260816ubuntu0.24.04.1\n' "$ASSERT_PREFIX" > "$d/Dockerfile"
has "assertion-on-the-ubuntu-line-is-clear" "$(audit "$d")" '^CLEAR Dockerfile: '

d="$(newrepo assert-debian-line-too-old)"
printf 'FROM debian:12\n%s ge 20250419~deb12u1\n' "$ASSERT_PREFIX" > "$d/Dockerfile"
has "assertion-below-the-fixed-release-on-its-line-is-flagged" "$(audit "$d")" '^FLAG Dockerfile: '

d="$(newrepo assert-unknown)"
printf 'FROM debian:12\nARG MIN\n%s ge "$MIN"\n' "$ASSERT_PREFIX" > "$d/Dockerfile"
has "assertion-against-a-variable-is-not-proof" "$(audit "$d")" '^FLAG Dockerfile: '

d="$(newrepo apt-pin)"
printf 'FROM debian:12\nRUN apt-get update && apt-get install -y ca-certificates=20250419~deb12u2\n' > "$d/Dockerfile"
has "apt-pin-to-a-fixed-version-is-clear" "$(audit "$d")" '^CLEAR Dockerfile: '

d="$(newrepo apt-pin-old)"
printf 'FROM debian:12\nRUN apt-get update && apt-get install -y ca-certificates=20230311\n' > "$d/Dockerfile"
has "apt-pin-to-an-old-version-is-not-clear" "$(audit "$d")" '^UNCONFIRMED Dockerfile: '

d="$(newrepo apk)"
printf 'FROM alpine:3.22\nRUN apk add --no-cache ca-certificates=20261020-r0\n' > "$d/Dockerfile"
printf 'FROM cgr.dev/chainguard/wolfi-base\nRUN apk add --no-cache "ca-certificates>=20260909-r3"\n' > "$d/Dockerfile.wolfi"
printf 'FROM alpine:3.22\nRUN apk add --no-cache curl\n' > "$d/Dockerfile.old"
out="$(audit "$d")"
has "apk-pin-is-clear" "$out" '^CLEAR Dockerfile: .*20261020-r0'
has "apk-at-least-is-clear" "$out" '^CLEAR Dockerfile\.wolfi: '
has "apk-image-lists-apk-versions" "$out" '^FLAG Dockerfile\.old: .*move to ca-certificates 20261020-r0, 20260909-r3'

d="$(newrepo scratch)"
printf 'FROM scratch\nCOPY app /app\n' > "$d/Dockerfile"
out="$(audit "$d")"
has "from-scratch-is-not-assessed" "$out" '^NOT ASSESSED Dockerfile: '
lacks "from-scratch-is-not-flagged" "$out" '^(FLAG|UNCONFIRMED) '

d="$(newrepo scratch-final)"
printf 'FROM golang:1.26 AS build\n%s ge 20250419~deb12u2\nFROM scratch\nCOPY --from=build /app /app\n' "$ASSERT_PREFIX" > "$d/Dockerfile"
has "scratch-final-stage-leaves-the-patched-build-stage-clear" "$(audit "$d")" '^CLEAR Dockerfile: '

d="$(newrepo naming)"
mkdir -p "$d/svc/deep" "$d/node_modules/pkg" "$d/.git"
for f in "svc/deep/api.Dockerfile" "svc/web.dockerfile" "Containerfile" "svc/Containerfile.prod"; do
  printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/$f"
done
printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/node_modules/pkg/Dockerfile"
printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/.git/Dockerfile"
out="$(audit "$d")"
for f in "svc/deep/api.Dockerfile" "svc/web.dockerfile" "Containerfile" "svc/Containerfile.prod"; do
  has "audits-$f" "$out" "^FLAG $f: "
done
lacks "skips-node_modules-for-dockerfiles" "$out" 'node_modules'
lacks "skips-dot-git" "$out" '\.git'

d="$(newrepo bundles)"
mkdir -p "$d/certs" "$d/node_modules/dep/data" "$d/vendor"
cp "$FIXTURES/aaa-certificate-services.pem" "$d/certs/bundle.pem"
cp "$FIXTURES/synthetic-test-ca.pem" "$d/certs/unlisted.pem"
cat "$FIXTURES/synthetic-test-ca.pem" "$FIXTURES/aaa-certificate-services.pem" > "$d/node_modules/dep/data/cacert.pem"
body="$(sed -e '1d;$d' "$FIXTURES/aaa-certificate-services.pem" | tr '\n' ' ' | sed 's/ /\\n/g')"
printf '{"ca":"-----BEGIN CERTIFICATE-----\\n%s-----END CERTIFICATE-----\\n"}\n' "$body" > "$d/vendor/embedded.json"
out="$(audit "$d")"
has "bundle-holding-the-aaa-root-is-flagged" "$out" '^FLAG certs/bundle\.pem: contains AAA Certificate Services \(root\); replace the bundle or point the library at the system store'
lacks "bundle-without-a-listed-cert-has-no-finding" "$out" 'unlisted\.pem'
has "bundle-inside-node_modules-is-flagged" "$out" '^FLAG node_modules/dep/data/cacert\.pem: contains AAA Certificate Services'
has "pem-embedded-in-json-is-flagged" "$out" '^FLAG vendor/embedded\.json: contains AAA Certificate Services'
lacks "never-advises-removing-a-root" "$out" '[Rr]emov'
has "bundle-findings-leave-the-verdict-flagged" "$out" '^Verdict: FLAGGED$'

d="$(newrepo bundle-clean)"
cp "$FIXTURES/synthetic-test-ca.pem" "$d/ca.pem"
out="$(audit "$d")"
has "unlisted-bundle-reports-clear-without-naming-it" "$out" '^CLEAR certificate bundles: 1 PEM file\(s\) scanned, none contains a listed certificate$'
has "unlisted-bundle-verdict-is-clear" "$out" '^Verdict: CLEAR$'

d="$(newrepo keystores)"
: > "$d/trust.jks"; : > "$d/store.p12"; mkdir -p "$d/lib"; : > "$d/lib/cacerts"
has "binary-keystores-are-counted-under-not-checked" "$(audit "$d")" '^Not checked: .*binary keystores \(3 found: '

d="$(newrepo empty)"
out="$(audit "$d")"
has "empty-repo-is-clear" "$out" '^Verdict: CLEAR$'
has "empty-repo-says-nothing-was-found" "$out" '^CLEAR container build files: none found$'

d="$(newrepo hostile)"
mkdir -p "$d/a"$'\n'"CLEAR fake-subject"
printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/a"$'\n'"CLEAR fake-subject/Dockerfile"
printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/evil"$'\x01'"name.Dockerfile"
out="$(audit "$d")"
lacks "a-path-with-a-newline-cannot-forge-a-report-line" "$out" '^CLEAR fake-subject'
lacks "control-characters-in-paths-are-not-printed" "$out" "$(printf '[\001]')"
has "hostile-paths-are-still-audited" "$out" '^FLAG '

printf 'FROM debian:12\r\nRUN apt-get install -y ca-certificates \\\r\n  curl\r\n' > "$(newrepo crlf)/Dockerfile"
has "crlf-dockerfile-is-parsed" "$(audit "$tmp/crlf")" '^UNCONFIRMED Dockerfile: '

d="$(newrepo relative)"
printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/Dockerfile"
out="$(cd "$tmp" && "$SCRIPT" repo relative)"
has "relative-directory-is-reported-as-an-absolute-path" "$out" "^CA distrust audit \\(read-only\\): repo $tmp/relative\$"

rc=0; "$SCRIPT" repo "$tmp/does-not-exist" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "missing-directory-exits-2" || bad "missing-directory-exits-2" "exit $rc"
rc=0; "$SCRIPT" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "no-arguments-exits-2" || bad "no-arguments-exits-2" "exit $rc"
rc=0; "$SCRIPT" repo > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "repo-without-a-directory-exits-2" || bad "repo-without-a-directory-exits-2" "exit $rc"
rc=0; CA_AUDIT_DATA_DIR="$tmp/no-data" "$SCRIPT" repo "$tmp/empty" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "no-data-files-exits-2" || bad "no-data-files-exits-2" "exit $rc"

exit "$fail"
