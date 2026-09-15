#!/usr/bin/env bash
# backup.sh — daily backup of the base stack (manual §4.2).
#   PG:      consistent pg_dumpall (runs inside the container)
#   volumes: tar snapshots of file-backed data dirs
#            (Bao: run while SEALED for a consistent copy — see note below)
# Retention: 14 days under /opt/company/backups/
#
# Cron (human registers once):
#   15 3 * * *  cd /opt/company/platform && bash ops/scripts/backup.sh >> /opt/company/backups/backup.log 2>&1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT/ops/compose/.env"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/ops/compose/docker-compose.yml" --env-file "$ENV_FILE")
BACKUP_ROOT="/opt/company/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$STAMP"
RETENTION_DAYS=14

log() { printf '[backup %s] %s\n' "$STAMP" "$*"; }

[[ -f "$ENV_FILE" ]] || { echo "no .env — run bootstrap.sh first" >&2; exit 1; }
mkdir -p "$DEST"

# --- PostgreSQL: consistent cluster-wide dump --------------------------------
log "pg_dumpall -> $DEST/pg_all.sql.gz"
"${COMPOSE[@]}" exec -T pg pg_dumpall -U postgres | gzip -6 > "$DEST/pg_all.sql.gz"

# --- File-backed volumes ------------------------------------------------------
# NOTE on OpenBao: copying the storage dir while bao is UNSEALED and taking
# writes can produce an inconsistent snapshot. For maximum safety seal first
# (bao-unseal.sh reverses it), or accept the crash-recovery window. We snapshot
# as-is and record the seal state.
SEALED="$(cd "$ROOT" && "${COMPOSE[@]}" exec -T bao bao status 2>/dev/null | grep -c 'Sealed.*true' || echo unknown)"
echo "bao sealed at backup time: $SEALED" > "$DEST/NOTE-bao-seal-state.txt"

for d in pg bao restate kafka zot clickhouse minio redis tb; do
    SRC="/opt/company/data/$d"
    [[ -d "$SRC" ]] || continue
    log "tar $SRC -> $DEST/$d.tar.gz"
    tar -czf "$DEST/$d.tar.gz" -C /opt/company/data "$d"
done

# --- Finish + retention -------------------------------------------------------
chmod -R go-rwx "$DEST"
log "backup complete: $DEST ($(du -sh "$DEST" | cut -f1))"
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
log "retention: removed backups older than ${RETENTION_DAYS}d"
