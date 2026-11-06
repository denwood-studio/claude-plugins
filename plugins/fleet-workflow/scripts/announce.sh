#!/usr/bin/env bash
[ -n "${ORCH_HOOK_PORT:-}" ] || exit 0
args=()
for pair in "$@"; do args+=(--data-urlencode "$pair"); done
curl -s -m 1 -G "http://127.0.0.1:$ORCH_HOOK_PORT/announce" \
  -H "x-orch-token: ${ORCH_HOOK_TOKEN:-}" \
  --data-urlencode "session=${ORCH_SESSION_ID:-}" \
  --data-urlencode "contract=1" \
  "${args[@]}" >/dev/null 2>&1
exit 0
