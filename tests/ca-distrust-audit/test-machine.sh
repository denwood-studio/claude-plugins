#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="${CA_AUDIT_PLUGIN_DIR:-$REPO/plugins/ca-distrust-audit}"
SCRIPT="$PLUGIN/scripts/audit.sh"
DATA="$PLUGIN/data/emudhra-2026-10.tsv"

if [ "$(uname -s)" != Darwin ]; then
  echo "PASS [machine-mode-skipped] skipped: machine mode runs on macOS only"
  exit 0
fi

tmp="$(cd "$(mktemp -d)" && pwd -P)"
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

mkdir -p "$tmp/home"

fake_node() {
  mkdir -p "$tmp/$1"
  printf '#!/bin/sh\necho %s\n' "$2" > "$tmp/$1/node"
  chmod +x "$tmp/$1/node"
}

fake_app() {
  local fw="$tmp/apps/$1.app/Contents/Frameworks/Electron Framework.framework/Resources"
  mkdir -p "$fw"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleVersion</key><string>%s</string></dict></plist>\n' "$2" > "$fw/Info.plist"
}

fake_node n-old24 v24.9.0
fake_node n-old25 v25.9.0
fake_node n-fixed26 v26.12.1
fake_node n-new27 v27.0.0
fake_node n-old22 v22.16.0
fake_node shims v10.0.0
fake_node n-unreadable 'not a version'
mkdir -p "$tmp/n-envcheck"
printf '#!/bin/sh\nprintf "%%s\\n" "$0" >> "%s/argv0.log"\nif [ -n "${HOME:-}" ] || [ -n "${ZZ_PROBE:-}" ]; then echo v1.0.0; else echo v26.12.1; fi\n' "$tmp" > "$tmp/n-envcheck/node"
chmod +x "$tmp/n-envcheck/node"
mkdir -p "$tmp/n-link"
ln -s "$tmp/n-old24/node" "$tmp/n-link/node"
mkdir -p "$tmp/home/.volta/bin"
printf '#!/bin/sh\necho v1.1.0\n' > "$tmp/home/.volta/bin/node"
chmod +x "$tmp/home/.volta/bin/node"
mkdir -p "$tmp/home/.local/share/mise/installs/node/22.5.0/bin"
printf '#!/bin/sh\necho v22.5.0\n' > "$tmp/home/.local/share/mise/installs/node/22.5.0/bin/node"
chmod +x "$tmp/home/.local/share/mise/installs/node/22.5.0/bin/node"

fake_app Alpha 39.8.3
fake_app Beta 43.8.3
fake_app Gamma 43.1.1
fake_app "Two Words" 45.2.1
mkdir -p "$tmp/apps/Plain.app/Contents" "$tmp/apps/Broken.app/Contents/Frameworks/Electron Framework.framework/Resources"
printf 'garbage\n' > "$tmp/apps/Broken.app/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"

NODE_DIRS="$tmp/n-old24:$tmp/n-old25:$tmp/n-fixed26:$tmp/n-new27:$tmp/n-old22:$tmp/shims:$tmp/n-unreadable:$tmp/n-envcheck:$tmp/n-link"

machine() {
  env HOME="$tmp/home" PATH=/usr/bin:/bin CA_AUDIT_NODE_DIRS="$NODE_DIRS" CA_AUDIT_APP_DIRS="$tmp/apps" \
    CA_AUDIT_MACOS_VERSION="$1" "$SCRIPT" machine
}

asof="$(awk -F'\t' '$1 == "as-of" { print $2 }' "$DATA")"

out="$(machine 26.7.3)"; rc=$?
[ "$rc" -eq 0 ] && pass "exit-0-on-a-flagged-audit" || bad "exit-0-on-a-flagged-audit" "exit $rc"
has "node-v24.9.0-moves-to-24.22.1" "$out" "^FLAG $tmp/n-old24/node: Node 24\\.9\\.0 .* move to 24\\.22\\.1\$"
has "node-v25.9.0-moves-to-26.12.1" "$out" "^FLAG $tmp/n-old25/node: Node 25\\.9\\.0 .* move to 26\\.12\\.1\$"
has "node-v22.16.0-moves-to-22.23.4" "$out" "^FLAG $tmp/n-old22/node: Node 22\\.16\\.0 .* move to 22\\.23\\.4\$"
has "node-v26.12.1-is-clear" "$out" "^CLEAR $tmp/n-fixed26/node: "
has "node-v27.0.0-is-clear" "$out" "^CLEAR $tmp/n-new27/node: "
lacks "shim-directory-node-is-not-reported" "$out" "$tmp/shims"
lacks "volta-shim-is-not-reported" "$out" '\.volta/bin/node'
has "mise-install-dir-is-scanned" "$out" "^FLAG $tmp/home/\\.local/share/mise/installs/node/22\\.5\\.0/bin/node: Node 22\\.5\\.0 .* move to 22\\.23\\.4\$"
has "unreadable-node-version-is-unconfirmed" "$out" "^UNCONFIRMED $tmp/n-unreadable/node: "
has "node-runs-under-env-i" "$out" "^CLEAR $tmp/n-envcheck/node: "
if [ -s "$tmp/argv0.log" ] && ! grep -qv '^/' "$tmp/argv0.log"; then pass "node-runs-by-absolute-path"; else bad "node-runs-by-absolute-path" "argv0: $(cat "$tmp/argv0.log" 2>/dev/null)"; fi
n24="$(printf '%s\n' "$out" | grep -c '^FLAG .*Node 24\.9\.0')"
[ "$n24" -eq 1 ] && pass "a-symlinked-node-is-listed-once" || bad "a-symlinked-node-is-listed-once" "listed $n24 times"

has "electron-39.8.3-moves-to-42.11.16" "$out" '^FLAG Alpha: Electron 39\.8\.3 .* update Alpha to a release built on Electron ≥ 42\.11\.16$'
has "electron-43.1.1-moves-to-43.8.1" "$out" '^FLAG Gamma: Electron 43\.1\.1 .* update Gamma to a release built on Electron ≥ 43\.8\.1$'
has "electron-43.8.3-is-clear" "$out" '^CLEAR Beta: '
has "electron-45.2.1-is-clear" "$out" '^CLEAR Two Words: '
has "electron-with-an-unreadable-plist-is-unconfirmed" "$out" '^UNCONFIRMED Broken: '
lacks "app-without-electron-is-not-reported" "$out" 'Plain'
has "fixed-macos-is-clear" "$out" '^CLEAR macOS: macOS 26\.7\.3 '
has "report-opens-with-the-read-only-header" "$out" '^CA distrust audit \(read-only\): machine$'
has "report-states-the-list-date" "$out" "^Checked against: .* — fixed-version list as of $asof \\(https://"
has "report-has-a-not-checked-line" "$out" '^Not checked: Homebrew/Python/pip/certifi stores; Java keystores; Go/Rust binaries; Docker Desktop and images; browsers; apps outside /Applications and ~/Applications; apps that patch their own store$'
has "report-ends-with-a-verdict" "$out" '^Verdict: FLAGGED$'

has "macos-26.4.1-moves-to-26.7.3" "$(machine 26.4.1)" '^FLAG macOS: macOS 26\.4\.1 .* move to 26\.7\.3$'
has "macos-14.7-moves-to-15.8.3" "$(machine 14.7)" '^FLAG macOS: macOS 14\.7 .* move to 15\.8\.3$'
has "macos-15.2-moves-to-15.8.3" "$(machine 15.2)" '^FLAG macOS: macOS 15\.2 .* move to 15\.8\.3$'
has "macos-27.0-moves-to-27.2.1" "$(machine 27.0)" '^FLAG macOS: macOS 27\.0 .* move to 27\.2\.1$'
has "macos-27.3-is-clear" "$(machine 27.3)" '^CLEAR macOS: '

rc=0; "$SCRIPT" machine extra > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "machine-with-an-extra-argument-exits-2" || bad "machine-with-an-extra-argument-exits-2" "exit $rc"

exit "$fail"
