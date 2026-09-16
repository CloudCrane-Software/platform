#!/usr/bin/env bash
# edge-recovery.sh — bring the governance base stack back after a host reboot
# (manual §9 ops, edge colocation ADR 0004). Idempotent.
#   1. docker compose up (443 race-safe: retry caddy)
#   2. OpenBao unseal (key from the HOST vault: secret/cloudcrane/base-stack)
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

# unseal bao from the host vault (VAULT_TOKEN=root)
export VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true
VT=$(cat /etc/vault/root-token 2>/dev/null) || { echo "no host vault token"; exit 1; }
UK=$(VAULT_TOKEN="$VT" vault kv get -field=bao_unseal_key secret/cloudcrane/base-stack 2>/dev/null) || { echo "no unseal key in vault"; exit 1; }
docker exec -e BAO_ADDR=http://127.0.0.1:8200 company-bao-1 bao operator unseal "$UK" >/dev/null 2>&1 \
  && echo "bao: unsealed" || echo "bao: unseal failed (already unsealed?)"
unset UK VT

sleep 10
bash "$ROOT/ops/scripts/healthcheck-edge.sh" 2>/dev/null || \
  docker ps --format '{{.Names}}\t{{.Status}}' | sort
