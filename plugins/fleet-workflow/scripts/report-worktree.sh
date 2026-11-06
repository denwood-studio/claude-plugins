#!/usr/bin/env bash
[ -n "${ORCH_HOOK_PORT:-}" ] || exit 0
curl -s -m 1 -G "http://127.0.0.1:$ORCH_HOOK_PORT/worktree" \
  -H "x-orch-token: ${ORCH_HOOK_TOKEN:-}" \
  --data-urlencode "session=${ORCH_SESSION_ID:-}" \
  --data-urlencode "path=${1:-}" >/dev/null 2>&1
exit 0
