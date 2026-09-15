#!/usr/bin/env bash
# bao-unseal.sh — unseal OpenBao after a host/container restart.
# Reads the unseal key from the terminal (hidden) or stdin; never argv.
#   interactive: bash ops/scripts/bao-unseal.sh
#   piped:       echo "$KEY" | bash ops/scripts/bao-unseal.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/ops/compose/docker-compose.yml" --env-file "$ROOT/ops/compose/.env")

if [[ -t 0 ]]; then
    read -rsp "OpenBao unseal key: " KEY; echo >&2
else
    read -r KEY
fi
[[ -n "$KEY" ]] || { echo "empty key" >&2; exit 1; }

printf '%s' "$KEY" | "${COMPOSE[@]}" exec -T bao bao operator unseal >/dev/null
"${COMPOSE[@]}" exec -T bao bao status | grep -E "Initialized|Sealed|Total Shares|Version"
echo "unsealed."
