#!/usr/bin/env bash
# backup-restore-drill.sh — proves the §9.2 daily backups are restorable.
#   1) latest pgall-*.sql.gz -> throwaway postgres:16.15 container -> verify
#      every live company-db table exists + row-count spot checks vs production
#   2) latest compose-*.tgz   -> tmp dir -> diff -r vs live ops/  (drift = WARN)
#   3) latest transform-*.tgz -> tmp dir -> diff -r vs live /root/transform
# Production-safe: throwaway container only (no prod restarts, no prod writes).
# Exit 0 = PASS, 1 = FAIL. Run after first backup and whenever SOP requires.
set -uo pipefail
BACKUP_ROOT="/opt/company/backups"
PLATFORM_OPS="/opt/company/platform/ops"
DRILL_CONTAINER="backup-drill-restore"
TS=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d "/tmp/restore-drill-$TS.XXXXXX")
FAIL=0
cleanup() { docker rm -f "$DRILL_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

latest_path() { # dir pattern -> newest file, full path (skip .part)
  local d="$1" p="$2"
  ls -1t "$d"/$p 2>/dev/null | grep -v '\.part$' | head -1 || true
}

echo "== backup restore drill $TS =="
echo "workdir: $WORK"

# --- 1. PG restore into throwaway container ---------------------------------
PG=$(latest_path "$BACKUP_ROOT/pg" 'pgall-*.sql.gz')
if [[ -z ${PG:-} ]]; then
  echo "FAIL pg: no pgall-*.sql.gz under $BACKUP_ROOT/pg"
  exit 1
fi
echo "[1] pg source: $(basename "$PG") ($(du -sh "$PG" | cut -f1))"

docker run -d --name "$DRILL_CONTAINER" \
  -e POSTGRES_PASSWORD="drill-$TS" postgres:16.15 >/dev/null
READY=0
for _ in $(seq 1 30); do
  if docker exec "$DRILL_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
if (( ! READY )); then echo "FAIL pg: drill container not ready"; exit 1; fi

# pg_dumpall emits `CREATE ROLE postgres;` but the fresh initdb cluster already
# has it (documented pg_dumpall behavior; per pg_dumpall docs such errors on a
# fresh cluster are ignorable). Filter that single deterministic line so we can
# keep psql ON_ERROR_STOP=1 strict for everything else.
if gunzip -c "$PG" | grep -vx 'CREATE ROLE postgres;' \
     | docker exec -i "$DRILL_CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -q >/dev/null \
     2>"$WORK/pg-restore.err"; then
  echo "[1] pg restore: OK (psql ON_ERROR_STOP=1, no errors)"
else
  echo "FAIL pg: restore errored (first 20 lines):"
  head -20 "$WORK/pg-restore.err"
  exit 1
fi

# table coverage: every table in the live company db must exist in the restore
LIVE_TABLES=$(docker exec company-pg-1 psql -U postgres -d company -Atc \
  "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1;")
MISS=0
for t in $LIVE_TABLES; do
  HAS=$(docker exec "$DRILL_CONTAINER" psql -U postgres -d company -Atc \
    "SELECT to_regclass('public.$t') IS NOT NULL;" 2>/dev/null || echo f)
  if [[ "$HAS" == "t" ]]; then echo "    table $t: OK"; else echo "    table $t: MISSING"; MISS=1; fi
done
if (( MISS )); then FAIL=1; else
  echo "[1] table coverage: all $(echo "$LIVE_TABLES" | wc -l) live tables present in restore"
fi

# row-count spot checks vs production (data actually made it through)
for t in episodes decisions audit_events; do
  LIVE_N=$(docker exec company-pg-1 psql -U postgres -d company -Atc \
    "SELECT count(*) FROM $t;" 2>/dev/null || echo "?")
  REST_N=$(docker exec "$DRILL_CONTAINER" psql -U postgres -d company -Atc \
    "SELECT count(*) FROM $t;" 2>/dev/null || echo "?")
  if [[ "$LIVE_N" == "$REST_N" ]]; then
    echo "    rows $t: $REST_N == live OK"
  else
    echo "    rows $t: restore=$REST_N live=$LIVE_N MISMATCH"; FAIL=1
  fi
done

# --- 2. compose config diff --------------------------------------------------
CFG=$(latest_path "$BACKUP_ROOT/config" 'compose-*.tgz')
if [[ -z ${CFG:-} ]]; then
  echo "FAIL config: no compose-*.tgz under $BACKUP_ROOT/config"; FAIL=1
else
  echo "[2] config source: $(basename "$CFG")"
  mkdir -p "$WORK/ops"
  if tar xzf "$CFG" -C "$WORK/ops" 2>/dev/null; then
    if diff -r -q --exclude=__pycache__ "$WORK/ops" "$PLATFORM_OPS" >"$WORK/config.diff" 2>&1; then
      echo "[2] config diff vs live ops/: IDENTICAL"
    else
      echo "WARN config: drift vs live ops/ (snapshot is valid; live moved since):"
      head -20 "$WORK/config.diff"
    fi
  else
    echo "FAIL config: tar unpack failed"; FAIL=1
  fi
fi

# --- 3. transform diff --------------------------------------------------------
TR=$(latest_path "$BACKUP_ROOT/transform" 'transform-*.tgz')
if [[ -z ${TR:-} ]]; then
  echo "FAIL transform: no transform-*.tgz under $BACKUP_ROOT/transform"; FAIL=1
else
  echo "[3] transform source: $(basename "$TR")"
  mkdir -p "$WORK/transform"
  if tar xzf "$TR" -C "$WORK/transform" 2>/dev/null; then
    if diff -r -q --exclude=.git --exclude=__pycache__ "$WORK/transform" /root/transform \
         >"$WORK/transform.diff" 2>&1; then
      echo "[3] transform diff vs live /root/transform: IDENTICAL"
    else
      echo "WARN transform: drift vs live (snapshot is valid; live moved since):"
      head -20 "$WORK/transform.diff"
    fi
  else
    echo "FAIL transform: tar unpack failed"; FAIL=1
  fi
fi

echo "== drill summary =="
if (( FAIL )); then echo "RESULT: FAIL"; else echo "RESULT: PASS"; fi
exit "$FAIL"
