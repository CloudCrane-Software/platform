# ADR 0002: CNB organization naming (yearly root-org quota constraint)

## Context
Manual §1.1/§3.1: CNB organization named `<ORG>` or `<ORG>-private`. The CNB
account's 2026 root-organization creation quota is exhausted by the legacy
`Cloudbird-Software` org; `POST /groups` returns
"The root organization has reached its yearly creation limit."

## Decision
Reuse `Cloudbird-Software` as the CNB namespace for now (description updated
to the CloudCrane purpose). Re-evaluate at quota reset (yearly) or when CNB
supports sub-groups; renaming/moving then is cheap because every CNB repo is
either a one-way mirror (re-point the pipeline) or a small template repo.

## Consequences
- Mirror URLs reference Cloudbird-Software; tracked here and in .cnb.yml files.
- The old-name association is a naming residue only; all legacy repos were
  deleted (22 repos, audited list) and credentials are scoped tokens.

## Ratification

**RATIFIED by the owner, 2026-09-17** — Cloudbird-Software remains the CNB namespace
until quota reset; re-evaluation triggers unchanged.
