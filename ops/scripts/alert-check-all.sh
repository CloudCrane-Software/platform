#!/usr/bin/env bash
# alert-check-all.sh — active alerting layer (batch D). Runs the five
# monitored conditions and calls alert-notify.sh on ANY anomaly, so an
# on-call sees it instead of waiting for someone to look:
#
#   1. healthcheck-edge.sh  rc != 0                    -> CRITICAL (stack health)
#   2. backup-status.sh     rc=2 stale / rc=3 missing  -> WARNING / CRITICAL
#   3. daily report gap: latest reports/daily file (pricing repo,
#      reports/daily branch) != yesterday UTC          -> WARNING
#   4. PG company db: obligations rows with status='ESCALATED' > 0 -> CRITICAL
#   5. GitHub Actions: completed runs with conclusion=failure within 24h
#      across CloudCrane-Software/{platform,kernel,skills}
#      gate workflows (sign/eval-gate/guard) -> CRITICAL, others -> WARNING
#
# Designed for cron every 15 min. NOTE: conditions persisting across runs
# re-notify each cycle (no dedup — deliberate, predictable; keep the
# webhook quiet or widen the cron if that ever becomes noise).
# Exit 0 = all five ok, 1 = at least one alert fired.
set -uo pipefail

SCRIPTS_DIR="/opt/company/platform/ops/scripts"
ENV_FILE="/opt/company/platform/ops/compose/.env"
GH_ORG="CloudCrane-Software"
GH_REPOS="platform kernel skills"
CREDS_FILE="/root/company/.git-creds"

FAILED=0

notify() { # severity message
  bash "$SCRIPTS_DIR/alert-notify.sh" "$1" "$2"
}
fail() { # severity message  — record an anomaly and notify
  FAILED=1
  notify "$1" "$2"
}
one_line() { # squeeze a command's output into <=300 chars for alert text
  printf '%s\n' "$1" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-300
}

echo "----- alert-check-all start $(date -u +%Y-%m-%dT%H:%M:%SZ) -----"

# --- 1/5 stack health -------------------------------------------------------
echo "=== check 1/5: healthcheck-edge (stack health) ==="
HC_OUT="$(bash "$SCRIPTS_DIR/healthcheck-edge.sh" 2>&1)"
HC_RC=$?
if [ "$HC_RC" -ne 0 ]; then
  fail CRITICAL "healthcheck-edge.sh FAILED rc=$HC_RC: $(one_line "$HC_OUT")"
else
  echo "[ok] $(one_line "$HC_OUT")"
fi

# --- 2/5 backup freshness ---------------------------------------------------
echo "=== check 2/5: backup-status (manual §9.2 backups) ==="
BK_OUT="$(bash "$SCRIPTS_DIR/backup-status.sh" 2>&1)"
BK_RC=$?
BK_BAD="$(printf '%s\n' "$BK_OUT" | grep -E 'STALE|MISSING|STATUS' | tr '\n' ';')"
case "$BK_RC" in
  0) echo "[ok] $(one_line "$BK_OUT" | sed 's/.*total/total/')";;
  2) fail WARNING "backup-status rc=2 STALE: $(one_line "$BK_BAD")";;
  3) fail CRITICAL "backup-status rc=3 MISSING: $(one_line "$BK_BAD")";;
  *) fail WARNING "backup-status rc=$BK_RC (unexpected): $(printf '%s\n' "$BK_OUT" | tail -2 | tr '\n' ' ' | cut -c1-200)";;
esac

# --- 3/5 daily report freshness --------------------------------------------
# The pricing daily reports live on the reports/daily git branch of the
# cnb.cool pricing clone (data-push channel), not on the local filesystem.
echo "=== check 3/5: daily report freshness (pricing reports/daily) ==="
YDAY="$(date -u -d '-1 day' +%F)"
PRICING_DIR="/root/company/cnb-staging/pricing"
LATEST="$(
  cd "$PRICING_DIR" 2>/dev/null \
  && GIT_CONFIG_GLOBAL=/root/company/gitconfig timeout 45 git fetch -q origin reports/daily 2>/dev/null \
  && git ls-tree -r --name-only FETCH_HEAD 2>/dev/null \
     | grep -oE '^reports/daily/[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' \
     | sort | tail -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}'
)"
if [ -z "$LATEST" ]; then
  fail WARNING "daily-report: cannot determine latest reports/daily file (fetch failed or pricing clone missing) — expected $YDAY (UTC)"
elif [ "$LATEST" != "$YDAY" ]; then
  fail WARNING "daily-report GAP: latest reports/daily file is $LATEST, expected $YDAY (UTC) — check /var/log/pricing-daily.log and the 06:30 report cron"
else
  echo "[ok] latest daily report = $LATEST (= yesterday UTC)"
fi

# --- 4/5 obligations escalations -------------------------------------------
echo "=== check 4/5: obligations ESCALATED (PG company db) ==="
PG_USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
PG_USER="${PG_USER:-postgres}"
ESC="$(docker exec company-pg-1 psql -U "$PG_USER" -d company \
  -tAc "SELECT count(*) FROM obligations WHERE status='ESCALATED'" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$ESC" ]; then
  fail WARNING "obligations: cannot query company-pg-1 (container down / psql failed)"
elif [ "$ESC" -gt 0 ]; then
  fail CRITICAL "obligations: $ESC ESCALATED row(s) in PG company db — verification escalated, investigate action_intents"
else
  echo "[ok] obligations: 0 ESCALATED"
fi

# --- 5/5 GitHub Actions gate failures --------------------------------------
echo "=== check 5/5: GitHub Actions failures (24h window) ==="
if ! command -v jq >/dev/null 2>&1; then
  fail WARNING "github-actions: jq not installed — cannot check workflow runs"
else
  GH_TOKEN="$(sed -n 's|^https://[^:/]*:\([^@]*\)@github.com$|\1|p' "$CREDS_FILE" 2>/dev/null | head -1)"
  if [ -z "$GH_TOKEN" ]; then
    fail WARNING "github-actions: no github.com credential in $CREDS_FILE — cannot check workflow runs"
  else
    SINCE="$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)"
    ANY_FAILURE=0
    for REPO in $GH_REPOS; do
      RUNS_JSON="$(curl -sS --max-time 20 \
        -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$GH_ORG/$REPO/actions/runs?per_page=15" 2>/dev/null || true)"
      if [ -z "$RUNS_JSON" ]; then
        fail WARNING "github-actions: API query failed for $GH_ORG/$REPO"
        continue
      fi
      FAILURES="$(printf '%s' "$RUNS_JSON" | jq -r --arg since "$SINCE" '
        (.workflow_runs // [])[] 
        | select(.status == "completed" and .conclusion == "failure" and .created_at >= $since)
        | [.name, .head_branch, .created_at, .html_url] | @tsv' 2>/dev/null)"
      if [ -n "$FAILURES" ]; then
        ANY_FAILURE=1
        while IFS=$'\t' read -r WF_NAME WF_BRANCH WF_AT WF_URL; do
          case "$WF_NAME" in
            *eval-gate*|*eval_gate*|*guard*|*sign*|*SIGN*)
              fail CRITICAL "github-actions GATE FAILURE: $GH_ORG/$REPO '$WF_NAME' ($WF_BRANCH) $WF_AT — $WF_URL" ;;
            *)
              fail WARNING "github-actions failure: $GH_ORG/$REPO '$WF_NAME' ($WF_BRANCH) $WF_AT — $WF_URL" ;;
          esac
        done <<< "$FAILURES"
      fi
    done
    [ "$ANY_FAILURE" -eq 0 ] && echo "[ok] no failed workflow runs in last 24h across $GH_ORG/{$(echo "$GH_REPOS" | tr ' ' ',')}"
  fi
fi

# --- summary ----------------------------------------------------------------
echo "----- alert-check-all end $(date -u +%Y-%m-%dT%H:%M:%SZ) -----"
if [ "$FAILED" -eq 0 ]; then
  echo "ALL CHECKS OK"
  exit 0
fi
echo "ALERTS FIRED (delivered per alert-notify.sh; persisted in /var/log/company-alerts.log)"
exit 1
