# JiuwenBox sandbox

Ephemeral execution sandbox for coding agents (openJiuWen-native, default
isolation tier). Two properties are load-bearing for the whole governance
system: **egress default-deny** (every external side effect must pass the
action gateway) and **LLM privacy-proxy mode** (real provider keys never
enter the sandbox).

## Layout

- `config.yaml` — sandbox policy (network isolation, whitelist, lifecycle)
- `ops/compose/docker-compose.yml` — `jiuwenbox` service under the `sandbox`
  compose profile (started separately from the base stack)

The image tag is set via `JIWUENBOX_IMAGE` in `.env` — pin it to the exact
version matching your pinned openJiuWen release at deploy time (do not run
floating tags).

## Start / stop / inspect (on srv-1)

```bash
# start sandbox service (profile-gated, base stack untouched)
docker compose --env-file ops/compose/.env -f ops/compose/docker-compose.yml \
  --profile sandbox up -d jiuwenbox

# status
docker compose ... --profile sandbox ps jiuwenbox

# stop (running sandboxes are destroyed: on_stop=delete)
docker compose ... --profile sandbox stop jiuwenbox
```

## Egress verification (must pass before any agent uses the sandbox)

From INSIDE a running sandbox session:

```bash
# must FAIL (not whitelisted):
curl -v --max-time 10 https://example.com            # expect: connection refused/timeout
curl -v --max-time 10 https://api.github.com         # expect: connection refused/timeout

# must SUCCEED (whitelisted):
curl -v https://api.${DOMAIN}/health                 # expect: HTTP response from gateway
curl -v https://litellm.${DOMAIN}/health/liveliness  # expect: 200
```

Both directions are asserted by `ops/scripts/verify-sandbox.sh` — run it
after first deploy and after every sandbox image change; a failing check
means the isolation property is broken: stop agent workloads immediately.

## Secret placement

- Real LLM provider keys: OpenBao → LiteLLM channels only.
- Sandbox environment: `LLM_API_KEY=PLACEHOLDER-ONLY` (privacy proxy swaps it).
- If a real key is ever found inside a sandbox: rotate ALL keys immediately
  (manual §9.4) and file an incident work order.
