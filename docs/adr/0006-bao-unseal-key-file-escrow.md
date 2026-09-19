# ADR 0006: OpenBao key escrow at /etc/bao, file-first, no legacy vault fallback (owner decision, 2026-09-19)

## Context

The base stack moved to the new edge host (lhins-kbf5177p, 159.75.21.149) on
2026-09-19. OpenBao (container `company-bao-1`) auto-seals whenever its
container is recreated, and a host reboot recreates the whole stack (the
`ops/scripts/edge-recovery.sh` path). Recovery therefore needs the unseal key
available on the host at boot.

Two escrow sources existed across the machine generations:

- OLD host: unseal key fetched from a legacy host vault
  (`secret/cloudcrane/base-stack` via `/etc/vault/root-token`). The
  2026-09-17 repo version of `ops/scripts/edge-recovery.sh` depends on this
  path exclusively.
- NEW host: plaintext file escrow at `/etc/bao/{unseal-key,root-token}`,
  permissions 0600, root-only (directory 0700), provisioned during the
  2026-09-19 migration; the migration-day recovery run unsealed Bao from it
  successfully.

The migration-day server-side patch made the script "file-first + legacy
vault fallback". On the new host the fallback is a dead path: `/etc/vault`
does not exist, so the fallback branch can never succeed. Prior to this ADR
the file-first patch had never entered the repo
(`git log --all -S 'unseal-key'` empty; M2 启动计划终稿 §2.7 evidence).

## Decision (owner, 2026-09-19)

1. Escrow the OpenBao unseal key and root token as plaintext files at
   `/etc/bao/unseal-key` and `/etc/bao/root-token`, 0600 root-only.
2. The repo version of `ops/scripts/edge-recovery.sh` is **file-only**: the
   legacy host-vault fallback branch is REMOVED. If the escrow file is
   missing or empty the script fails fast with an explicit message instead
   of silently degrading to a dead code path.
3. Apply note (post-E4 batch): the deployed
   `/opt/company/platform/ops/scripts/edge-recovery.sh` must be reinstalled
   from the repo version so the deployed copy converges with main (it
   currently still carries the dead fallback branch).

## Consequences

- Recovery after host reboot needs no external secret service; one fewer
  moving part on the edge host, and the script's behavior matches what the
  host can actually do.
- The unseal key and root token sit in plaintext on the host filesystem.
  Accepted by owner given 0600 root-only permissions and single-operator
  root access. Rotation is out of scope (SECRET-FREEZE, M2 终稿 §2.5: no
  secret rotation before full completion).
- The legacy vault path is dead code and MUST NOT be restored. If a future
  host reintroduces a host vault, that is a new ADR.

## Facts (verified 2026-09-20, metadata only)

- `/etc/bao/unseal-key`, `/etc/bao/root-token`: `-rw------- root root`
  (0600), directory `/etc/bao` is `drwx------ root root` (0700).
- `/etc/vault` does not exist on the new host (`ls: cannot access
  '/etc/vault': No such file or directory`).
- Migration-day run (2026-09-19): `bao operator unseal` from the file
  succeeded; stack healthy (17 containers Up, E4 anchor unchanged).

## Relations

- Extends ADR 0004 (edge colocation) with the secret-escrow aspect of host
  recovery.
- Implements WO-0002 requirement 1/2 (mandates
  `workorders/0002-edge-recovery-filefirst-patchback.md`).
