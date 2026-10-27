# AGENTS.md — `lib/features/autofill`

The Dart side of the Android autofill service: the `MethodChannel` the native `AutofillService` calls, and the handler that turns one fill query into an answer. Its edge is a one-question port — it may ask the vault for the items indexed under one host, and for nothing else.

The map of this module: `mise run repo-map --module lib/features/autofill`.

## Invariants

- There are exactly three answers: `locked`, `matched` and `searchOnly`. "No match" is not an error; only `matched` carries candidates, and the named constructors are the only way to build an answer.
- Matching is exact: the requested host is normalized by `vaultHostOfWebsite` and compared for equality. No fuzzy, substring or best-guess match exists.
- A locked vault reads nothing: the handler answers `locked` before touching the lookup.
- One answer carries at most `AutofillFillHandler.defaultMaxCandidates` (10) candidates.
- Fail closed: an exception while answering becomes `locked` with no candidates, and an unknown method raises `MissingPluginException`.
- Nothing is logged: a candidate carries a secret, so the safe amount of logging is none (ADR-008 §6).

## How it is tested

- `test/features/autofill/autofill_channel_test.dart` — pins the wire protocol: the matched answer, the search marker, the locked answer, `status`, the fail-closed path and the unknown method.
- `test/features/autofill/autofill_fill_handler_test.dart` — pins the matching rules: exact host only, no similar-host match, an empty answer while locked, the candidate cap, and that the handler asks for one host instead of decrypting every item.

## Do not touch

- The channel name string — it exists exactly once in Dart and once in Kotlin (`VaultaAutofillBridge.CHANNEL_NAME`) and keeps the historical `com.insyd.gestor_contrasenas/autofill` prefix.
- `AutofillVaultLookup` — it is deliberately not `VaultRepository` (ADR-008 §5); widening it to a full-vault read is an ADR change.
- The `locked` / `matched` / `searchOnly` wire strings — the Kotlin service switches on them.
- The "nothing is logged" rule — adding a `debugPrint` here leaks a secret.

## Boundaries

- Depends on: `lib/features/vault/domain` — the `VaultItem` type a candidate is built from.
- Depends on: `lib/core/storage` — `vaultHostOfWebsite`, the one host normalization rule.
- Depends on: `lib/core/security` — `VaultRepository`, used only by the fallback adapter when the storage has no host index.
- Never imports: `lib/features/*/presentation` — this module has no screen and never mounts one.
