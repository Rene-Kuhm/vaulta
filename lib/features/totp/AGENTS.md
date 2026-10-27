# AGENTS.md — `lib/features/totp`

One-time codes: the base32 decoder, the `otpauth://` URI parser and the RFC 6238 generator, plus the live code panel the entry detail screen mounts. Its edge is the secret — it lives in memory, is never written to disk and leaves the screen only through the sensitive clipboard.

The map of this module: `mise run repo-map --module lib/features/totp`.

## Invariants

- A malformed secret never becomes a plausible code: the base32 decoder and the URI parser both throw `FormatException` instead of dropping bytes.
- The code follows RFC 6238 (SHA-1, SHA-256 or SHA-512, dynamic truncation, 6 or 8 digits, zero padded) and the counter is computed in UTC, so the code does not depend on the device timezone.
- HOTP is rejected explicitly: `otpauth://hotp/` is counter-based and out of scope, and the parser says so instead of ignoring it.
- An unsupported algorithm, digit count or period is rejected, never silently defaulted to SHA-1, 6 digits and 30 seconds.
- `totpSecondsRemaining` never returns zero, so a countdown cannot show an expired code while the code is still valid.
- The secret stays in memory: the code is plain text (not selectable) and a copy goes through `SensitiveClipboardService`.

## How it is tested

- `test/features/totp/base32_test.dart` — pins the decoder: the RFC 4648 vectors, lowercase input, ignored spaces and padding, and every rejection.
- `test/features/totp/otp_auth_uri_test.dart` — pins the parser: the canonical and percent-encoded URIs, the defaults, the code a phone authenticator shows, and the rejection of HOTP, a missing secret, a bad secret, bad digits, a bad algorithm and a non-positive period.
- `test/features/totp/totp_test.dart` — pins the RFC 6238 Appendix B vectors for the three algorithms, the zero padding, the period boundary and the UTC counter.
- `test/features/totp/totp_code_panel_test.dart` — pins the panel: the grouped code, the countdown, the copy through the sensitive clipboard, and an unreadable secret reported instead of a code.
- `test/features/totp/vault_entry_detail_totp_test.dart` — pins that the panel appears only for an entry that carries an `otpauth://` URI.

## Do not touch

- The `otpAuthUri` field of `VaultItem` — it is serialized only when present, so the encrypted payload keeps its exact shape and the payload version does not move (4 today).
- The RFC 6238 parameters (digits, period, algorithm) — they are the contract with the authenticator apps.
- The clipboard path — a copied code goes through `SensitiveClipboardService`; a plain `Clipboard.setData` would lose the auto-clear.

## Boundaries

- Depends on: `lib/core/security` — `SensitiveClipboardService`, the only way a code leaves the screen.
- Depends on: `lib/app` — the theme and the shared panel.
- Never imports: `lib/features/vault` — the URI arrives as a string, so the TOTP module does not depend on the item model.
- Never imports: `lib/core/storage` — this module never writes the secret.
