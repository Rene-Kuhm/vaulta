# Security hardening status

What security controls Vaulta actually ships, what is being built on a branch, and what is only planned. This page exists so that the README, store listings and release notes never claim more than the code does. When this page and the code disagree, the code wins and this page is wrong.

**Snapshot of `master` at `50c3d73` (2026-10-24).** Line numbers refer to that commit. The previous snapshot described `feat/enterprise-closure` at `e0de33c` (2026-10-21) and was out of date by the time that work reached `master`: it listed the native Android autofill service and integrated TOTP as "Planned" although both landed in the same line of work afterwards, it marked the in-app security screen as "In progress (branch `swarm/make-the-security-screen-report-real-hardw`)" although that branch was merged, and it said the sync wire had never been verified against a backend although a cross-device wrapped-DEK run was recorded on 2026-10-23. All of those are corrected below with the file and the commit that closed them.

That work was squash-merged onto `master` as `0492fc4` (2026-10-24), so its own commits are not in `master`'s history: everything that arrived with it is cited as `0492fc4`, and the individual commits remain reachable only through `origin/feat/enterprise-closure`. Controls that merged earlier keep their own merge commit.

Other queued issues are changing this tree at the same time. This page describes `50c3d73` and nothing after it; where a row depends on an issue that is still open, the row says so instead of predicting its outcome.

## How to read the table

| Status | Meaning |
|---|---|
| **Shipped** | Merged and in the tree this snapshot describes. Evidence points at the code and, when it landed after the previous snapshot, at the commit that merged it. |
| **In progress (branch)** | Code exists on a feature branch, not merged, not in any release. |
| **Planned** | No code yet. Listed in the README roadmap. |

"Published builds" means the `vaulta.apk` that `.github/workflows/dev-apk-release.yml` uploads to the `dev-latest` pre-release, and the manually uploaded stable release (`v1.0.22` at the time of writing, containing `vaulta.apk` and `vaulta-windows-bundle.zip`). **Shipped below means merged, not necessarily published** — every control that cites `0492fc4` shipped after `v1.0.22` and is not in a store listing yet. The release contents listed at the bottom were re-checked on 2026-10-24.

> **Not covered by this page:** any security work that exists only on an
> unmerged branch or in a queued issue. Nothing here describes such work as
> shipped, and nothing here should be read as covering it.

## Controls

### Vault cryptography

| Control | Status | Evidence |
|---|---|---|
| Argon2id master-key derivation: 64 MiB, 3 iterations, parallelism 1, **64-byte output**, one run per unlock | Shipped | `lib/core/security/master_password_service.dart:54` (iterations), `:59` (`_masterKeyBytes = 64`), `:67` (memory), `:68` (parallelism), Argon2id at `:358-363`. **Changed from the `64b2260` snapshot:** that page said "32-byte output", which was true before record v3. |
| The 64-byte master key is split with HKDF-SHA256 into a verifier half (`info="vaulta:v3:verifier"`) and a KEK half (`info="vaulta:v3:kek"`) | Shipped | `master_password_service.dart:62`, `:65` (labels), `:131` (`_splitMasterKey`), `:256` (`_splitMasterKey` body) |
| Master password NFC-normalized before the KDF; records written are `version: 3` with `pw_norm: "NFC"` | Shipped | `password_policy.dart:131` (`normalize`), `master_password_service.dart:121`, `master_password_record.dart:126-133` |
| One random 16-byte salt per record, shared by the verifier and the KEK | Shipped | `master_password_service.dart:122`, written to both fields at `:138` and `:141`. **Changed from `64b2260`**, which claimed two separate salts ("random 16-byte salts for verifier and KEK"); the v2 format had two, the v3 format has one. |
| Random 32-byte DEK per vault, wrapped with AES-256-GCM under the KEK half | Shipped | `master_password_service.dart:55` (`_keyBytes = 32`), `:132`, `:133`, `_wrapDek` at `:367-371` |
| Vault item payloads encrypted with AES-256-GCM | Shipped | `lib/core/security/aes_gcm_vault_crypto_service.dart:18` (`AesGcm.with256bits()`) |
| Each item sealed under **its own** HKDF-SHA256 key derived from the DEK, never under the DEK directly; item key version bound into the AAD | Shipped | `aes_gcm_vault_crypto_service.dart:29` (`payloadVersionV4 = 4`), `:35` (`aadDomainV4`), `:103` (HKDF, 32-byte output), `:264` and `:295` (sealed under the item key) |
| DEK held only in the in-memory session; dropped on lock | Shipped | `lib/core/security/vault_security_controller.dart:773` (`lock`), `:776` (`_vaultSession = null`) |
| External cryptographic audit | Planned | None. See the security note in `README.md` and `docs/architecture/CRYPTO.md`. |

### Unlock

| Control | Status | Evidence |
|---|---|---|
| Master password unlock on every platform | Shipped | `lib/core/security/vault_security_controller.dart:559` (`unlockWithPassword`) |
| Android biometric envelope key: RSA-2048 KeyStore, `setUserAuthenticationRequired(true)` **and** `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/KeystoreChannel.kt:275`, `:278-281`. The `AUTH_BIOMETRIC_STRONG` declaration arrived in `0492fc4`. |
| On API < 30 the envelope is **refused**, not downgraded | Shipped, untested | `KeystoreChannel.kt:329` (`MIN_BIOMETRIC_ONLY_AUTH_SDK = Build.VERSION_CODES.R`), `:229-239` (`buildKeySpecForDevice` throws `UnsupportedOperationException` below API 30), `:129-138` (`isAvailable` returns false), `:167-178` (`ensureKey` builds the spec **before** the alias check, so a leftover key cannot keep unlocking). **No automated coverage** — see the limit below; issue #22 covers running it on an API 29 device. |
| **Biometric unlock support window: Android 11 (API 30) and newer only** | Shipped, accepted limit | See "Biometric unlock and Android API levels" below. The app itself installs from API 23 (`android/app/build.gradle.kts:52`, `minSdk = maxOf(flutter.minSdkVersion, 23)`, unchanged since `18d9bce`). |
| The biometric gate asks `canUseStrong`, not `canUseStrongOrCredential` | Shipped | `lib/core/security/native_biometric_auth_service.dart:252-256` (`0492fc4`) |
| Exactly one `BiometricPrompt` per unlock, guaranteed by the type system | Shipped | `lib/app/bootstrap/password_manager_app.dart:212` (`sealed class BiometricStack`), `:225` (`AndroidKeystoreBiometricStack` = native provider + non-prompting gate), `:244` (`LocalAuthBiometricStack` = `local_auth` gate + inert provider), `:267` (`resolveBiometricStack`, the only branch). `0492fc4`. |
| Android unlock prompt uses `BIOMETRIC_STRONG` with a `CryptoObject` wrapping the KeyStore cipher | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:254` (authenticator set), `:358` (`BiometricPrompt.CryptoObject(cipher)`), entry point `authenticateAndDecrypt` at `:240` |
| Android bypasses `local_auth` so the capability gate and the prompt read the same `BiometricManager` state | Shipped | `lib/app/bootstrap/password_manager_app.dart:267-274` (`resolveBiometricStack`) |
| Biometric unlock on Windows (Windows Hello), iOS, macOS, Linux | Not shipped | Non-Android targets get the inert `_NullEnvelopeKeyProvider` (`password_manager_app.dart:244-248`), and `_isBiometricCapableTarget` returns `_isMobileTarget` (`lib/core/security/biometric_unlock_service.dart:310-311`), so both `canAttemptUnlock` (`:200-203`) and `unlock` (`:222-226`) answer unavailable. `local_auth` only names "Windows Hello" in a label (`lib/core/security/biometric_auth_service.dart:53-54`). |
| Master password attempt throttling: persisted exponential lockout, 4 free failures, 30 s doubling to a 15 min cap | Shipped | `lib/core/security/unlock_attempt_limiter.dart:103` (`freeAttempts = 4`), `:106` (`baseLockout`), `:109` (`maxLockout = 15 min`), `:140-148`. Merged in `5fd0c30`. The `64b2260` snapshot still listed this as "In progress (branch)". |
| The in-app security screen reports device capabilities by **asking the services that perform them**, with three states (available / not available / could not determine) | Shipped | `VaultSecurityController.probeSecurityPlan` in `lib/core/security/vault_security_controller.dart:341-364` answers each row from the wired service: secure storage from a real read (`:369-377`), the biometric gate from `NativeBiometricAuthService.probeCapability` (`lib/core/security/native_biometric_auth_service.dart:199`, asked at `vault_security_controller.dart:395-417`), the platform key from `AndroidKeystoreEnvelopeKeyProvider.probeHardwareBackedKeyAvailability` (`lib/core/security/android_keystore_envelope_key_provider.dart:249-268`). The states are `SecurityCapabilityState` in `lib/core/security/platform_security_plan.dart:15-26`, and `lib/features/security/presentation/security_capabilities_panel.dart:55-63`, `:100-125` renders an unknown state with its own word and icon, never as "not available"; the panel is mounted at `lib/features/settings/presentation/settings_screen.dart:836`. Covered by `test/core/security/vault_security_controller_test.dart` (real yes, real no, unknown) and `test/features/security/presentation/security_capabilities_panel_test.dart` (en + es). `0492fc4`. Replaces the static `PlatformSecurityPlan` table, which is gone. |

### Session and screen

| Control | Status | Evidence |
|---|---|---|
| Auto-lock when the app leaves the foreground (on by default) | Shipped | `lib/core/security/vault_security_controller.dart:136` (`_autoLockOnBackgroundEnabled = true`), `:979-1001` (`handleAppLifecycleState`, locks on `inactive` / `hidden` / `paused` / `detached`, and stands down for a declared long-running flow such as the import file picker) |
| Idle auto-lock, 900 s (15 min) default, configurable, 0 disables | Shipped | `vault_security_controller.dart:112` (`defaultIdleTimeoutSeconds = 900`), `:137`, `:247-251` (`0` → `null` timeout), `:1565-1584` (timer) |
| Clipboard auto-clear 30 s after copying a secret, only if the clipboard still holds that secret, plus the Android sensitive-content flag | Shipped | `lib/features/vault/presentation/vault_entry_detail_screen.dart:402-405` (`_copySecret` → `copySensitive`), `lib/core/security/sensitive_clipboard_service.dart:50` (`defaultClearAfter`), `:74` (`copySensitive`), `:126-135` (native hand-off), `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/SensitiveClipboard.kt:74-76` (`EXTRA_IS_SENSITIVE`, plus the pre-API-33 legacy key). The `64b2260` snapshot marked this whole row "In progress (branch)" and said `_copySecret` set plain `ClipboardData`; merged in `c506c48`. |
| Screen-capture protection on Android (`FLAG_SECURE`: blocks screenshots, screen recording and the recents thumbnail) | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:117-119`, and the autofill unlock screen sets it too (`android/app/src/main/kotlin/com/insyd/gestor_contrasenas/autofill/AutofillUnlockActivity.kt:201-206`). Merged in `c506c48`; the `64b2260` snapshot marked it "In progress (branch)" and claimed `FLAG_SECURE` "appears nowhere under `android/`". |

### Storage and platform

| Control | Status | Evidence |
|---|---|---|
| Secrets in `flutter_secure_storage` (Android Keystore-backed, Windows Credential Manager) | Shipped | `lib/core/security/flutter_secure_storage_service.dart:21-27` (per-platform `AndroidOptions` / `WindowsOptions` / `LinuxOptions`) |
| Android cloud backup and device-transfer extraction disabled | Shipped | `android/app/src/main/AndroidManifest.xml:15-17`, `android/app/src/main/res/xml/data_extraction_rules.xml` |
| Cleartext HTTP disallowed on Android | Shipped | `android/app/src/main/AndroidManifest.xml:18` |
| Main activity not exported; the only exported components are the launcher alias and the autofill service | Shipped | `android/app/src/main/AndroidManifest.xml:19-24` (`MainActivity`, `exported="false"`), `:39-50` (`.VaultaLauncherActivity`, exported), `:76-87` (`.autofill.VaultaAutofillService`, exported but guarded by `android.permission.BIND_AUTOFILL_SERVICE`, a signature-level permission only the system holds). The rest of this file is `exported="false"`: the `FileProvider` (`:54-62`), `AutofillUnlockActivity` (`:93-97`) and `ClipboardClearReceiver` (`:105-107`). The `FingerprintDialogActivity` entry (`:63-67`) only merges an icon into the copy the `androidx.biometric` library declares; this file sets no `exported` attribute there, so it does not decide that component's exposure. The autofill service declaration arrived in `0492fc4`. |
| Native Android autofill service | Shipped | Service declared with `BIND_AUTOFILL_SERVICE` and the `android.autofill` meta-data at `android/app/src/main/AndroidManifest.xml:76-87`, metadata at `android/app/src/main/res/xml/autofill_service.xml:27-31`; the service itself is `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/autofill/VaultaAutofillService.kt:70` (locked → no datasets plus an authentication intent, `:115-122`; host matching `:99-104`), the single-engine bridge is `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/autofill/VaultaAutofillBridge.kt:56`, the unlock screen is `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/autofill/AutofillUnlockActivity.kt:56`, and the Dart half is `lib/features/autofill/autofill_channel.dart:28` plus `lib/features/autofill/autofill_fill_handler.dart:129-190` (a fill reads one host lookup and never the whole vault). Design: `docs/architecture/ADR-008-autofill.md` (still marked "Proposed" there; the code above is what ships). `0492fc4`. Limits: the platform cannot bind the service below API 26, and app-package matching is limited to the exact host and the requesting package's **verified** web domains — there is no fuzzy matching. The "Access" tab (`lib/features/access/presentation/access_screen.dart`) is no longer only an explainer: it carries the lock-now action and the autofill hero card. |
| App installs on Android 6 (API 23) and newer | Shipped | `android/app/build.gradle.kts:52` (`minSdk = maxOf(flutter.minSdkVersion, 23)`), unchanged since `18d9bce`. Note the biometric support window below — a wider install range is not a wider feature range. |

### Biometric unlock and Android API levels

**Biometric unlock requires Android 11 (API 30) or newer.** Below API 30
Vaulta has **no biometric unlock at all**, and the only way into the vault
is the master password. This is a deliberate trade, introduced by `a4fc61b`
and shipped to `master` in `0492fc4`, and it is a real loss of a feature on
Android 6 through 10.

**Why.** `KeyGenParameterSpec.Builder.setUserAuthenticationParameters` and
`KeyProperties.AUTH_BIOMETRIC_STRONG` were both introduced in API 30
(`KeystoreChannel.kt:194-196`). On API 23-29 the only knobs are
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
emulator, and this repository has neither; the queued issue #22 is the one
that adds the instrumented test and runs it on an API 29 device. The Dart
half of the gate is tested (`android_keystore_envelope_key_provider_test.dart`,
33 tests at `50c3d73`, including the RED-able "credential-only device does
not open the biometric gate"); the Kotlin half below API 30 is
**unverified by execution** and rests on reading the code.

### Distribution and updates

| Control | Status | Evidence |
|---|---|---|
| Release APK signed with a persistent upload key from CI secrets; the build fails if a secret is missing | Shipped | `.github/workflows/dev-apk-release.yml:69-79`, `android/app/build.gradle.kts:21-23`, `:66-82` |
| In-app update channel: queries the GitHub release for the selected channel and hands the APK to the system installer | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/UpdateChannel.kt:196-235` — `/releases/latest` for the stable channel (the default and the fallback for an unknown value) and `/releases/tags/dev-latest` for the opt-in dev channel; the installer hand-off is `:494-529` (`verifyThenInstall`). `0492fc4`. |
| In-app update verifies the APK against the release's published SHA-256 and against the signing certificate, and refuses to install (deleting the file) on mismatch | Shipped | `UpdateChannel.kt:499-508` (checksum and signer, delete on mismatch), `:393` (`sha256Hex`); `lib/core/update/update_service.dart:397-438` (fetch `SHA256SUMS`, refuse `checksumMissing` / `checksumMismatch` / `signatureMismatch`). `0492fc4`. **The `64b2260` snapshot claimed "the app does not verify a hash or signature itself"; that was false and is corrected here.** |
| Windows code signing (Authenticode) | Planned | The `vaulta.exe` in `v1.0.22/vaulta-windows-bundle.zip` has an empty PE security directory (re-checked 2026-10-24, see below). `.github/workflows/release.yml:186` builds the Windows bundle, but no step signs it and no certificate is configured (`0492fc4`). |
| Optional Supabase sync, off in published builds | Experimental, off | `lib/core/sync/supabase_client_resolver.dart:19-21` returns `null` without `SUPABASE_URL`/`SUPABASE_ANON_KEY`; both publishing workflows build with no `--dart-define` (`.github/workflows/dev-apk-release.yml:94`, `.github/workflows/release.yml:139`). |
| Sync carries the v4 item format (item key salt + item key version on the wire) | Shipped, exercised once against a real backend | Queue side `lib/core/security/local_encrypted_vault_repository.dart:165-179`, which reads the salt and version out of the sealed payload in `:389-424` and queues **nothing** when a v4 envelope lacks them; the pull side reads the same two columns at `lib/core/sync/remote_vault_blob_change.dart:176-192`; columns `item_key_salt` / `item_key_version` (`lib/core/sync/supabase_remote_vault_sync_repository.dart:60`, `:121-122`), migration `supabase/migrations/20261021120000_add_vault_item_key_salt.sql:24-26`. `0492fc4`. The manual cross-device run on 2026-10-23 pushed a v4 item (key_version 4 + salt) through this backend and opened it on a second device — see the run recorded below. |
| Cross-device vault key: the wrapped DEK travels as `vault_keys` metadata and a second device adopts it | Shipped, exercised once against a real backend | `supabase/migrations/20261023140000_add_vault_key_sync.sql:23-28` (one row per user, `record_json` = the full `MasterPasswordRecord`), RPC calls at `lib/core/sync/supabase_vault_key_sync_repository.dart:19` (`rpc_vault_get_key`) and `:39` (`rpc_vault_put_key`), reconciliation in `lib/core/sync/vault_key_sync_service.dart:19`, wired at `lib/core/sync/device_sync_bootstrap.dart:103-104`. `0492fc4`. Verified on 2026-10-23 in one emulator with the vault backend running: device A pushed ciphertext and the wrapped DEK, then the "second device" was simulated in the same emulator with `pm clear` plus a fresh sign-in, which adopted the remote key, switched onboarding to "Unlock", and opened the item with the same master password (`odd/tasks/vault-key-cross-device-sync.md`, log L2). A newly adopted device does not refresh its dashboard until a pull-to-refresh — being fixed in issue #19. |
| Encrypted export / backup (`.vaulta`, Argon2id, authenticated header) | Shipped | `lib/core/security/vault_backup_service.dart`, `lib/features/backup/`. `0492fc4`. The `64b2260` snapshot listed this as "Planned" and said "No export feature on `master`". Design: ADR-006. |
| Integrated TOTP | Shipped | `lib/features/totp/domain/totp.dart:95-107` (RFC 6238 HMAC + dynamic truncation), `lib/features/totp/domain/otp_auth_uri.dart:66` (`otpauth://totp/` parsing; HOTP rejected), `lib/features/totp/presentation/totp_code_panel.dart:72` (one-second ticker), the `otpAuthUri` field at `lib/features/vault/domain/vault_item.dart:199` (serialized only when present, so the encrypted payload needs no version bump), rendered at `lib/features/vault/presentation/vault_entry_detail_screen.dart:240-246`. `0492fc4`. Correctness is pinned against the RFC 6238 Appendix B vectors in `test/features/totp/totp_test.dart:9` (SHA-1, SHA-256 and SHA-512 at each timestamp). |

## How the non-obvious rows were checked

Cross-device sync was checked by running it, not by reading it. The evidence
is the log entry, not this page: `odd/tasks/vault-key-cross-device-sync.md` L2
(2026-10-23) records device A pushing a v4 item and the wrapped DEK, the
`pm clear` + re-sign-in that simulated the second device, and the item opening
there under the same master password. L3 records the dashboard refresh gap that
issue #19 tracks. What this page adds is the state of the migrations and the CI:
`ls .github/workflows/` lists `dev-apk-release.yml`, `flutter-ci.yml` and
`release.yml`, and none of the three applies anything under
`supabase/migrations/`.

Windows binary signing:

```bash
D=$(mktemp -d) && cd "$D"
gh release download v1.0.22 --repo Rene-Kuhm/vaulta --pattern vaulta-windows-bundle.zip
unzip -o -q vaulta-windows-bundle.zip vaulta.exe -d x
# read the PE optional header's security data directory (index 4)
```

Output (2026-10-24): `magic 0x20b security dir 0 0`, meaning a PE32+ image with no Authenticode certificate table. The same result was recorded on 2026-08-13; `v1.0.22` has not been replaced since, so it is the same artifact.

Release contents (2026-10-24), timestamps trimmed to the date:

```text
$ gh release list --repo Rene-Kuhm/vaulta
Vaulta para Android (dev)                             Pre-release  dev-latest  2026-06-09
Vaulta v1.0.22 - Soporte oficial para Windows desktop  Latest      v1.0.22     2026-06-11
```

`v1.0.22` holds `vaulta.apk` (57 192 457 bytes) and `vaulta-windows-bundle.zip` (13 546 694 bytes). `dev-latest` is rewritten by CI — its assets were recreated on 2026-10-24 — and now holds `vaulta.apk` plus a `SHA256SUMS` asset, which is what the in-app updater downloads.

Controls that shipped since the previous snapshot were checked by searching the tree at `50c3d73`: `grep -rln "BIND_AUTOFILL_SERVICE\|AutofillService" android/` now lists the manifest, `res/xml/autofill_service.xml`, `VaultaAutofillService.kt` and `AutofillUnlockActivity.kt`, and `grep -rln "totp\|otpauth" lib` lists `lib/features/totp/`, the `otpAuthUri` field and the detail screen — which is what moves those two rows from **Planned** to **Shipped**. The old `64b2260` check ran `grep -rn FLAG_SECURE android/` and `grep -rni "throttl\|lockout\|failedAttempt" lib` and found nothing; both of those **do** have implementations now (`MainActivity.kt:117`, `unlock_attempt_limiter.dart`), which is how the two rows above were found to be stale.

The security screen row was checked against the code and its tests, not against a device: the three-state enum is `platform_security_plan.dart:15-26`, the assembler and its three probes are `vault_security_controller.dart:341-417`, and the "could not determine" rendering is asserted in `test/features/security/presentation/security_capabilities_panel_test.dart`.

## Unverified

Stated rather than deleted, because an auditor should not have to guess
which claims were checked and which were not.

- **The API < 30 biometric refusal is not test-covered.** Verifying it
  needs an API < 30 device or emulator and this repository has neither: there
  is no `android/app/src/androidTest/` directory and no `android/app/src/test/`
  directory at all. The Kotlin path (`KeystoreChannel.kt:129-138`, `:229-239`)
  is verified by reading only. Issue #22 adds the instrumented test and runs it
  on an API 29 device; until that lands, the row above says "verified by
  reading", not "verified by execution".
- **No Kotlin code in this app has an automated test at `50c3d73`.** The Dart
  side talks to the platform channels through fakes, so the native halves of
  autofill (`VaultaAutofillService.kt`), of the update verifier
  (`UpdateChannel.kt:499-508`), of the clipboard sensitive-content flag
  (`SensitiveClipboard.kt:74-76`), of screen-capture protection and of the
  KeyStore refusal are covered by reading. Nothing in this page claims an
  on-device run for them except the sync run described above.
- **Autofill has no recorded end-to-end run in the repository.**
  `integration_test/seed_autofill_vault_test.dart` seeds a real vault on a
  device so a person can exercise the fill flow by hand, and the Dart tests
  (`test/features/autofill/`) fake the platform channel; there is no artifact
  in the tree showing that a fill was executed on a device at this snapshot.
- **The Supabase SQL migration has never been run by CI.** No workflow in
  `.github/workflows/` applies `supabase/migrations/`, so which migration files
  a given deployment has is not visible from the repository. The only execution
  against a real Postgres recorded here is the manual run of 2026-10-23
  (`odd/tasks/vault-key-cross-device-sync.md` L2), which pushed a v4 item with
  its salt and read a `vault_keys` row — so those columns and RPCs accepted
  writes on that backend — but the log does not say which migration files were
  applied to it. A deployment that skips them fails closed: the client returns
  `null` instead of queueing a v4 upsert whose columns are missing
  (`local_encrypted_vault_repository.dart:402-407`), never a broken row. The Dart
  side of that wire is tested.
- **The security screen's answers were never captured on real hardware at this
  snapshot.** The probe and the three states are tested with fakes; the
  real-device behaviour of `probeCapability` and
  `probeHardwareBackedKeyAvailability` on an API < 30 device is the same gap
  issue #22 covers.
- **"Hardware-backed" cannot be proven from the Dart side.** The row of
  that name reports that the KeyStore-held key exists and is usable
  (`KeystoreChannel.isAvailable`, via
  `probeHardwareBackedKeyAvailability`); it does **not** report
  `KeyInfo.isInsideSecureHardware`, which the channel does not expose.
  On a device where AndroidKeyStore keys are software-backed the label
  is therefore optimistic, which is why the row's copy says
  "KeyStore-held key" (`lib/l10n/app_en.arb:59`) rather than
  "hardware-backed". Reading the TEE/StrongBox flag would need a new native
  call and was not added here.
- **One piece of user-facing copy still does not name the API 30 floor.** The
  security gate now does: `securityBiometricUnavailable` is "Biometric unlock
  is unavailable: no biometrics are enrolled, or this Android version cannot
  require a biometric." (`lib/l10n/app_en.arb:122`, shown at
  `lib/features/security/presentation/security_gate.dart:749`). The settings
  subtitle still reads "Biometrics are not configured or supported in this
  environment." (`app_en.arb:28`,
  `lib/features/settings/presentation/settings_screen.dart:487`), which does
  not distinguish "nothing enrolled" from "this Android release cannot express
  biometric-only KeyStore auth". **Reported, not fixed:** localization and UI
  are outside this page's edit surface.
- **Release contents and the Windows PE header were re-checked on 2026-10-24;
  nothing else in this page was verified by downloading an artifact.** Every
  other claim rests on the tree at `50c3d73`, its tests, or the log entry named
  beside it.
- **What the open issues will change is not predicted here.** Issue #19
  (dashboard refresh after a pull) and issue #22 (executed API 29 verification)
  are queued against this tree, and issue #20 reworks the unlock messages; a
  later snapshot must re-read those rows rather than assume this one still
  holds. Unmerged security work under an unresolved decision is not described
  anywhere above.
