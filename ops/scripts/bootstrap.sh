#!/usr/bin/env bash
# bootstrap.sh — one-shot base stack bring-up (manual §4.2).
#
# What it does (idempotent — safe to re-run):
#   1. Generates ops/compose/.env from .env.example with random secrets
#      (only if .env does not exist). Aborts if DOMAIN is still a placeholder.
#   2. Hashes the Zot password with bcrypt (via the Caddy image).
#   3. Creates /opt/company/data/* directories.
#   4. docker compose pull + up -d --wait (all containers healthy).
#   5. Initializes OpenBao on first run (prints unseal key + root token to the
#      TERMINAL ONLY — they are never written to a file), enables transit,
#      creates ed25519 keys `eval-signer` and `human-signer`.
#   6. Provisions Kafka topics (via kafka-init service).
#   7. Prints the health table and the "secrets to store" checklist.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_DIR="$ROOT/ops/compose"
ENV_FILE="$COMPOSE_DIR/.env"
ENV_TPL="$COMPOSE_DIR/.env.example"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE")

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin missing"

# ---------------------------------------------------------------- 1. .env --
if [[ ! -f "$ENV_FILE" ]]; then
    log "generating $ENV_FILE from template"
    cp "$ENV_TPL" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    gen() { openssl rand -hex "$1"; }
    sed -i \
        -e "s|__GEN_PG_SUPER__|$(gen 16)|g" \
        -e "s|__GEN_PG_KERNEL__|$(gen 16)|g" \
        -e "s|__GEN_PG_LITELLM__|$(gen 16)|g" \
        -e "s|__GEN_PG_LANGFUSE__|$(gen 16)|g" \
        -e "s|__GEN_LITELLM_MASTER__|sk-$(gen 24)|g" \
        -e "s|__GEN_ZOT_PASSWORD__|$(gen 12)|g" \
        -e "s|__GEN_NEXTAUTH_SECRET__|$(gen 16)|g" \
        -e "s|__GEN_LF_ENCRYPTION__|$(gen 32)|g" \
        -e "s|__GEN_LF_SALT__|$(gen 8)|g" \
        -e "s|__GEN_CLICKHOUSE_PASSWORD__|$(gen 12)|g" \
        -e "s|__GEN_REDIS_AUTH__|$(gen 12)|g" \
        -e "s|__GEN_MINIO_ROOT_PASSWORD__|$(gen 12)|g" \
        "$ENV_FILE"
    log "secrets generated"
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

[[ "$DOMAIN" != "example.com" ]] || die "edit $ENV_FILE: set DOMAIN (and ACME_EMAIL) to your real domain first"
[[ "$ACME_EMAIL" != "admin@example.com" ]] || die "edit $ENV_FILE: set ACME_EMAIL to your real email first"

if [[ "$NEXTAUTH_URL" == "https://langfuse.example.com" ]]; then
    sed -i "s|^NEXTAUTH_URL=.*|NEXTAUTH_URL=https://langfuse.${DOMAIN}|" "$ENV_FILE"
    NEXTAUTH_URL="https://langfuse.${DOMAIN}"
fi

# ------------------------------------------------- 2. zot bcrypt via caddy --
if [[ "$ZOT_PASS_BCRYPT" == __GEN_ZOT_BCRYPT__* ]]; then
    log "hashing zot password (bcrypt) via caddy image"
    HASH="$("${COMPOSE[@]}" run --rm --quiet-pull --entrypoint caddy caddy hash-password --plaintext "$ZOT_PASSWORD" | tr -d '\n')"
    [[ "$HASH" == \$2b\* || "$HASH" == \$2a\* ]] || die "bcrypt hash generation failed"
    sed -i "s|^ZOT_PASS_BCRYPT=.*|ZOT_PASS_BCRYPT=$HASH|" "$ENV_FILE"
    log "zot bcrypt written to .env"
fi

# ------------------------------------------------------------- 3. dirs -----
for d in pg restate kafka bao zot clickhouse minio redis; do
    mkdir -p "/opt/company/data/$d"
done
mkdir -p /opt/company/backups

# --------------------------------------------------------- 4. compose up ---
log "pulling images"
"${COMPOSE[@]}" pull --quiet
log "starting stack (waiting for health)"
"${COMPOSE[@]}" up -d --wait
log "all containers up"

# ----------------------------------------------------------- 5. OpenBao ----
log "checking OpenBao initialization state"
BAO_INIT_JSON="$("${COMPOSE[@]}" exec -T bao bao operator init -key-shares=1 -key-threshold=1 -format=json 2>/dev/null || true)"
if [[ -n "$BAO_INIT_JSON" ]]; then
    UNSEAL_KEY="$(printf '%s' "$BAO_INIT_JSON" | sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)".*/\1/p')"
    BAO_ROOT="$(printf '%s' "$BAO_INIT_JSON" | sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p')"
    printf '\033[1;31m==============================================================\033[0m\n'
    printf '\033[1;31m  STORE THESE IN YOUR PASSWORD MANAGER NOW (terminal-only)\033[0m\n'
    printf '\033[1;31m  OpenBao unseal key : %s\033[0m\n' "$UNSEAL_KEY"
    printf '\033[1;31m  OpenBao root token : %s\033[0m\n' "$BAO_ROOT"
    printf '\033[1;31m==============================================================\033[0m\n'
    printf 'These values are NOT written to any file. If lost, Bao data is unrecoverable.\n'
    unset BAO_INIT_JSON
else
    log "OpenBao already initialized (or sealed) — skipping init"
    BAO_ROOT=""
fi

# If sealed (fresh boot of an initialized bao), ask operator to unseal now.
SEALED="$("${COMPOSE[@]}" exec -T bao bao status 2>/dev/null | grep -c 'Sealed.*true' || true)"
if [[ "$SEALED" == "1" ]]; then
    warn "OpenBao is SEALED. Run ops/scripts/bao-unseal.sh now (needs the unseal key), then re-run bootstrap."
fi

if [[ -n "$BAO_ROOT" ]]; then
    log "enabling transit engine + signing keys (eval-signer, human-signer)"
    "${COMPOSE[@]}" exec -T -e BAO_TOKEN="$BAO_ROOT" bao bao secrets list >/dev/null
    "${COMPOSE[@]}" exec -T -e BAO_TOKEN="$BAO_ROOT" bao bao secrets enable transit 2>/dev/null \
        || log "transit already enabled"
    "${COMPOSE[@]}" exec -T -e BAO_TOKEN="$BAO_ROOT" bao bao write -f transit/keys/eval-signer type=ed25519 >/dev/null
    "${COMPOSE[@]}" exec -T -e BAO_TOKEN="$BAO_ROOT" bao bao write -f transit/keys/human-signer type=ed25519 >/dev/null
    log "transit keys ready: eval-signer (ed25519), human-signer (ed25519)"
fi

# ------------------------------------------------------- 6. Kafka topics ---
log "provisioning kafka topics (audit-events, decisions)"
"${COMPOSE[@]}" run --rm kafka-init >/dev/null
log "topics ready"

# -------------------------------------------------------- 7. healthcheck ---
bash "$ROOT/ops/scripts/healthcheck.sh" || warn "some checks failed — inspect output above"

cat <<'EOF'

NEXT (human actions):
  1. Store every generated secret (.env values + BAO keys above) in the password manager.
  2. Fill real LLM provider keys into ops/compose/.env on the server, then:
       docker compose -f ops/compose/docker-compose.yml --env-file ops/compose/.env up -d litellm
  3. Verify: curl -sk https://bao.DOMAIN/v1/sys/health ; zot/litellm/langfuse endpoints.
  4. Register daily backup cron: crontab -e
       15 3 * * *  cd /opt/company/platform && bash ops/scripts/backup.sh
EOF
log "bootstrap complete"
