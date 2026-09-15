# AGENTS.md — platform

One sentence: deployment & docs repo for the srv-1 base stack — compose,
Caddy, and lifecycle scripts; no application code.

## Directory map

```
ops/compose/       docker-compose.yml (base stack) + .env.example
ops/caddy/         Caddyfile (six subdomains, auto-TLS)
ops/sql/           first-boot PG init (databases/roles only; kernel DDL ships in kernel repo)
ops/bao/           OpenBao server config
ops/litellm/       LiteLLM proxy config template (channels + budget windows)
ops/zot/           Zot registry config
ops/opa/           OPA policy mount point (CI deploy target from kernel repo)
ops/scripts/       bootstrap.sh / backup.sh / healthcheck.sh / bao-unseal.sh
docs/adr/          architecture decision records
```

## Build & test commands

```bash
bash -n ops/scripts/*.sh                 # syntax check
shellcheck ops/scripts/*.sh              # lint (CI runs this)
docker compose -f ops/compose/docker-compose.yml config   # compose validation
```

## Code conventions

- Shell scripts: bash strict mode (`set -euo pipefail`), shellcheck-clean.
- YAML/JSON: no inline secrets, everything sensitive flows through `.env`.
- Version bumps (image tags) are PRs with the tag verified via
  `docker manifest inspect` (or registry API) before merge.

## Prohibitions (each rule has an executable checkpoint)

1. Never commit the real `.env` or any key/token/password.
   Checkpoint: CI grep for secret-looking patterns + `.gitignore` covers `.env`.
2. Never publish internal services (PG/Kafka/OPA/minio/redis/clickhouse) to
   public ports; only Caddy faces the internet.
   Checkpoint: `docker compose config | grep -A3 ports:` review in every PR
   touching compose.
3. Never unpin an image tag (`latest` is forbidden).
   Checkpoint: CI script asserts every `image:` has a pinned tag.
4. Never bypass PR to main.
   Checkpoint: branch protection (required PR + status checks + no force push).

## Working rules for agents

- Read this file before doing anything in this repo.
- Human instructions arrive as work-order files, never verbal. Do not expand
  scope beyond the work order; on unclear or blocked conditions, stop and
  report.
- Changes that alter the exposure matrix (ports, TLS, auth) require an ADR in
  `docs/adr/`.
