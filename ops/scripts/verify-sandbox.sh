#!/usr/bin/env bash
# verify-sandbox.sh — assert the JiuwenBox egress contract (manual §4.3).
# Inside a sandbox session: non-whitelisted hosts must be unreachable;
# api/litellm must be reachable. Exits non-zero on any violation.
set -uo pipefail

DOMAIN="$(sed -n 's/^DOMAIN=//p' "$(dirname "$0")/../compose/.env" | head -1)"

RED=$'\033[31m'; GREEN=$'\033[32m'; NC=$'\033[0m'
FAIL=0

must_fail() { # url
    if curl -s -o /dev/null --max-time 8 "$1"; then
        printf '%bVIOLATION: %s was reachable%b\n' "$RED" "$1" "$NC"; FAIL=1
    else
        printf '%bblocked ok: %s%b\n' "$GREEN" "$1" "$NC"
    fi
}

must_pass() { # url
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" || echo 000)"
    if [[ "$code" != 000 ]]; then
        printf '%breachable ok: %s (%s)%b\n' "$GREEN" "$1" "$code" "$NC"
    else
        printf '%bVIOLATION: %s unreachable%b\n' "$RED" "$1" "$NC"; FAIL=1
    fi
}

echo "== egress default-deny checks (run INSIDE the sandbox session) =="
must_fail "https://example.com"
must_fail "https://api.github.com"
must_pass "https://api.${DOMAIN}/health"
must_pass "https://litellm.${DOMAIN}/health/liveliness"

(( FAIL )) && { printf '%bRESULT: FAIL%b\n' "$RED" "$NC"; exit 1; }
printf '%bRESULT: ALL GREEN%b\n' "$GREEN" "$NC"
