#!/usr/bin/env bash
# edge-recovery.sh — bring the governance base stack back after a host reboot
# (manual §9 ops, edge colocation ADR 0004). Idempotent.
#   1. docker compose up (443 race-safe: retry caddy)
#   2. OpenBao unseal (file escrow /etc/bao/unseal-key; ADR 0006)
#   3. health snapshot
set -uo pipefail
ROOT="/opt/company/platform"
CDC="$ROOT/ops/compose"
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.edge.yml --env-file .env)

cd "$CDC" || exit 1
"${COMPOSE[@]}" up -d || true
for i in 1 2 3; do
  sleep 3
  docker ps --format '{{.Names}}' | grep -q '^company-caddy-1$' && break
  "${COMPOSE[@]}" up -d caddy >/dev/null 2>&1
done

# unseal bao from the file escrow /etc/bao/unseal-key (ADR 0006, owner
# decision 2026-09-19). The legacy host-vault fallback was REMOVED:
# /etc/vault does not exist on this host (dead path); escrow is 0600 root-only.
if [ -s /etc/bao/unseal-key ]; then
  UK=$(cat /etc/bao/unseal-key)
else
  echo "no unseal key escrow at /etc/bao/unseal-key (see ADR 0006)" >&2
  exit 1
fi
docker exec -e BAO_ADDR=http://127.0.0.1:8200 company-bao-1 bao operator unseal "$UK" >/dev/null 2>&1 \
  && echo "bao: unsealed" || echo "bao: unseal failed (already unsealed?)"
unset UK

sleep 10
bash "$ROOT/ops/scripts/healthcheck-edge.sh" 2>/dev/null || \
  docker ps --format '{{.Names}}\t{{.Status}}' | sort
