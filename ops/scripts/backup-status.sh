#!/usr/bin/env bash
# backup-status.sh — freshness/size report for the §9.2 daily backups
# (batch D). For alerting + SOP use; independent of healthcheck-edge.sh
# (which probes network/memory, per its own scope).
# Exit 0 = all kinds fresh (<26h), 2 = some stale, 3 = some kind missing.
set -uo pipefail
BACKUP_ROOT="/opt/company/backups"
NOW=$(date +%s)
STALE_SECS=$((26 * 3600))
WORST=0

printf '%-10s %-24s %8s %6s %8s\n' KIND LATEST SIZE_MiB FILES AGE
for kind in pg config transform; do
  d="$BACKUP_ROOT/$kind"
  latest=$(ls -1t "$d" 2>/dev/null | grep -v '\.part$' | head -1 || true)
  if [[ -z ${latest:-} ]]; then
    printf '%-10s %-24s %8s %6s %8s\n' "$kind" MISSING - 0 -
    WORST=3
    continue
  fi
  f="$d/$latest"
  m=$(stat -c %Y "$f" 2>/dev/null || echo "$NOW")
  age_h=$(( (NOW - m) / 3600 ))
  n=$(ls -1 "$d" 2>/dev/null | wc -l)
  size_mib=$(( $(stat -c %s "$f") / 1048576 ))
  printf '%-10s %-24s %8s %6s %7sh\n' "$kind" "$latest" "$size_mib" "$n" "$age_h"
  if (( NOW - m > STALE_SECS )); then
    echo "  STALE: $kind latest backup is ${age_h}h old (> 26h) — check backup cron/log"
    (( WORST < 2 )) && WORST=2
  fi
done

total=$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)
echo "total: ${total:-?} under $BACKUP_ROOT (retention: 30 days)"
if (( WORST == 0 )); then
  echo "STATUS: FRESH"
elif (( WORST == 2 )); then
  echo "STATUS: STALE"
else
  echo "STATUS: MISSING"
fi
exit "$WORST"
