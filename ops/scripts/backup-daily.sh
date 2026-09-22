#!/usr/bin/env bash
# backup-daily.sh — manual §9.2 daily backup (batch D, 2026-09-22).
#   pg:        cluster-wide pg_dumpall (postgres/company/litellm/langfuse)
#   config:    /opt/company/platform/ops incl. compose/.env (0600 via umask 077)
#   transform: /root/transform work tree minus .git (decision records / manual)
# Retention: 30 days. Cron: 0 4 * * * (appended to root crontab 2026-09-22).
# Complements ops/scripts/backup.sh (manual §4.2 full-stack snapshot incl.
# volume tars — exists since 2026-09-16 but was never cron-registered; kept
# as-is for manual full snapshots).
set -euo pipefail
umask 077
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_ROOT="/opt/company/backups"
PLATFORM_OPS="/opt/company/platform/ops"

# --- PG: full-cluster logical backup ----------------------------------------
# Write to .part first so a failed dump never leaves a truncated file that
# restore drills / status could mistake for a valid backup.
mkdir -p "$BACKUP_ROOT/pg"
if docker exec company-pg-1 pg_dumpall -U postgres | gzip > "$BACKUP_ROOT/pg/pgall-$TS.sql.gz.part"; then
  mv "$BACKUP_ROOT/pg/pgall-$TS.sql.gz.part" "$BACKUP_ROOT/pg/pgall-$TS.sql.gz"
else
  rm -f "$BACKUP_ROOT/pg/pgall-$TS.sql.gz.part"
  echo "backup-$TS: pg_dumpall FAILED" >&2
  exit 1
fi

# --- compose config (includes .env; protected 0600 via umask 077) -----------
# NOTE: GNU tar --exclude must precede the file operands (-C dir .).
mkdir -p "$BACKUP_ROOT/config"
tar --exclude='*.pyc' --exclude='__pycache__' \
  -czf "$BACKUP_ROOT/config/compose-$TS.tgz" -C "$PLATFORM_OPS" . \
  || echo "backup-$TS: WARN config tar nonzero" >&2

# --- transform work tree (decision records / manual / work orders) ----------
mkdir -p "$BACKUP_ROOT/transform"
tar --exclude='.git' --exclude='*.pyc' --exclude='__pycache__' \
  -czf "$BACKUP_ROOT/transform/transform-$TS.tgz" -C /root/transform . \
  || echo "backup-$TS: WARN transform tar nonzero" >&2

# --- integrity check + retention: 30 days -----------------------------------
for f in "$BACKUP_ROOT/pg/pgall-$TS.sql.gz" \
         "$BACKUP_ROOT/config/compose-$TS.tgz" \
         "$BACKUP_ROOT/transform/transform-$TS.tgz"; do
  if [[ ! -f "$f" ]]; then echo "backup-$TS: MISSING $f" >&2; exit 1; fi
  gzip -t "$f"
done
find "$BACKUP_ROOT" -type f \( -name '*.gz' -o -name '*.tgz' \) -mtime +30 -delete
find "$BACKUP_ROOT/pg" -type f -name '*.part' -mmin +1440 -delete

echo "backup-$TS: pg=$(du -sh "$BACKUP_ROOT/pg/pgall-$TS.sql.gz" | cut -f1) config=$(du -sh "$BACKUP_ROOT/config/compose-$TS.tgz" | cut -f1) transform=$(du -sh "$BACKUP_ROOT/transform/transform-$TS.tgz" | cut -f1)"
