# Architecture Decision Records

Every significant decision about Vaulta's architecture is recorded here as a
numbered ADR. The list is append-only: a decision that turned out to be wrong
is superseded by a new ADR, not edited in place.

The ADRs used to live in `docs/architecture/ADR-00N-*.md`. They were migrated
to this folder on 2026-10-25 with the same content, the same numbering and
the same decision text — only the file names changed, to the canonical
`NNNN-<decision>.md` shape.

The pack was approved for implementation in batches (2026-06-11).

## Format

Every ADR follows the same three-step shape:

| Section | What it answers |
| --- | --- |
| **Context** | What forced the decision. The forces, not the decision. |
| **Decision** | What was decided, in the active voice: "we will…". |
| **Consequences** | What the decision costs and what it buys. |

The first five ADRs were written in Spanish and are frozen in that language,
because the decision they record was taken in Spanish. ADRs 0006 and later are
in English. New ADRs are written in English.

## Index

| # | Decision | Status | Date |
| --- | --- | --- | --- |
| [0001](./0001-crypto-key-derivation-and-encrypted-blob.md) | Key derivation and encrypted blob format v2 | Accepted | 2026-03-23 (amended 2026-10-19, 2026-10-20, 2026-10-21) |
| [0002](./0002-sync-versioning-cas-idempotency-tombstones.md) | Sync model with versioning, CAS, idempotency and tombstones | Accepted | 2026-03-23 (amended 2026-10-20) |
| [0003](./0003-session-policy-and-revocation.md) | Session policy and per-device / global revocation | Accepted | 2026-03-23 |
| [0004](./0004-sync-layer-roadmap.md) | Roadmap for the `lib/core/sync/` layer | Accepted | 2026-06-11 |
| [0005](./0005-repository-hygiene-lints-and-coverage.md) | Repository hygiene, lints and coverage | Accepted | 2026-06-11 |
| [0006](./0006-encrypted-backup-format.md) | Encrypted backup format (`.vaulta`) and export/restore flow | Accepted | 2026-10-19 |
| [0007](./0007-encrypted-local-database.md) | Local vault storage moves from one encrypted blob to an encrypted database | Accepted | 2026-10-21 |
| [0008](./0008-android-autofill.md) | Android autofill service | Proposed | 2026-10-21 |

## Reading order for an external audit

An auditor who wants the cryptographic contract first should read, in this
order:

1. [0001 — Key derivation and encrypted blob format](./0001-crypto-key-derivation-and-encrypted-blob.md)
2. [0006 — Encrypted backup format](./0006-encrypted-backup-format.md)
3. [0002 — Sync model](./0002-sync-versioning-cas-idempotency-tombstones.md)
4. [0003 — Session policy and revocation](./0003-session-policy-and-revocation.md)

The same material is collected for auditors in
[`../reference/crypto-architecture.md`](../reference/crypto-architecture.md),
and the risks Vaulta accepts are described in
[`../explanation/threat-model.md`](../explanation/threat-model.md).

## Writing a new ADR

1. Take the next free number. Numbers are never reused, not even when an ADR
   is superseded.
2. Name the file `NNNN-<short-decision>.md`, in lowercase, with dashes.
3. Write Context, Decision and Consequences. Context and Consequences are the
   parts that get read six months later: record the forces and the costs, not
   the meeting.
4. List the ADR in the index table above, with its status and date.
5. Cross-reference it from the ADR it supersedes. Do not delete the old one.

Statuses used in this repository: **Proposed**, **Accepted**, and
**Superseded** (with a pointer to the ADR that replaced it).
