#!/usr/bin/env bash
# healthcheck.sh — per-container health table + endpoint probes (manual §4.2).
# Exit code: 0 all green, 1 anything red/missing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT/ops/compose/.env"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/ops/compose/docker-compose.yml" --env-file "$ENV_FILE")

[[ -f "$ENV_FILE" ]] || { echo "no .env — run bootstrap.sh first" >&2; exit 1; }
DOMAIN="$(sed -n 's/^DOMAIN=//p' "$ENV_FILE" | head -1)"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
FAIL=0

printf '\n%-18s %-14s %s\n' "CONTAINER" "STATE" "HEALTH"
printf '%s\n' "------------------------------------------------------------"
for c in $("${COMPOSE[@]}" ps -a --format '{{.Name}}' | sort); do
    STATE="$("${COMPOSE[@]}" ps -a --filter "name=^$c$" --format '{{.State}}')"
    HEALTH="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$c" 2>/dev/null || echo missing)"
    case "$HEALTH" in
        healthy)   COLOR=$GREEN ;;
        unhealthy|missing) COLOR=$RED; FAIL=1 ;;
        *)         COLOR=$YELLOW ;; # starting / n/a
    esac
    case "$STATE" in
        running) ;;
        *) COLOR=$RED; FAIL=1 ;;
    esac
    printf '%-18s %-14s %b%s%b\n' "${c#company-}" "$STATE" "$COLOR" "$HEALTH" "$NC"
done

probe() { # url accepted_codes...
    local url="$1"; shift
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo 000)"
    local ok=0
    for a in "$@"; do [[ "$code" == "$a" ]] && ok=1 && break; done
    if (( ok )); then
        printf '%-40s %b%s %s%b\n' "$url" "$GREEN" "$code" "[ok]" "$NC"
    else
        printf '%-40s %b%s (want %s)%b\n' "$url" "$RED" "$code" "$*" "$NC"; FAIL=1
    fi
}

printf '\n%-40s %s\n' "ENDPOINT" "STATUS"
printf '%s\n' "------------------------------------------------------------"
probe "bao sys/health"     "https://bao.$DOMAIN/v1/sys/health"      200 401 501 503
probe "zot /v2/"           "https://zot.$DOMAIN/v2/"                200 401
probe "litellm liveliness" "https://litellm.$DOMAIN/health/liveliness" 200
probe "langfuse health"    "https://langfuse.$DOMAIN/api/public/health" 200
probe "restate /health"    "https://restate.$DOMAIN/health"         200

# internal-only services: probe from inside the network
printf '\n%-40s %s\n' "INTERNAL" "STATUS"
printf '%s\n' "------------------------------------------------------------"
if "${COMPOSE[@]}" exec -T caddy wget -q -O /dev/null http://opa:8181/health 2>/dev/null; then
    printf '%-40s %b%s%b\n' "opa /health" "$GREEN" "ok" "$NC"
else
    printf '%-40s %b%s%b\n' "opa /health" "$RED" "fail" "$NC"; FAIL=1
fi
if "${COMPOSE[@]}" exec -T kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1; then
    printf '%-40s %b%s%b\n' "kafka api-versions" "$GREEN" "ok" "$NC"
else
    printf '%-40s %b%s%b\n' "kafka api-versions" "$RED" "fail" "$NC"; FAIL=1
fi
TOPICS="$("${COMPOSE[@]}" exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null | sort | tr '\n' ' ' || echo '')"
printf '%-40s %s\n' "kafka topics" "${TOPICS:-<none>}"

if (( FAIL )); then
    printf '\n%bRESULT: FAIL%b\n' "$RED" "$NC"; exit 1
fi
printf '\n%bRESULT: ALL GREEN%b\n' "$GREEN" "$NC"
