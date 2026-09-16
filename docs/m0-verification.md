# M0 verification evidence (code side)

| Judgement | Evidence |
|---|---|
| ① six-table DDL+triggers green | kernel PR#1-#3 CI (testcontainers PG16): P-3/P-4/F-2/append-only all in test_db_invariants.py |
| ③ gateway skeleton + sandbox egress policy | kernel PR#5 contract tests (17); ops/jiuwenbox config egress default-deny + verify-sandbox.sh (runtime check on srv-1 pending) |
| ④ GitHub->CNB one-way mirror | .cnb.yml cron on default branch; manual api_trigger runs SUCCESS with HEAD parity verified 2026-09-16; hourly cron activation in progress (see run logs) |
| ⑤ eval-gate guard in place | kernel guard.yml DEMONSTRATED: PR#6 v1 (mixed product+eval changes) FAILED the guard, then was split into PR#6 (product, green) + PR#8 (eval, waits for eval-gate environment approval) — the manual's three demo outcomes are all on record |
| fork-PR zero secrets | no repo secrets exist in public repos at all (org/ repo secrets lists empty; secret-pattern scans in CI); fork PRs cannot leak what does not exist |

Server-side judgements (② healthy stack, sandbox egress live test, LiteLLM
channels) require srv-1 + DNS — tracked as human prerequisites.
