# Vaulta documentation

This folder is the documentation of Vaulta, the encrypted password manager by
[TecnoDespegue](https://www.tecnodespegue.com/). It is organised with the
[Diátaxis](https://diataxis.fr) model: four kinds of document, each answering
a different question, and one folder per kind.

## Pick the folder that answers your question

| If you want to… | Go to | What you get |
| --- | --- | --- |
| Learn something by doing it, start to finish | [`tutorials/`](./tutorials/) | Guided walkthroughs with a result at the end |
| Do one specific task | [`how-to/`](./how-to/) | Recipes for a goal you already have |
| Look something up | [`reference/`](./reference/) | Tables, contracts, audits, templates |
| Understand why it works this way | [`explanation/`](./explanation/) | Reasoning, trade-offs, threat model |
| Know why a decision was made | [`adr/`](./adr/) | Numbered architecture decision records |

If a document answers two questions at once it is in the wrong folder. When
one does, this index says so.

## The four quadrants

### [`docs/tutorials/`](./tutorials/)

Learning-oriented. The reader is new to the subject and follows the steps in
order.

- [Create your first vault](./tutorials/create-your-first-vault.md) — install,
  create the master password, store your first credential, lock and unlock.
- [Import your existing passwords](./tutorials/import-your-existing-passwords.md) —
  bring a CSV, JSON, Chrome, Bitwarden, 1Password, LastPass, Notion or KeePass
  export into Vaulta.
- [Set up your development environment](./tutorials/set-up-your-development-environment.md) —
  clone, install the pinned toolchain, run the tests and the coverage gate.

### [`docs/how-to/`](./how-to/)

Task-oriented. The reader has a goal and needs the steps to reach it.

- [Cut a release](./how-to/release-process.md) — channels, tags, publishing,
  and how the app verifies what it downloaded.
- [Sign an Android release](./how-to/android-release-signing.md) — keystore
  setup, environment variables, and what happens when they are missing.
- [Run the release QA matrix](./how-to/release-qa-matrix.md) — the checks to
  complete before promoting any build.
- [Prepare a store submission](./how-to/store-release-checklist.md) — the
  external assets, secrets, accounts and policy decisions each store needs.
- [Run a private beta](./how-to/run-a-private-beta.md) — what testers may and
  may not do, and what to collect from them.
- [Apply the Supabase migrations](./how-to/apply-supabase-migrations.md) —
  the schema, the RPCs and the RLS policies behind optional sync.

### [`docs/reference/`](./reference/)

Lookup-oriented. The reader wants a fact, not a lesson.

- [Crypto architecture](./reference/crypto-architecture.md) — the entry point
  for an external crypto audit: index of sources, cryptographic contract, and
  the open questions for the auditor.
- [Security hardening status](./reference/security-hardening-status.md) — what
  each security control actually does today, with `file:line` evidence.
- [API < 30 biometric refusal verification](./reference/api30-biometric-refusal-verification.md) —
  the recorded run of the instrumented test that proves the refusal happens on
  a real device.
- [Privacy policy template](./reference/privacy-policy-template.md) — the
  template to adapt before publishing, pending legal and product review.

### [`docs/explanation/`](./explanation/)

Understanding-oriented. The reader wants the reasons behind the behaviour.

- [Threat model](./explanation/threat-model.md) — what Vaulta defends against,
  what it explicitly does not, and the residual risks the user accepts.
- [How Vaulta encrypts your vault](./explanation/how-vaulta-encrypts-your-vault.md)
  — from master password to stored record, without the code.

### [`docs/adr/`](./adr/)

One file per decision, numbered, never rewritten in place. See
[`adr/README.md`](./adr/README.md) for the index and the format.

## Conventions

- **Language.** Everything in this folder is written in English. The five
  oldest ADRs are frozen in Spanish because the decisions were taken in
  Spanish; their text was not rewritten during the 2026-10-25 migration.
- **Accuracy.** Where a page and the code disagree, the code wins. Pages that
  describe a snapshot say which commit they describe.
- **Publication assets.** Store screenshots and the project hero live in
  [`publication/`](./publication/) because the README and the screenshot
  golden test point at those exact paths.

## Related documents outside this folder

- [`../README.md`](../README.md) — the project README.
- [`../SECURITY.md`](../SECURITY.md) — how to report a vulnerability.
- [`../CHANGELOG.md`](../CHANGELOG.md) — what changed in each release.
- [`../odd/`](../odd/) and [`../openspec/`](../openspec/) — the historical
  task and change records that produced the current state.
