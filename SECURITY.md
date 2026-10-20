# Security Policy

Vaulta is an offline-first password manager. A security bug here can
expose a user's whole vault, so reports are welcome and handled
privately.

## Supported versions

Only the latest stable release line receives security fixes. Stable
releases are the `vX.Y.Z` tags published on the
[Releases page](https://github.com/Rene-Kuhm/vaulta/releases) and
marked **Latest**.

| Version                         | Supported |
| ------------------------------- | --------- |
| 1.1.x (latest stable)           | Yes       |
| < 1.1                           | No        |
| `dev-latest` pre-release builds | No (fixed by the next stable release) |

Please reproduce on the latest stable release before reporting.

## Reporting a vulnerability

**Do not open a public issue, discussion or pull request for a
vulnerability.**

Report it privately through GitHub Security Advisories:

1. Go to <https://github.com/Rene-Kuhm/vaulta/security/advisories/new>
   (repository **Security** tab → **Report a vulnerability**).
2. Include the affected version and platform (Android version / Windows
   version), steps to reproduce, the impact you observed, and a proof
   of concept if you have one.

Never include real vault contents, master passwords or other people's
data in a report. Use a throwaway test vault.

## What to expect

These are targets for a small project, not contractual SLAs:

| Step                                   | Target                     |
| -------------------------------------- | -------------------------- |
| Acknowledge the report                 | within 3 business days     |
| Initial assessment and severity        | within 10 business days    |
| Fix released for critical / high       | within 30 days of triage   |
| Fix released for medium / low          | next planned release       |

We will keep you updated in the advisory thread, credit you in the
advisory and the CHANGELOG unless you ask otherwise, and publish the
advisory once a fixed release is available. Please give us that time
before disclosing publicly.

## Scope

In scope:

- **Cryptography**: master password key derivation (Argon2id), DEK
  wrapping and item encryption (AES-256-GCM), nonce handling, blob
  format parsing and migrations — see
  [`docs/architecture/CRYPTO.md`](docs/architecture/CRYPTO.md) and
  [`ADR-001`](docs/architecture/ADR-001-crypto.md).
- Key storage: Android Keystore envelope keys, Windows Credential
  Manager, secure storage, biometric unlock.
- Unlock protections: attempt throttling and lockout, auto-lock,
  session handling and device revocation.
- Data leakage: screenshots / screen recording, clipboard handling,
  logs, backups, autofill, exported or imported files.
- Sync: authentication, authorization between users/devices, conflict
  handling that could leak or corrupt vault data.
- Updates and supply chain: the in-app updater (SHA-256 checksum and
  signing-certificate verification), release workflows and published
  artifacts.

Out of scope:

- Attacks that require an already unlocked, rooted/jailbroken or
  malware-compromised device, unless Vaulta makes them meaningfully
  easier.
- Physical access to an unlocked phone or desktop session.
- Missing hardening with no demonstrated impact (e.g. generic header
  or best-practice reports from automated scanners).
- Vulnerabilities in third-party services or dependencies that are
  already public and tracked upstream — but do tell us if Vaulta uses
  them in an exploitable way.
- Social engineering of maintainers or users.

## Verifying releases

Every stable release publishes a `SHA256SUMS` file next to its assets.
See [`docs/release-process.md`](docs/release-process.md) for how to
verify a download.
