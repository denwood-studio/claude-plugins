#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="${CA_AUDIT_PLUGIN_DIR:-$REPO/plugins/ca-distrust-audit}"
SCRIPT="$PLUGIN/scripts/audit.sh"
FIXTURES="$REPO/tests/ca-distrust-audit/fixtures"
DATA="$PLUGIN/data/emudhra-2026-10.tsv"
tmp="$(mktemp -d)"
trap 'chmod -R u+rwx "$tmp" 2> /dev/null; rm -rf "$tmp"' EXIT

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
printf 'FROM registry.example.invalid/base:1\nRUN dnf -y update\n' > "$d/Containerfile"
out="$(audit "$d")"
has "apt-full-upgrade-is-unconfirmed" "$out" '^UNCONFIRMED Dockerfile: '
has "dnf-update-on-an-unclassified-image-is-unconfirmed" "$out" '^UNCONFIRMED Containerfile: '

d="$(newrepo rpm)"
printf 'FROM fedora:44\nRUN dnf -y update\n' > "$d/Containerfile"
printf 'FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4\nRUN microdnf install -y ca-certificates\n' > "$d/Dockerfile"
printf 'FROM rockylinux:9 AS base\nRUN echo base\nFROM base AS app\nRUN echo app\n' > "$d/Dockerfile.rocky"
printf 'FROM public.ecr.aws/amazonlinux/amazonlinux:2023\nRUN dnf install -y curl\n' > "$d/Dockerfile.al"
printf 'FROM ubuntu:24.04\nRUN apt-get install -y curl\n' > "$d/Dockerfile.ubuntu"
out="$(audit "$d")"
has "rpm-image-is-unconfirmed-and-names-the-from-image" "$out" '^UNCONFIRMED Containerfile: stage FROM fedora:44 is an RPM-family image'
has "ubi-image-is-unconfirmed" "$out" '^UNCONFIRMED Dockerfile: stage FROM registry\.access\.redhat\.com/ubi9/ubi-minimal:9\.4 '
has "rocky-image-is-unconfirmed-once-for-its-stages" "$out" '^UNCONFIRMED Dockerfile\.rocky: stage FROM rockylinux:9 '
[ "$(printf '%s\n' "$out" | grep -c '^UNCONFIRMED Dockerfile\.rocky: ')" -eq 1 ] && pass "rpm-parent-stage-is-reported-once" || bad "rpm-parent-stage-is-reported-once" "not exactly one line"
has "amazonlinux-image-is-unconfirmed" "$out" '^UNCONFIRMED Dockerfile\.al: stage FROM public\.ecr\.aws/amazonlinux/amazonlinux:2023 '
lacks "rpm-image-is-not-flagged" "$out" '^FLAG (Containerfile|Dockerfile|Dockerfile\.rocky|Dockerfile\.al): '
lacks "rpm-image-gets-no-dpkg-advice" "$out" '^UNCONFIRMED (Containerfile|Dockerfile|Dockerfile\.rocky|Dockerfile\.al): .*(dpkg-query|move to ca-certificates)'
has "ubuntu-is-not-mistaken-for-an-rpm-image" "$out" '^FLAG Dockerfile\.ubuntu: '
has "rpm-families-are-listed-under-not-checked" "$out" '^Not checked: .*RPM-family base images \(UBI, RHEL, CentOS, Fedora, '

d="$(newrepo rpm-only)"
printf 'FROM fedora:44\nRUN dnf -y install ca-certificates\n' > "$d/Dockerfile"
out="$(audit "$d")"
has "rpm-only-repo-reports-unconfirmed" "$out" '^UNCONFIRMED Dockerfile: stage FROM fedora:44 '
lacks "rpm-only-repo-is-not-reported-as-having-no-build-files" "$out" '^CLEAR container build files: none found$'
lacks "rpm-image-is-never-clear-evidence" "$out" '^CLEAR Dockerfile'
has "rpm-only-repo-verdict-is-unconfirmed" "$out" '^Verdict: UNCONFIRMED$'
lacks "rpm-only-repo-verdict-is-not-clear" "$out" '^Verdict: CLEAR$'

d="$(newrepo rpm-and-debian)"
printf 'FROM debian:12 AS build\nRUN apt-get install -y curl\nFROM fedora:44\nRUN echo hi\n' > "$d/Dockerfile"
out="$(audit "$d")"
has "debian-stage-next-to-an-rpm-stage-is-still-assessed" "$out" '^FLAG Dockerfile: stage FROM debian:12 '
has "rpm-stage-next-to-a-debian-stage-is-unconfirmed" "$out" '^UNCONFIRMED Dockerfile: stage FROM fedora:44 '

d="$(newrepo rpm-and-clear)"
printf 'FROM debian:12 AS build\n%s %s\nFROM fedora:44\nRUN echo hi\n' "$ASSERT_PREFIX" "$CHECK" > "$d/Dockerfile"
has "rpm-stage-next-to-a-clear-stage-holds-the-verdict" "$(audit "$d")" '^Verdict: UNCONFIRMED$'
has "clear-next-to-an-rpm-stage-says-so" "$(audit "$d")" '^CLEAR Dockerfile: .*; stages built on an RPM-family image are not assessed$'

d="$(newrepo rpm-token-in-org-path)"
printf 'FROM ghcr.io/photon-labs/api:bookworm\nRUN apt-get update && apt-get install -y curl\n' > "$d/Dockerfile"
printf 'FROM registry.example.invalid/redhat-tools/runner:1\nRUN apk add --no-cache curl\n' > "$d/Dockerfile.apk"
printf 'FROM ghcr.io/photon-labs/api:bookworm AS base\nRUN apt-get install -y curl\nFROM base AS app\nRUN echo app\n' > "$d/Dockerfile.stages"
out="$(audit "$d")"
has "rpm-token-in-an-org-path-with-apt-is-flagged" "$out" '^FLAG Dockerfile: stage FROM ghcr\.io/photon-labs/api:bookworm '
has "rpm-token-in-an-org-path-with-apk-is-flagged" "$out" '^FLAG Dockerfile\.apk: '
has "rpm-token-in-an-org-path-with-apt-in-the-parent-stage-is-flagged" "$out" '^FLAG Dockerfile\.stages: '
lacks "rpm-token-in-an-org-path-is-not-called-rpm" "$out" 'RPM-family image'
lacks "rpm-token-in-an-org-path-never-reads-clear" "$out" '^Verdict: CLEAR$'

d="$(newrepo rpm-token-child-of-a-patched-apt-stage)"
printf 'FROM ghcr.io/photon-labs/api:bookworm AS base\nRUN apt-get update && apt-get install -y ca-certificates=20250419~deb12u2\nFROM base AS app\nRUN echo app\n' > "$d/Dockerfile"
out="$(audit "$d")"
has "child-of-a-patched-apt-stage-on-an-rpm-token-image-is-clear" "$out" '^CLEAR Dockerfile: ca-certificates is asserted at a fixed version \(20250419~deb12u2\)$'
lacks "child-of-an-apt-stage-on-an-rpm-token-image-is-not-called-rpm" "$out" 'RPM-family image'

d="$(newrepo rpm-token-apt-in-the-child-stage-only)"
printf 'FROM ghcr.io/photon-labs/api:bookworm AS base\nRUN echo base\nFROM base AS app\nRUN apt-get update && apt-get install -y curl\n' > "$d/Dockerfile"
has "unpatched-apt-in-a-child-stage-only-on-an-rpm-token-image-is-flagged" "$(audit "$d")" '^FLAG Dockerfile: '

d="$(newrepo rpm-token-apt-in-the-grandchild-stage-only)"
printf 'FROM ghcr.io/photon-labs/api:bookworm AS base\nRUN echo base\nFROM base AS mid\nRUN echo mid\nFROM mid AS app\nRUN apt-get update && apt-get install -y curl\n' > "$d/Dockerfile"
out="$(audit "$d")"
has "unpatched-apt-in-a-grandchild-stage-only-on-an-rpm-token-image-is-flagged" "$out" '^FLAG Dockerfile: stage FROM ghcr\.io/photon-labs/api:bookworm '
lacks "apt-in-a-grandchild-stage-keeps-the-rpm-token-root-from-being-called-rpm" "$out" 'RPM-family image'

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

has "pem-scan-completed-reports-no-scan-failure" "$out" '^FLAG '
lacks "complete-scan-has-no-unconfirmed" "$out" '^UNCONFIRMED '

d="$(newrepo bundle-clean)"
cp "$FIXTURES/synthetic-test-ca.pem" "$d/ca.pem"
out="$(audit "$d")"
has "unlisted-bundle-reports-clear-without-naming-it" "$out" '^CLEAR certificate bundles: 1 PEM file\(s\) scanned, none contains a listed certificate$'
has "unlisted-bundle-verdict-is-clear" "$out" '^Verdict: CLEAR$'

d="$(newrepo bundles-with-a-fake-grep)"
cp "$FIXTURES/aaa-certificate-services.pem" "$d/bundle.pem"
printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/Dockerfile"
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\necho "grep: unrecognized option: --null" >&2\nexit 2\n' > "$tmp/fakebin/grep"
printf '#!/bin/sh\necho "xargs: invalid option -- 0" >&2\nexit 2\n' > "$tmp/fakebin/xargs"
chmod +x "$tmp/fakebin/grep" "$tmp/fakebin/xargs"
real="$(audit "$d")"
fake="$(PATH="$tmp/fakebin:$PATH" "$SCRIPT" repo "$d")"
[ "$real" = "$fake" ] && pass "report-ignores-a-non-conforming-grep-and-xargs-on-the-users-path" || bad "report-ignores-a-non-conforming-grep-and-xargs-on-the-users-path" "reports differ"
has "bundle-is-flagged-with-a-non-conforming-grep-first-on-path" "$fake" '^FLAG bundle\.pem: contains AAA Certificate Services'
if grep -nE 'xargs|--null|-print0|-lI' "$SCRIPT" > "$tmp/portability.out"; then
  bad "script-uses-no-xargs-or-non-posix-find-or-grep-options" "$(cat "$tmp/portability.out")"
else
  pass "script-uses-no-xargs-or-non-posix-find-or-grep-options"
fi
greps="$(grep -n 'grep' "$SCRIPT")"
if [ "$(printf '%s\n' "$greps" | grep -c .)" -eq 1 ] && printf '%s\n' "$greps" | grep -qF "grep -l -F -e \"\$0\" \"\$@\" || [ \$? -eq 1 ]"; then
  pass "the-only-grep-call-uses-posix-options-and-keeps-exit-status-2"
else
  bad "the-only-grep-call-uses-posix-options-and-keeps-exit-status-2" "$greps"
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "PASS [unreadable-directory-tests-skipped] skipped: root reads every directory"
else
  d="$(newrepo unreadable)"
  printf 'FROM debian:12\n%s %s\n' "$ASSERT_PREFIX" "$CHECK" > "$d/Dockerfile"
  mkdir -p "$d/locked"
  cp "$FIXTURES/aaa-certificate-services.pem" "$d/locked/bundle.pem"
  printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/locked/Dockerfile.dev"
  chmod 000 "$d/locked"
  out="$(audit "$d")"; rc=$?
  chmod 755 "$d/locked"
  [ "$rc" -eq 0 ] && pass "unreadable-directory-still-exits-0" || bad "unreadable-directory-still-exits-0" "exit $rc"
  has "unreadable-directory-leaves-the-pem-scan-unconfirmed" "$out" '^UNCONFIRMED certificate bundles: .*did not complete'
  has "unreadable-directory-leaves-the-dockerfile-search-unconfirmed" "$out" '^UNCONFIRMED container build files: .*did not complete'
  lacks "unreadable-directory-is-never-clear-for-bundles" "$out" '^CLEAR certificate bundles'
  lacks "unreadable-directory-is-never-clear-for-build-files-it-hid" "$out" '^CLEAR container build files: none found'
  has "unreadable-directory-verdict-is-unconfirmed" "$out" '^Verdict: UNCONFIRMED$'
  has "findings-from-readable-files-are-kept-when-the-scan-is-incomplete" "$out" '^CLEAR Dockerfile: '

  d="$(newrepo unreadable-file)"
  printf 'FROM debian:12\n%s %s\n' "$ASSERT_PREFIX" "$CHECK" > "$d/Dockerfile"
  cp "$FIXTURES/aaa-certificate-services.pem" "$d/hidden.pem"
  chmod 000 "$d/hidden.pem"
  out="$(audit "$d")"
  chmod 644 "$d/hidden.pem"
  has "unreadable-file-leaves-the-pem-scan-unconfirmed" "$out" '^UNCONFIRMED certificate bundles: .*did not complete'
  lacks "unreadable-file-is-never-clear-for-bundles" "$out" '^CLEAR certificate bundles'
  has "unreadable-file-verdict-is-unconfirmed" "$out" '^Verdict: UNCONFIRMED$'

  d="$(newrepo unreadable-dockerfile-between-readable-ones)"
  mkdir -p "$d/a" "$d/b"
  for f in a/Dockerfile a/Dockerfile.x b/Dockerfile; do
    printf 'FROM debian:12\nRUN apt-get install -y curl\n' > "$d/$f"
  done
  chmod 000 "$d/a/Dockerfile.x"
  out="$(audit "$d")"
  chmod 644 "$d/a/Dockerfile.x"
  has "readable-dockerfile-before-an-unreadable-one-is-still-flagged" "$out" '^FLAG a/Dockerfile: '
  has "readable-dockerfile-after-an-unreadable-one-is-still-flagged" "$out" '^FLAG b/Dockerfile: '
  has "unreadable-dockerfile-leaves-the-readable-flags-in-the-verdict" "$out" '^Verdict: FLAGGED$'
fi

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
