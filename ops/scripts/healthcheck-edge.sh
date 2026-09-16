#!/usr/bin/env bash
# healthcheck-edge.sh — edge colocation variant of healthcheck.sh:
# subdomain probes pinned to EDGE_IPV4 (DNS may prefer IPv6), plus a memory
# guard (co-location risk, ADR 0004).
set -uo pipefail
ENVF="/opt/company/platform/ops/compose/.env"
DOMAIN="$(sed -n 's/^DOMAIN=//p' "$ENVF" | head -1)"
IPV4="$(sed -n 's/^EDGE_IPV4=//p' "$ENVF" | head -1)"
RED=$'\033[31m'; GREEN=$'\033[32m'; NC=$'\033[0m'; FAIL=0

probe() { # sub path expected_codes...
  local sub="$1" path="$2"; shift 2
  local host="$sub.$DOMAIN"
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "$host:443:$IPV4" "https://$host$path" 2>/dev/null || echo 000)
  local ok=0 a
  for a in "$@"; do [[ "$code" == "$a" ]] && ok=1 && break; done
  if (( ok )); then
    printf '%b%-40s %s [ok]%b\n' "$GREEN" "$host$path" "$code" "$NC"
  else
    printf '%b%-40s %s (want %s)%b\n' "$RED" "$host$path" "$code" "$*" "$NC"; FAIL=1
  fi
}

probe bao      /v1/sys/health        200
probe zot      /v2/                  401 200
probe litellm  /health/liveliness    200
probe langfuse /api/public/health    200
probe restate  /health               200 400 404

MEM=$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
if (( MEM > 90 )); then
  printf '%bMEMORY: %s%% HIGH (co-location risk)%b\n' "$RED" "$MEM" "$NC"; FAIL=1
else
  printf '%bMEMORY: %s%% ok%b\n' "$GREEN" "$MEM" "$NC"
fi

(( FAIL )) && exit 1 || exit 0
