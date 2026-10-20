# Security hardening status

What security controls Vaulta actually ships, what is being built on a branch, and what is only planned. This page exists so that the README, store listings and release notes never claim more than the code does. When this page and the code disagree, the code wins and this page is wrong.

**Snapshot of `feat/enterprise-closure` at `e0de33c` (2026-10-21).** Line numbers refer to that commit. The previous snapshot was `master` at `64b2260` (2026-08-13) and was badly out of date: it listed controls as "Planned" or "In progress (branch)" that had shipped weeks earlier, and it described the update channel as performing no integrity check at all. Both are corrected below with the commit that closed them.

## How to read the table

| Status | Meaning |
|---|---|
| **Shipped** | Merged and in the tree this snapshot describes. Evidence points at the code and, where it landed later than `64b2260`, at the commit that merged it. |
| **In progress (branch)** | Code exists on a feature branch, not merged, not in any release. |
| **Planned** | No code yet. Listed in the README roadmap. |

"Published builds" means the `vaulta.apk` that `.github/workflows/dev-apk-release.yml` uploads to the `dev-latest` release, and the manually uploaded stable release (`v1.0.22` at the time of writing, containing `vaulta.apk` and `vaulta-windows-bundle.zip`). **Shipped below means merged, not necessarily published** — several controls shipped after `v1.0.22` and are not in a store listing yet. The release contents listed at the bottom were last checked on 2026-08-13 and are not re-verified here.

> **Not covered by this page:** any security work that exists only on an
> unmerged feature branch under an unresolved decision. Nothing here
> describes such work as shipped, and nothing here should be read as
> covering it.

## Controls

### Vault cryptography

| Control | Status | Evidence |
|---|---|---|
| Argon2id master-key derivation: 64 MiB, 3 iterations, parallelism 1, **64-byte output**, one run per unlock | Shipped | `lib/core/security/master_password_service.dart:54` (iterations), `:59` (`_masterKeyBytes = 64`), `:67` (memory), `:68` (parallelism), Argon2id at `:358-362`. **Changed from the `64b2260` snapshot:** that page said "32-byte output", which was true before record v3. |
| The 64-byte master key is split with HKDF-SHA256 into a verifier half (`info="vaulta:v3:verifier"`) and a KEK half (`info="vaulta:v3:kek"`) | Shipped | `master_password_service.dart:62`, `:65` (labels), `:131` (`_splitMasterKey`), `:256` (`_splitMasterKey` body) |
| Master password NFC-normalized before the KDF; records written are `version: 3` with `pw_norm: "NFC"` | Shipped | `password_policy.dart:131` (`normalize`), `master_password_service.dart:121`, `master_password_record.dart:126-133` |
| One random 16-byte salt per record, shared by the verifier and the KEK | Shipped | `master_password_service.dart:122`, written to both fields at `:138` and `:141`. **Changed from `64b2260`**, which claimed two separate salts ("random 16-byte salts for verifier and KEK"); the v2 format had two, the v3 format has one. |
| Random 32-byte DEK per vault, wrapped with AES-256-GCM under the KEK half | Shipped | `master_password_service.dart:55` (`_keyBytes = 32`), `:132`, `:133`, `_wrapDek` at `:367-371` |
| Vault item payloads encrypted with AES-256-GCM | Shipped | `lib/core/security/aes_gcm_vault_crypto_service.dart:18` (`AesGcm.with256bits()`) |
| Each item sealed under **its own** HKDF-SHA256 key derived from the DEK, never under the DEK directly; item key version bound into the AAD | Shipped | `aes_gcm_vault_crypto_service.dart:29` (`payloadVersionV4 = 4`), `:35` (`aadDomainV4`), `:103` (HKDF, 32-byte output), `:264` and `:295` (sealed under the item key) |
| DEK held only in the in-memory session; dropped on lock | Shipped | `lib/core/security/vault_security_controller.dart:674` (`lock`), `:677` (`_vaultSession = null`) |
| External cryptographic audit | Planned | None. See the security note in `README.md` and `docs/architecture/CRYPTO.md`. |

### Unlock

| Control | Status | Evidence |
|---|---|---|
| Master password unlock on every platform | Shipped | `lib/core/security/vault_security_controller.dart:460` (`unlockWithPassword`) |
| Android biometric envelope key: RSA-2048 KeyStore, `setUserAuthenticationRequired(true)` **and** `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/KeystoreChannel.kt:275`, `:278-281`. The `AUTH_BIOMETRIC_STRONG` declaration was added in `a4fc61b`. |
| On API < 30 the envelope is **refused**, not downgraded | Shipped, untested | `KeystoreChannel.kt:329` (`MIN_BIOMETRIC_ONLY_AUTH_SDK = Build.VERSION_CODES.R`), `:229-239` (`buildKeySpecForDevice` throws `UnsupportedOperationException` below API 30), `:129-138` (`isAvailable` returns false), `:167-175` (`ensureKey` builds the spec **before** the alias check, so a leftover key cannot keep unlocking). **No automated coverage** — see the limit below. |
| **Biometric unlock support window: Android 11 (API 30) and newer only** | Shipped, accepted limit | See "Biometric unlock and Android API levels" below. The app itself installs from API 23 (`android/app/build.gradle.kts:52`, `minSdk = maxOf(flutter.minSdkVersion, 23)`, unchanged since `18d9bce`). |
| The biometric gate asks `canUseStrong`, not `canUseStrongOrCredential` | Shipped | `lib/core/security/native_biometric_auth_service.dart:256` (`a4fc61b`) |
| Exactly one `BiometricPrompt` per unlock, guaranteed by the type system | Shipped | `lib/app/bootstrap/password_manager_app.dart:127` (`sealed class BiometricStack`), `:141` (`AndroidKeystoreBiometricStack` = native provider + non-prompting gate), `:163` (`LocalAuthBiometricStack` = `local_auth` gate + inert provider), `:182` (`resolveBiometricStack`, the only branch). `a4fc61b`. |
| Android unlock prompt uses `BIOMETRIC_STRONG` with a `CryptoObject` wrapping the KeyStore cipher | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:240` (authenticator set), `:344` (`BiometricPrompt.CryptoObject(cipher)`), entry point `authenticateAndDecrypt` at `:226` |
| Android bypasses `local_auth` so the capability gate and the prompt read the same `BiometricManager` state | Shipped | `lib/app/bootstrap/password_manager_app.dart:182-188` (`resolveBiometricStack`) |
| Biometric unlock on Windows (Windows Hello), iOS, macOS, Linux | Not shipped | Non-Android targets get the inert `_NullEnvelopeKeyProvider` (`password_manager_app.dart:163`), and `_isBiometricCapableTarget` returns `_isMobileTarget` (`lib/core/security/biometric_unlock_service.dart:311`), so `unlock` returns `BiometricUnlockUnavailable` (`:217-219`). `local_auth` only names "Windows Hello" in a label (`lib/core/security/biometric_auth_service.dart:53-54`). |
| Master password attempt throttling: persisted exponential lockout, 4 free failures, 30 s doubling to a 15 min cap | Shipped | `lib/core/security/unlock_attempt_limiter.dart:103` (`freeAttempts = 4`), `:106` (`baseLockout`), `:109` (`maxLockout = 15 min`), `:140-148`. Merged in `5fd0c30`. The `64b2260` snapshot still listed this as "In progress (branch)". |

### Session and screen

| Control | Status | Evidence |
|---|---|---|
| Auto-lock when the app leaves the foreground (on by default) | Shipped | `lib/core/security/vault_security_controller.dart:134` (`_autoLockOnBackgroundEnabled = true`), `:875-884` (`handleAppLifecycleState`, locks on `inactive` / `hidden` / `paused`) |
| Idle auto-lock, 900 s (15 min) default, configurable, 0 disables | Shipped | `vault_security_controller.dart:110` (`defaultIdleTimeoutSeconds = 900`), `:135`, `:248-249` (`0` → `null` timeout), `:1443` (timer) |
| Clipboard auto-clear 30 s after copying a secret, only if the clipboard still holds that secret, plus the Android sensitive-content flag | Shipped | `lib/features/vault/presentation/vault_entry_detail_screen.dart:283` (`copySensitive`), `lib/core/security/sensitive_clipboard_service.dart:74` and `:129`. The `64b2260` snapshot marked this whole row "In progress (branch)" and said `_copySecret` set plain `ClipboardData`; merged in `c506c48`. |
| Screen-capture protection on Android (`FLAG_SECURE`: blocks screenshots, screen recording and the recents thumbnail) | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:104-105`. Merged in `c506c48`; the `64b2260` snapshot marked it "In progress (branch)" and claimed `FLAG_SECURE` "appears nowhere under `android/`". |

### Storage and platform

| Control | Status | Evidence |
|---|---|---|
| Secrets in `flutter_secure_storage` (Android Keystore-backed, Windows Credential Manager) | Shipped | `lib/core/security/flutter_secure_storage_service.dart:21-27` (per-platform `AndroidOptions` / `WindowsOptions` / `LinuxOptions`) |
| Android cloud backup and device-transfer extraction disabled | Shipped | `android/app/src/main/AndroidManifest.xml:15-17`, `android/app/src/main/res/xml/data_extraction_rules.xml` |
| Cleartext HTTP disallowed on Android | Shipped | `android/app/src/main/AndroidManifest.xml:18` |
| Main activity not exported; only the launcher alias is | Shipped | `android/app/src/main/AndroidManifest.xml:19-24` (`MainActivity`, `exported="false"`), `:39-50` (`.VaultaLauncherActivity`, the only `exported="true"` component besides the system-registered fingerprint dialog). The `FileProvider` (`:54-60`) and `ClipboardClearReceiver` (`:74-77`) are `exported="false"`. |
| Native Android autofill service | Planned | No `<service>` with `BIND_AUTOFILL_SERVICE` in `android/app/src/main/AndroidManifest.xml`, and no `AutofillService` class in `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/` (only `BiometricChannel.kt`, `KeystoreChannel.kt`, `MainActivity.kt`, `UpdateChannel.kt`). The "Access" tab (`lib/features/access/presentation/access_screen.dart`) is an explainer screen only. |
| App installs on Android 6 (API 23) and newer | Shipped | `android/app/build.gradle.kts:52` (`minSdk = maxOf(flutter.minSdkVersion, 23)`), unchanged since `18d9bce`. Note the biometric support window below — a wider install range is not a wider feature range. |

### Biometric unlock and Android API levels

**Biometric unlock requires Android 11 (API 30) or newer.** Below API 30
Vaulta has **no biometric unlock at all**, and the only way into the vault
is the master password. This is a deliberate trade, introduced by `a4fc61b`,
and it is a real loss of a feature on Android 6 through 10.

**Why.** `KeyGenParameterSpec.Builder.setUserAuthenticationParameters` and
`KeyProperties.AUTH_BIOMETRIC_STRONG` were both introduced in API 30
(`KeystoreChannel.kt:195-196`). On API 23-29 the only knobs are
`setUserAuthenticationRequired(true)` and the deprecated
`setUserAuthenticationValidityDurationSeconds`, and **neither restricts
which credential satisfies the requirement** — a key that requires user
auth on those releases is authorized by the device PIN, pattern or
password exactly as readily as by a fingerprint. There is no
keystore-level fix. `a4fc61b` chose to refuse rather than mint a key whose
declared guarantee is weaker than what the UI claims: `isAvailable()`
answers `false` (`KeystoreChannel.kt:129-138`) and `ensureKey` throws
(`:229-239`), so Dart never enrolls an envelope and the biometric toggle
stays off.

**The alternative the project did NOT take** is raising `minSdk` to 30
(`android/app/build.gradle.kts:52`). That would drop Android 6 through 10
outright — no install at all — in exchange for a feature those users would
still not get, since the same API level is the blocker. The current
choice keeps the app installable on API 23+ and removes the biometric
option there. Anyone shipping a store listing should say "biometric unlock
requires Android 11+" rather than implying universal availability.

**Known limit on the enforcement, not on the design:** this refusal has
**no automated test coverage**. Verifying it needs an API < 30 device or
emulator, and this repository has neither. The Dart half of the gate is
tested (`android_keystore_envelope_key_provider_test.dart`, 33 tests at
`e0de33c`, including the RED-able "credential-only device does not open the
biometric gate"); the Kotlin half below API 30 is **unverified by
execution** and rests on reading the code.

### Distribution and updates

| Control | Status | Evidence |
|---|---|---|
| Release APK signed with a persistent upload key from CI secrets; the build fails if a secret is missing | Shipped | `.github/workflows/dev-apk-release.yml:56-73`, `android/app/build.gradle.kts:20-23`, `:64-80` |
| In-app update channel: queries the `dev-latest` GitHub release and hands the APK to the system installer | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/UpdateChannel.kt:134` |
| In-app update verifies the APK against the release's published SHA-256 and against the signing certificate, and refuses to install on mismatch | Shipped | `UpdateChannel.kt:106-130` (`sha256File`, `verifyApkSigner`, `openInstallPrompt` requiring `expectedSha256`), `:393-403` (`sha256Hex`); `lib/core/update/update_service.dart:401-436` (fetch `SHA256SUMS`, refuse `checksumMissing` / `checksumMismatch` / `signatureMismatch`). Merged in `7b78e03`. **The `64b2260` snapshot claimed "the app does not verify a hash or signature itself"; that was false and is corrected here.** |
| Windows code signing (Authenticode) | Planned | The `vaulta.exe` in `v1.0.22/vaulta-windows-bundle.zip` has an empty PE security directory (checked 2026-08-13, see below). No workflow builds Windows. |
| Optional Supabase sync, off in published builds | Experimental, off | `lib/core/sync/device_sync_bootstrap.dart:46-50` returns `null` without `SUPABASE_URL`/`SUPABASE_ANON_KEY`; `.github/workflows/dev-apk-release.yml:73` builds with no `--dart-define`. |
| Sync carries the v4 item format (item key salt + item key version on the wire) | Shipped in code, **not verified against a backend** | `lib/core/security/local_encrypted_vault_repository.dart:429-439` (write side), `:568-579` (read side), migration `supabase/migrations/20261021120000_add_vault_item_key_salt.sql`. `51517c2`. **The SQL has never been run against a real Postgres** and no workflow applies it. |
| Encrypted export / backup (`.vaulta`, Argon2id, authenticated header) | Shipped | `lib/core/security/vault_backup_service.dart`, `lib/features/backup/`. Merged in `f718411`. The `64b2260` snapshot listed this as "Planned" and said "No export feature on `master`". Design: ADR-006. |
| Integrated TOTP | Planned | No TOTP or `otpauth` code under `lib/` (checked at `e0de33c`). |

## How the non-obvious rows were checked

Windows binary signing:

```bash
gh release download v1.0.22 --repo Rene-Kuhm/vaulta --pattern vaulta-windows-bundle.zip
unzip -o -q vaulta-windows-bundle.zip vaulta.exe -d x
# read the PE optional header's security data directory (index 4)
```

Output: `magic 0x20b security dir 0 0`, meaning a PE32+ image with no Authenticode certificate table.

Release contents:

```text
$ gh release list --repo Rene-Kuhm/vaulta
Vaulta para Android                                   dev-latest  2026-06-09
Vaulta v1.0.22 - Soporte oficial para Windows desktop  Latest  v1.0.22  2026-06-11
```

`v1.0.22` holds `vaulta.apk` and `vaulta-windows-bundle.zip`. `dev-latest` is rewritten by CI and holds only `vaulta.apk`.

Missing controls were checked by searching the tree at `e0de33c`:
`grep -rn "totp\|otpauth" lib` and `grep -rln "BIND_AUTOFILL_SERVICE\|AutofillService" android/` both return nothing, which is what keeps the TOTP and autofill rows at **Planned**. The old `64b2260` check also ran `grep -rn FLAG_SECURE android/` and `grep -rni "throttl\|lockout\|failedAttempt" lib` and found nothing; both of those **do** have implementations now (`MainActivity.kt:104`, `unlock_attempt_limiter.dart`), which is how the two rows above were found to be stale.

## Unverified

Stated rather than deleted, because an auditor should not have to guess
which claims were checked and which were not.

- **The API < 30 biometric refusal is not test-covered.** Verifying it
  needs an API < 30 device or emulator; this repository has neither. The
  Kotlin path (`KeystoreChannel.kt:129-138`, `:229-239`) is verified by
  reading only. A JUnit test over `sdkInt >= 30` would be tautological;
  Robolectric would add a dependency and a CI job, and that decision was
  not taken here.
- **The Supabase SQL migration has never been executed against a real
  Postgres.** `supabase/migrations/20261021120000_add_vault_item_key_salt.sql`
  (`51517c2`) is verified by reading only; no workflow in
  `.github/workflows/` applies it. The Dart side of that wire is tested.
- **The in-app security screen's capability flags are probably wrong.** It
  reads a static `PlatformSecurityPlan`
  (`lib/core/security/local_encrypted_vault_repository.dart:58-65`) that
  reports `biometricUnlock: false` and `hardwareBackedKeys: false`, which
  contradicts the Android KeyStore path above. Carried over from the
  `64b2260` snapshot and **not re-checked** in this pass; it is a code
  issue, not covered by this page.
- **User-facing copy does not name the API 30 floor.** On Android 6-10
  `canOfferBiometricToggle` is false
  (`lib/core/security/vault_security_controller.dart:256-258`), so the
  user is shown `securityBiometricUnavailable` — "No biometrics detected.
  You can still unlock with your master password."
  (`lib/l10n/app_en.arb:119`, shown at
  `lib/features/security/presentation/security_gate.dart:730`) — and
  `settingsBiometricUnavailableSubtitle` (`app_en.arb:28`,
  `lib/features/settings/presentation/settings_screen.dart:487`). Both
  conflate "no fingerprint enrolled" with "this Android release cannot
  express biometric-only KeyStore auth", so a user on a fingerprint-
  enrolled Android 9 is told the wrong reason. **Reported, not fixed:**
  localization and UI are outside this page's edit surface.
- Release contents and the Windows signing check below were last verified
  on 2026-08-13 against `v1.0.22` and are not re-verified in this pass.
- Unmerged security work under an unresolved decision is not described
  anywhere above.
