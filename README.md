# platform

Deployment and documentation for the CloudCrane governance platform: the srv-1
base stack (docker compose), Caddy reverse proxy, and server lifecycle scripts.
The governance kernel code itself lives in
[`CloudCrane-Software/kernel`](https://github.com/CloudCrane-Software/kernel).

## Base stack (T-1)

| Service | Image (pinned) | Exposure |
|---|---|---|
| PostgreSQL 16 | `postgres:16.15` | loopback 5432 only |
| Kafka (KRaft) | `apache/kafka:4.3.1` | internal; topics `audit-events` (retention -1), `decisions` (compact) |
| Restate | `restatedev/restate:1.7.10` | Caddy `restate.<DOMAIN>`; admin 9070 loopback |
| OPA | `openpolicyagent/opa:1.20.2-static` | internal only; policies mounted from `ops/opa/` |
| OpenBao | `openbao/openbao:2.6.2` | Caddy `bao.<DOMAIN>`; transit keys `eval-signer`, `human-signer` |
| LiteLLM | `ghcr.io/berriai/litellm-database:main-v1.26.13` | Caddy `litellm.<DOMAIN>` |
| Zot | `ghcr.io/project-zot/zot-linux-amd64:v2.1.21` | Caddy `zot.<DOMAIN>` (basic auth) |
| Langfuse | `langfuse/langfuse:4.36.1` + worker | Caddy `langfuse.<DOMAIN>` (+ clickhouse 25.12, minio, redis 7.4) |
| Caddy | `caddy:2.11.4` | 80/443 public, auto-TLS, six subdomains |
| gateway | *(added in kernel WO-03)* | Caddy `api.<DOMAIN>` |

## Deploy (srv-1, once)

```bash
# as deploy user, after server init (manual §4.1) and DNS records are live:
cd /opt/company/platform
bash ops/scripts/bootstrap.sh
```

bootstrap.sh is idempotent. On first run it prints the OpenBao unseal key and
root token **to the terminal only** — store them in the password manager
immediately; they are never written to disk.

After a host reboot: `bash ops/scripts/bao-unseal.sh` (sealed-by-default Bao).

## Daily operations

```bash
bash ops/scripts/healthcheck.sh   # container + endpoint table, exit 1 on red
bash ops/scripts/backup.sh        # pg_dumpall + volume tars -> /opt/company/backups
```

Cron (human registers once): `15 3 * * * cd /opt/company/platform && bash ops/scripts/backup.sh`

## Security rules

- No secrets in git. The real `.env` is server-side only (bootstrap generates
  it with 0600 perms; it is gitignored).
- PG / Kafka / OPA / minio / redis / clickhouse are never published to public
  interfaces; only Caddy touches the internet (80/443).
- Real LLM provider keys are edited into the server-side `.env` only.

## Notes & known deviations

- `minio` tag `RELEASE.2025-01-20T14-49-07Z` was pinned at authoring time;
  verify with `docker manifest inspect` if the pull fails and re-pin via PR.
- Langfuse browser-side media upload needs a public S3 endpoint; currently set
  to the internal minio (works for server-side event uploads; browser media
  upload disabled until an `lfstore.<DOMAIN>` record + Caddy stanza are added).
- Restate has no built-in healthcheck; it is watched via the Caddy endpoint
  probe in healthcheck.sh.
