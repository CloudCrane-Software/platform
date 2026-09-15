# OPA policies mount point

This directory is mounted read-only into the `opa` container and loaded at
startup (`opa run --server /policies`). It is the **deploy target** for the
policy bundle built by CI from the kernel repo `policies/` directory.

Layout convention:

```
opa/
  grant.rego          # shipped from kernel repo policies/ by CI
  bundle.tar.gz       # OR a full bundle — see kernel repo build job
```

CI (kernel repo, `policies.yml` workflow) compiles + tests the Rego policies,
builds the bundle, and opens a PR that copies the artifacts here. OPA restarts
pick up the new bundle.

Internal-only service: OPA is never exposed through Caddy. Only in-stack
consumers (gateway) may query `http://opa:8181`.
