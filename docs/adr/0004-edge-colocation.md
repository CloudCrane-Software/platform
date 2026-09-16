# ADR 0004: base stack co-located on edge-server (owner decision, 2026-09-16)

## Context
srv-1 is not rented yet; the owner decided to run the FULL base stack on the
existing edge-server (42.194.143.17, hkmingdajiaoyu.com already resolves
here, TC firewall 443 open) rather than wait. The host also carries
production services (client website on nginx :80) and has 7.4G RAM + 4G swap.

## Decision
- Deploy via `docker-compose.edge.yml` override:
  - Caddy publishes **443 only** (host nginx owns :80). ACME issuance uses
    TLS-ALPN-01 instead of HTTP-01 — no port-80 involvement, zero conflict.
  - PG stays loopback-only; kafka/opa/minio/redis/clickhouse/tigerbeetle
    stay unpublished, exactly as the canonical compose specifies.
- The canonical docker-compose.yml remains srv-1-shaped (both ports); the
    override is additive and only used on this host.
- Memory risk accepted by owner; swap (4G) present as backstop.

## Consequences
- Six https://<sub>.hkmingdajiaoyu.com endpoints terminate at Caddy in
  docker; nginx and client sites untouched.
- If memory pressure appears, migration path = rent srv-1, re-point the 12
  DNS records, re-run bootstrap there (data via backup.sh restore).
