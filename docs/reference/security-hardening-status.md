# Security hardening status

What security controls Vaulta actually ships, what is being built on a branch, and what is only planned. This page exists so that the README, store listings and release notes never claim more than the code does. When this page and the code disagree, the code wins and this page is wrong.

**Snapshot of `master` at `4148fd59` (2026-10-25).** Line numbers refer to that commit. The page was checked against that tree on **2026-10-25**.

The previous snapshot was `50c3d73` (2026-10-24, PR #25). It was correct about the enterprise work that squash-merged as `0492fc4`, but seven pull requests landed after it and moved the tree underneath the page: #26 (issue #19), #27 (issue #20), #28 (issue #23), #29 (issue #21), #30 (issue #22), #34 (issue #31) and #35 (issue #32). The rows those pull requests changed still said "Planned", "In progress (branch)" or "not test-covered" for things that had already shipped, and the "Unverified" section still claimed that there was no `android/app/src/androidTest/` directory, that the dashboard did not refresh itself after a pull, and that no workflow applied `supabase/migrations/`. All of that is corrected below, and each correction names the file, the line and the commit that closed it.

The enterprise work that squash-merged onto `master` as `0492fc4` (2026-10-24) is cited as `0492fc4` throughout: its own commits are not in `master`'s history and stay reachable only through `origin/feat/enterprise-closure`. Controls that merged earlier keep their own merge commit.

## What changed since the previous snapshot

| PR | Issue | Commit | What it changed here |
|---|---|---|---|
| #25 | #18 | `50c3d73` | README only. This is the commit the previous snapshot named; no control changed. |
| #26 | #19 | `1150596` | The dashboard now re-reads the vault on its own after a pull or a remote key adoption. The row "The dashboard refreshes itself after a pull" below is new. |
| #27 | #20 | `7dd2ced` | The unlock path reports failures through typed, localized messages and the controller no longer carries Spanish literals. Two new rows below. |
| #28 | #23 | `ce7307a` | This page, rebased onto the tree of the day. Its content is superseded by this snapshot. |
| #29 | #21 | `91492bf` | `VaultItem` gained an optional `isFavorite` flag inside the encrypted item payload. The row "The encrypted item payload gained an optional `isFavorite` flag" below is new. |
| #30 | #22 | `013400d` | The instrumented test that drives the API < 30 refusal on a device. The refusal is now "verified by execution", and the "Unverified" section no longer claims there is no `androidTest/` directory. |
| #34 | #31 | `10b08dc` | The settings subtitle now tells "no biometrics are enrolled" apart from "this Android cannot require biometric-only authentication". |
| #35 | #32 | `4148fd5` | CI applies `supabase/migrations/` to a clean PostgreSQL on every pull request, so "no workflow ever runs the migrations" is no longer true. |

## How to read the table

| Status | Meaning |
|---|---|
| **Shipped** | Merged and in the tree this snapshot describes. Evidence points at the code and, when it landed after the previous snapshot, at the commit that merged it. |
| **Shipped, verified by execution** | Merged, and the behaviour was observed running on a device or an emulator, not only read. |
| **In progress (branch)** | Code exists on a feature branch, not merged, not in any release. No row uses it at this snapshot. |
| **Planned** | No code yet. Listed in the README roadmap. |

"Published builds" means the `vaulta.apk` that `.github/workflows/dev-apk-release.yml` uploads to the `dev-latest` pre-release, and the manually uploaded stable release (`v1.0.22` at the time of writing, containing `vaulta.apk` and `vaulta-windows-bundle.zip`). **Shipped below means merged, not necessarily published** — every control that cites a commit after `v1.0.22` shipped after that release and is not in a store listing yet. The release contents listed at the bottom were re-checked on 2026-10-25.

> **Not covered by this page:** any security work that exists only on an
> unmerged branch or in a queued issue. Nothing here describes such work as
> shipped, and nothing here should be read as covering it.

## Controls

### Vault cryptography

| Control | Status | Evidence |
|---|---|---|
| Argon2id master-key derivation: 64 MiB, 3 iterations, parallelism 1, **64-byte output**; the verifier and the KEK are two HKDF halves of that one output, not two derivations | Shipped | `lib/core/security/master_password_service.dart:79` (3 iterations), `:84` (`_masterKeyBytes = 64`), `:92` (65536 KiB = 64 MiB), `:93` (parallelism 1), the Argon2id construction at `:405-411` (`Argon2id(...)` + `deriveKeyFromPassword`), the split at `:303-312`. An unlock derives the master key twice — once to check the verifier (`:200-207`) and once to unwrap the DEK (`:286-293`) — and each of those two runs already yields both halves, which is what replaced the v2 scheme of two derivations under two salts (the code's own note at `:137-141`). **Changed from the `64b2260` snapshot:** that page said "32-byte output", which was true before record v3. |
| The 64-byte master key is split with HKDF-SHA256 into a verifier half (`info="vaulta:v3:verifier"`) and a KEK half (`info="vaulta:v3:kek"`) | Shipped | `master_password_service.dart:87` (`_verifierInfo`), `:90` (`_kekInfo`), `:303-312` (`_splitMasterKey`), `:156` (the call) |
| Master password NFC-normalized before the KDF; records written are `version: 3` with `pw_norm: "NFC"` | Shipped | `password_policy.dart:131` (`normalize`), `master_password_service.dart:146` (the call), `:179` (`pwNorm: MasterPasswordRecord.nfcMarker`), `master_password_record.dart:126-133` |
| One random 16-byte salt per record, shared by the verifier and the KEK | Shipped | `master_password_service.dart:147` (`_randomBytes(16)`), written to both fields at `:163` and `:166`. **Changed from `64b2260`**, which claimed two separate salts ("random 16-byte salts for verifier and KEK"); the v2 format had two, the v3 format has one. |
| Random 32-byte DEK per vault, wrapped with AES-256-GCM under the KEK half | Shipped | `master_password_service.dart:80` (`_keyBytes = 32`), `:157` (the random DEK), `:158` (the wrap), `_wrapDek` at `:414-425` |
| Vault item payloads encrypted with AES-256-GCM | Shipped | `lib/core/security/aes_gcm_vault_crypto_service.dart:18` (`AesGcm.with256bits()`) |
| Each item sealed under **its own** HKDF-SHA256 key derived from the DEK, never under the DEK directly; item key version bound into the AAD | Shipped | `aes_gcm_vault_crypto_service.dart:29` (`payloadVersionV4 = 4`), `:35` (`aadDomainV4`), `:103` (HKDF, 32-byte output), `:264` and `:295` (sealed under the item key) |
| The encrypted item payload gained an optional `isFavorite` flag, with **no payload version bump** | Shipped | `lib/features/vault/domain/vault_item.dart:221` (the field), `:260` (serialized only when true), `:287` (a payload without the field decodes as `false`). The payload version did not move: `aes_gcm_vault_crypto_service.dart:29` is still `4`. Merged in `91492bf` (PR #29, issue #21). |
| DEK held only in the in-memory session; dropped on lock | Shipped | `lib/core/security/vault_security_controller.dart:786` (`lock`), `:793` (`_vaultSession = null`) |
| External cryptographic audit | Planned | None. See the security note in `README.md` and `docs/reference/crypto-architecture.md`. |

### Unlock

| Control | Status | Evidence |
|---|---|---|
| Master password unlock on every platform | Shipped | `lib/core/security/vault_security_controller.dart:541` (`unlockWithPassword`) |
| A corrupt vault fails with a typed error, not with a raw exception | Shipped | `lib/core/security/vault_security_controller.dart:1679-1695` (`_deriveVaultKey` catches `VaultKeyUnavailableException` and sets `VaultSecurityMessageCode.vaultCannotBeOpened`), the code at `lib/core/security/vault_security_message.dart:76`, its copy at `lib/features/security/presentation/vault_security_message_l10n.dart:57`. Merged in `7dd2ced` (PR #27, issue #20). |
| Every unlock failure is a code, and the UI maps it to the app's language | Shipped | The controller assigns `VaultSecurityMessage` values, never a literal: `vault_security_controller.dart:137` (the field), `:551` (one of the 55 `VaultSecurityMessageCode` references in that file), the enum at `lib/core/security/vault_security_message.dart:19`, the English/Spanish mapping at `lib/features/security/presentation/vault_security_message_l10n.dart:1-149`, the copy in `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb`, and the gate renders it at `lib/features/security/presentation/security_gate.dart:1302-1309`. Merged in `7dd2ced` (PR #27, issue #20). **The previous snapshot described the controller as carrying the copy hardcoded in Spanish; it does not anymore.** |
| Android biometric envelope key: RSA-2048 KeyStore, `setUserAuthenticationRequired(true)` **and** `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/KeystoreChannel.kt:267` (`setUserAuthenticationRequired(true)`), `:270-272` (`setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`). The `AUTH_BIOMETRIC_STRONG` declaration arrived in `0492fc4`. |
| On API < 30 the envelope is **refused**, not downgraded | Shipped, **verified by execution** | `KeystoreChannel.kt:321` (`MIN_BIOMETRIC_ONLY_AUTH_SDK = Build.VERSION_CODES.R`), `:209-210` (`supportsBiometricOnlyAuth()`), `:220-231` (`buildKeySpecForDevice` throws `UnsupportedOperationException` below API 30), `:129-138` (`isAvailable` returns false), `:167-178` (`ensureKey` builds the spec **before** the alias check, so a leftover key cannot keep unlocking). The instrumented test `android/app/src/androidTest/kotlin/com/insyd/gestor_contrasenas/KeystoreChannelApiRefusalTest.kt:85` drives the real channel on the device it runs on; the run is recorded in `docs/reference/api30-biometric-refusal-verification.md`. Merged in `013400d` (PR #30, issue #22). |
| **Biometric unlock support window: Android 11 (API 30) and newer only** | Shipped, accepted limit | See "Biometric unlock and Android API levels" below. The app itself installs from API 23 (`android/app/build.gradle.kts:52`, `minSdk = maxOf(flutter.minSdkVersion, 23)`, unchanged since `18d9bce`). |
| The biometric gate asks `canUseStrong`, not `canUseStrongOrCredential` | Shipped | `lib/core/security/native_biometric_auth_service.dart:196` (`if (cap.canUseStrong)`) |
| Exactly one `BiometricPrompt` per unlock, guaranteed by the type system | Shipped | `lib/app/bootstrap/password_manager_app.dart:222` (`sealed class BiometricStack`), `:235` (`AndroidKeystoreBiometricStack` = native provider + non-prompting gate), `:254` (`LocalAuthBiometricStack` = `local_auth` gate + inert provider), `:277-284` (`resolveBiometricStack`, the only branch). `0492fc4`. |
| Android unlock prompt uses `BIOMETRIC_STRONG` with a `CryptoObject` wrapping the KeyStore cipher | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:267` (authenticator set), `:371` (`BiometricPrompt.CryptoObject(cipher)`), entry point `authenticateAndDecrypt` at `:253` |
| Android bypasses `local_auth` so the capability gate and the prompt read the same `BiometricManager` state | Shipped | `lib/app/bootstrap/password_manager_app.dart:277-284` (`resolveBiometricStack`) |
| The settings subtitle tells "no biometrics enrolled" apart from "this Android cannot require biometric-only auth" | Shipped | The native answer: `KeystoreChannel.kt:209-210` (`supportsBiometricOnlyAuth()`), returned in the probe map at `MainActivity.kt:188`; carried by `NativeBiometricCapability.supportsBiometricOnlyAuth` (`lib/core/security/native_biometric_auth_service.dart:77`, read at `:248`); the UI picks the copy from it at `lib/features/settings/presentation/settings_screen.dart:146-160` (the API-30 branch at `:151-153`); the strings are `lib/l10n/app_en.arb:29` and `lib/l10n/app_es.arb`. Merged in `10b08dc` (PR #34, issue #31). **The previous snapshot reported this copy gap as open; it is closed.** |
| Biometric unlock on Windows (Windows Hello), iOS, macOS, Linux | Not shipped | Non-Android targets get the inert `_NullEnvelopeKeyProvider` (`password_manager_app.dart:258`, the class at `:286`), and `_isBiometricCapableTarget` returns `_isMobileTarget` (`lib/core/security/biometric_unlock_service.dart:327-328`), so both `canAttemptUnlock` (`:203-205`) and `unlock` (`:227`) answer unavailable. `local_auth` only names "Windows Hello" in a label (`lib/core/security/biometric_auth_service.dart:53-54`). |
| Master password attempt throttling: persisted exponential lockout, 4 free failures, 30 s doubling to a 15 min cap | Shipped | `lib/core/security/unlock_attempt_limiter.dart:103` (`freeAttempts = 4`), `:106` (`baseLockout`), `:109` (`maxLockout = 15 min`), `:140-148`. Merged in `5fd0c30`. The `64b2260` snapshot still listed this as "In progress (branch)". |
| The in-app security screen reports device capabilities by **asking the services that perform them**, with three states (available / not available / could not determine) | Shipped | `VaultSecurityController.probeSecurityPlan` in `lib/core/security/vault_security_controller.dart:317-330` answers each row from the wired service: secure storage from a real read (`:345-353`), the biometric gate from `NativeBiometricAuthService.probeCapability` (`lib/core/security/native_biometric_auth_service.dart:229`, asked at `vault_security_controller.dart:371-385`), the platform key from `AndroidKeystoreEnvelopeKeyProvider.probeHardwareBackedKeyAvailability` (`lib/core/security/android_keystore_envelope_key_provider.dart:249-268`), and an unanswered probe is detected by `vault_security_controller.dart:400-405`. The states are `SecurityCapabilityState` in `lib/core/security/platform_security_plan.dart:15-26`, and `lib/features/security/presentation/security_capabilities_panel.dart:100-124` renders an unknown state with its own word and icon, never as "not available"; the panel is mounted at `lib/features/settings/presentation/settings_screen.dart:875`. Covered by `test/core/security/vault_security_controller_test.dart` (real yes, real no, unknown) and `test/features/security/presentation/security_capabilities_panel_test.dart` (en + es). `0492fc4`. Replaces the static `PlatformSecurityPlan` table, which is gone. |

### Session and screen

| Control | Status | Evidence |
|---|---|---|
| Auto-lock when the app leaves the foreground (on by default) | Shipped | `lib/core/security/vault_security_controller.dart:139` (`_autoLockOnBackgroundEnabled = true`), `:1012-1044` (`handleAppLifecycleState` locks on `inactive` / `hidden` / `paused` / `detached`, and stands down for a declared long-running flow such as the import file picker) |
| Idle auto-lock, 900 s (15 min) default, configurable, 0 disables | Shipped | `vault_security_controller.dart:115` (`defaultIdleTimeoutSeconds = 900`), `:140`, `:232` (`0` → `null` timeout), `:1620-1642` (timer) |
| Clipboard auto-clear 30 s after copying a secret, only if the clipboard still holds that secret, plus the Android sensitive-content flag | Shipped | `lib/features/vault/presentation/vault_entry_detail_screen.dart:469-472` (`_copySecret` → `copySensitive`), `lib/core/security/sensitive_clipboard_service.dart:50` (`defaultClearAfter`), `:74` (`copySensitive`), `:126-135` (native hand-off), `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/SensitiveClipboard.kt:74-76` (`EXTRA_IS_SENSITIVE`, plus the pre-API-33 legacy key). The `64b2260` snapshot marked this whole row "In progress (branch)" and said `_copySecret` set plain `ClipboardData`; merged in `c506c48`. |

### Storage and platform

| Control | Status | Evidence |
|---|---|---|
| Secrets in `flutter_secure_storage` (Android Keystore-backed, Windows Credential Manager) | Shipped | `lib/core/security/flutter_secure_storage_service.dart:21-27` (per-platform `AndroidOptions` / `WindowsOptions` / `LinuxOptions`) |
| Android cloud backup and device-transfer extraction disabled | Shipped | `android/app/src/main/AndroidManifest.xml:15-17`, `android/app/src/main/res/xml/data_extraction_rules.xml` |
| Cleartext HTTP disallowed on Android | Shipped | `android/app/src/main/AndroidManifest.xml:18` |
| Main activity not exported; the only exported components are the launcher alias and the autofill service | Shipped | `android/app/src/main/AndroidManifest.xml:19-24` (`MainActivity`, `exported="false"`), `:39-50` (`.VaultaLauncherActivity`, exported), `:76-87` (`.autofill.VaultaAutofillService`, exported but guarded by `android.permission.BIND_AUTOFILL_SERVICE`, a signature-level permission only the system holds). The rest of this file is `exported="false"`: the `FileProvider` (`:54-62`), `AutofillUnlockActivity` (`:93-97`) and `ClipboardClearReceiver` (`:105-107`). The `FingerprintDialogActivity` entry (`:63-67`) only merges an icon into the copy the `androidx.biometric` library declares; this file sets no `exported` attribute there, so it does not decide that component's exposure. The autofill service declaration arrived in `0492fc4`. |
| Native Android autofill service | Shipped | Service declared with `BIND_AUTOFILL_SERVICE` and the `android.autofill` meta-data at `android/app/src/main/AndroidManifest.xml:76-87`, metadata at `android/app/src/main/res/xml/autofill_service.xml:27-31`; the service itself is `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/autofill/VaultaAutofillService.kt:70` (locked → no datasets plus an authentication intent, `:115-122`; host matching `:99-104`), the single-engine bridge is `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/autofill/VaultaAutofillBridge.kt:56`, the unlock screen is `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/autofill/AutofillUnlockActivity.kt:56`, and the Dart half is `lib/features/autofill/autofill_channel.dart:28` plus `lib/features/autofill/autofill_fill_handler.dart:179-192` (a fill **returns** only exact-host matches and never guesses: with no session it reads nothing, then answers from `AutofillVaultLookup.findByHost`, else with the search marker). What it *reads* depends on the storage the lookup is wired to, not on the handler: with a host index it reads one host (`password_manager_app.dart:107`), and on the default blob storage — `password_manager_app.dart:102-115`, which passes no `findByHost` — it falls back to one full vault read plus an exact-host comparison (`autofill_fill_handler.dart:139-144`, `:170-176`), so the fallback can miss but never guess. Design: `docs/adr/0008-android-autofill.md` (still marked "Proposed" there; the code above is what ships). `0492fc4`. Limits: the platform cannot bind the service below API 26, and app-package matching is limited to the exact host and the requesting package's **verified** web domains — there is no fuzzy matching. The "Access" tab (`lib/features/access/presentation/access_screen.dart`) is no longer only an explainer: it carries the lock-now action and the autofill hero card. |
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
(`:220-231`), so Dart never enrolls an envelope and the biometric toggle
stays off.

**The alternative the project did NOT take** is raising `minSdk` to 30
(`android/app/build.gradle.kts:52`). That would drop Android 6 through 10
outright — no install at all — in exchange for a feature those users would
still not get, since the same API level is the blocker. The current
choice keeps the app installable on API 23+ and removes the biometric
option there. Anyone shipping a store listing should say "biometric unlock
requires Android 11+" rather than implying universal availability.

**How this is known now.** The refusal used to be "verified by reading"
only; since `013400d` (PR #30, issue #22) it is **verified by execution**.
The instrumented suite
`android/app/src/androidTest/kotlin/com/insyd/gestor_contrasenas/KeystoreChannelApiRefusalTest.kt`
drives the production channel through the same entry point Dart uses, on a
real device, with the real `AndroidKeyStore` of that device, and asserts the
behaviour instead of the SDK constant. It was executed on 2026-10-24 on an
API 29 emulator: the two below-30 tests passed and the API-30+ test was
skipped by a JUnit assumption. The run, the device, the exact command and a
mutation check (the below-30 branch replaced with a key build, which makes
the suite fail) are recorded in `docs/reference/api30-biometric-refusal-verification.md`.
The Dart half of the gate keeps its own tests
(`test/core/security/android_keystore_envelope_key_provider_test.dart`).
What is still **not** executed is listed under "Unverified" below.

### Distribution and updates

| Control | Status | Evidence |
|---|---|---|
| Release APK signed with a persistent upload key from CI secrets; the build fails if a secret is missing | Shipped | `.github/workflows/dev-apk-release.yml:69-79`, `android/app/build.gradle.kts:21-24`, `:73-82` |
| In-app update channel: queries the GitHub release for the selected channel and hands the APK to the system installer | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/UpdateChannel.kt:193-202` — `/releases/latest` for the stable channel (the default and the fallback for an unknown value) and `/releases/tags/dev-latest` for the opt-in dev channel; the installer hand-off is `:494-529` (`verifyThenInstall`). `0492fc4`. |
| In-app update verifies the APK against the release's published SHA-256 and against the signing certificate, and refuses to install (deleting the file) on mismatch | Shipped | `UpdateChannel.kt:499-508` (checksum and signer, delete on mismatch), `:393` (`sha256Hex`); `lib/core/update/update_service.dart:33-46` (the three refusal reasons), `:401-405` (`checksumMissing`), `:424-429` (`checksumMismatch`), `:433-438` (`signatureMismatch`). `0492fc4`. **The `64b2260` snapshot claimed "the app does not verify a hash or signature itself"; that was false and is corrected here.** |
| Windows code signing (Authenticode) | Planned | The `vaulta.exe` in `v1.0.22/vaulta-windows-bundle.zip` has an empty PE security directory (re-checked 2026-10-25, see below). `.github/workflows/release.yml:186` builds the Windows bundle, but no step signs it and no certificate is configured (`0492fc4`). |
| Optional Supabase sync, off in published builds | Experimental, off | `lib/core/sync/supabase_client_resolver.dart:19-21` returns `null` without `SUPABASE_URL`/`SUPABASE_ANON_KEY`; both publishing workflows build with no `--dart-define` (`.github/workflows/dev-apk-release.yml:94`, `.github/workflows/release.yml:139`). |
| Sync carries the v4 item format (item key salt + item key version on the wire) | Shipped, exercised once against a real backend | Queue side `lib/core/security/local_encrypted_vault_repository.dart:176-177`, which reads the salt and version out of the sealed payload in `:397-401` and queues **nothing** when a v4 envelope lacks them (`:402-407`); the pull side reads the same two columns at `lib/core/sync/remote_vault_blob_change.dart:182-185` and `:190-194`; columns `item_key_salt` / `item_key_version` (`lib/core/sync/supabase_remote_vault_sync_repository.dart:60`, `:121-122`), migration `supabase/migrations/20261021120000_add_vault_item_key_salt.sql:24-26`. `0492fc4`. The manual cross-device run on 2026-10-23 pushed a v4 item (key_version 4 + salt) through this backend and opened it on a second device — see the run recorded below. |
| Cross-device vault key: the wrapped DEK travels as `vault_keys` metadata and a second device adopts it | Shipped, exercised once against a real backend | `supabase/migrations/20261023140000_add_vault_key_sync.sql:23-28` (one row per user, `record_json` = the full `MasterPasswordRecord`), RPC calls at `lib/core/sync/supabase_vault_key_sync_repository.dart:19` (`rpc_vault_get_key`) and `:38-41` (`rpc_vault_put_key`), reconciliation in `lib/core/sync/vault_key_sync_service.dart:20`, wired at `lib/core/sync/device_sync_bootstrap.dart:112-117`. `0492fc4`. Verified on 2026-10-23 in one emulator with the vault backend running: device A pushed ciphertext and the wrapped DEK, then the "second device" was simulated in the same emulator with `pm clear` plus a fresh sign-in, which adopted the remote key, switched onboarding to "Unlock", and opened the item with the same master password (`odd/tasks/vault-key-cross-device-sync.md`, log L2). |
| The dashboard refreshes itself after a pull, with no user gesture | Shipped | The signal is `lib/core/sync/vault_change_signal.dart:58` (`VaultChangeSignal`), published at `:70` (`notifyVaultChanged`); the pull publishes it at `lib/core/sync/bidirectional_sync_service.dart:251` and the remote-key adoption at `lib/core/sync/vault_key_sync_service.dart:65`. The signal is created once in the bootstrap (`lib/app/bootstrap/password_manager_app.dart:54`), forwarded through the shell (`lib/features/home/presentation/app_shell.dart:74`) and subscribed by the dashboard (`lib/features/vault/presentation/vault_dashboard_screen.dart:99`, the handler at `:119`). It is event driven, not polled: the signal carries no vault content (`vault_change_signal.dart:16-20`), and the repository interface did not change. Merged in `1150596` (PR #26, issue #19). **The previous snapshot said a newly adopted device "does not refresh its dashboard until a pull-to-refresh — being fixed in issue #19"; that gap is closed.** |
| The dashboard can filter the vault by favorite entries | Shipped | `lib/features/vault/presentation/vault_dashboard_screen.dart:1005` (`_VaultFilter { all, weak, favorites, withNotes }`), the predicate at `:291` (`_VaultFilter.favorites => item.isFavorite`), the dropdown at `:862-868`, the flag itself at `lib/features/vault/domain/vault_item.dart:221`. Merged in `91492bf` (PR #29, issue #21). The flag is optional inside the encrypted payload and does not change the payload version. |
| Encrypted export / backup (`.vaulta`, Argon2id, authenticated header) | Shipped | `lib/core/security/vault_backup_service.dart`, `lib/features/backup/`. `0492fc4`. The `64b2260` snapshot listed this as "Planned" and said "No export feature on `master`". Design: ADR-006. |
| Integrated TOTP | Shipped | `lib/features/totp/domain/totp.dart:93-108` (RFC 6238 HMAC + dynamic truncation), `lib/features/totp/domain/otp_auth_uri.dart:66-89` (`otpauth://totp/` parsing; HOTP rejected), `lib/features/totp/presentation/totp_code_panel.dart:72` (one-second ticker), the `otpAuthUri` field at `lib/features/vault/domain/vault_item.dart:200` (serialized only when present, so the encrypted payload needs no version bump), rendered at `lib/features/vault/presentation/vault_entry_detail_screen.dart:292-295`. `0492fc4`. Correctness is pinned against the RFC 6238 Appendix B vectors in `test/features/totp/totp_test.dart:9` (SHA-1, SHA-256 and SHA-512 at each timestamp). |
| Every SQL migration is replayed against a clean PostgreSQL in CI | Shipped | `.github/workflows/supabase-migrations-ci.yml:39` (the `apply-migrations` job), `:44-52` (a throwaway `postgres:15` service container), the runner `supabase/ci/apply_migrations.sh`, the Supabase stand-in `supabase/ci/shim_supabase_objects.sql`, and the skip list `supabase/ci/excluded_migrations.txt` (empty at this snapshot: all eight files in `supabase/migrations/` are replayed). Merged in `4148fd5` (PR #35, issue #32). **The previous snapshot said "no workflow applies `supabase/migrations/`"; that was true then and is no longer.** |

## How the non-obvious rows were checked

Every command below was run in the tree of this snapshot
(`4148fd59`) on 2026-10-25, and the output is what it printed.

Cross-device sync was checked by running it, not by reading it. The evidence
is the log entry, not this page: `odd/tasks/vault-key-cross-device-sync.md` L2
(2026-10-23) records device A pushing a v4 item and the wrapped DEK, the
`pm clear` + re-sign-in that simulated the second device, and the item opening
there under the same master password. L3 records the dashboard refresh gap that
issue #19 tracked and that `1150596` closed.

The instrumented Android suite, and the disappearance of the claim that there
is no `androidTest/` directory:

```text
$ git ls-files android/app/src/androidTest
android/app/src/androidTest/kotlin/com/insyd/gestor_contrasenas/KeystoreChannelApiRefusalTest.kt

$ git ls-files android/app/src/test
                                    # empty: still no JVM unit test directory
```

The control that moved when the dashboard refresh landed (issue #19, `1150596`)
— the publisher of the signal, on both producers:

```text
$ grep -rn "notifyVaultChanged" lib/
lib/core/sync/vault_key_sync_service.dart:65:      _vaultChanges?.notifyVaultChanged(
lib/core/sync/vault_change_signal.dart:56:/// is never disposed, so `notifyVaultChanged` after a screen unmounts is
lib/core/sync/vault_change_signal.dart:70:  void notifyVaultChanged({required VaultChangeOrigin origin}) {
lib/core/sync/bidirectional_sync_service.dart:251:      _vaultChanges?.notifyVaultChanged(origin: VaultChangeOrigin.pull);
```

The typed unlock error (issue #20, `7dd2ced`):

```text
$ grep -rn "vaultCannotBeOpened" lib/
lib/features/security/presentation/vault_security_message_l10n.dart:57:    case VaultSecurityMessageCode.vaultCannotBeOpened:
lib/core/security/vault_security_message.dart:76:  vaultCannotBeOpened(isError: true),
lib/core/security/vault_security_controller.dart:1670:  /// [VaultSecurityMessageCode.vaultCannotBeOpened] message instead of an
lib/core/security/vault_security_controller.dart:1691:        VaultSecurityMessageCode.vaultCannotBeOpened,
lib/core/security/master_password_service.dart:22:/// [VaultSecurityMessageCode.vaultCannotBeOpened].
```

And the claim that the controller no longer carries user-facing copy: it
references the typed enum 55 times, and it holds no Spanish literal any more.

```text
$ grep -c "VaultSecurityMessageCode" lib/core/security/vault_security_controller.dart
55

$ grep -nE "'[^']*(contrase|verificac|coincide|borrado|no se puede|correcta|incorrecta)[^']*'" \
    lib/core/security/vault_security_controller.dart
                                    # empty: no Spanish user-facing literal left
```

The favorites flag (issue #21, `91492bf`) and the optional field it adds to
the encrypted payload:

```text
$ grep -rln "isFavorite" lib/features/vault/
lib/features/vault/domain/vault_item.dart
lib/features/vault/presentation/vault_entry_editor_screen.dart
lib/features/vault/presentation/vault_dashboard_screen.dart
lib/features/vault/presentation/vault_entry_detail_screen.dart
lib/features/vault/application/vault_import_parser.dart
```

The API-30-aware settings subtitle (issue #31, `10b08dc`), from the native
answer to the copy that uses it:

```text
$ grep -rn "supportsBiometricOnlyAuth" lib/ android/
lib/features/settings/presentation/settings_screen.dart:129:        cap.supportsBiometricOnlyAuth != current.supportsBiometricOnlyAuth;
lib/features/settings/presentation/settings_screen.dart:144:  /// ([NativeBiometricCapability.supportsBiometricOnlyAuth]), never by
lib/features/settings/presentation/settings_screen.dart:151:    if (capability.isAndroid && !capability.supportsBiometricOnlyAuth) {
lib/core/security/native_biometric_auth_service.dart:25:    this.supportsBiometricOnlyAuth = false,
lib/core/security/native_biometric_auth_service.dart:77:  final bool supportsBiometricOnlyAuth;
lib/core/security/native_biometric_auth_service.dart:83:  /// auth" ([supportsBiometricOnlyAuth] is false on an answered probe)
lib/core/security/native_biometric_auth_service.dart:123:    supportsBiometricOnlyAuth: false,
lib/core/security/native_biometric_auth_service.dart:248:        supportsBiometricOnlyAuth: raw['supportsBiometricOnlyAuth'] == true,
android/app/src/main/kotlin/com/insyd/gestor_contrasenas/KeystoreChannel.kt:130:        if (!supportsBiometricOnlyAuth()) {
android/app/src/main/kotlin/com/insyd/gestor_contrasenas/KeystoreChannel.kt:209:    private fun supportsBiometricOnlyAuth(): Boolean =
android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:188:            "supportsBiometricOnlyAuth" to
```

The SQL migrations, which no workflow applied before this snapshot and which
one applies now:

```text
$ ls .github/workflows/
dev-apk-release.yml
flutter-ci.yml
release.yml
supabase-migrations-ci.yml

$ grep -rln "supabase/migrations" .github/workflows/
.github/workflows/supabase-migrations-ci.yml

$ ls supabase/migrations/ | wc -l
8
```

The security screen row was checked against the code and its tests, not against
a device: the three-state enum is `platform_security_plan.dart:15-26`, the
assembler and its three probes are `vault_security_controller.dart:317-405`, and
the "could not determine" rendering is asserted in
`test/features/security/presentation/security_capabilities_panel_test.dart`.

Windows binary signing:

```bash
D=$(mktemp -d) && cd "$D"
curl -sSL -o w.zip \
  https://github.com/Rene-Kuhm/vaulta/releases/download/v1.0.22/vaulta-windows-bundle.zip
unzip -o -q w.zip vaulta.exe -d x
# read the PE optional header's security data directory (index 4)
```

Output (2026-10-25): `optional header magic 0x20b security dir 0 0`, meaning a
PE32+ image with no Authenticode certificate table. The same result was
recorded on 2026-10-24 and on 2026-08-13; `v1.0.22` has not been replaced
since, so it is the same artifact.

Release contents (2026-10-25), from the public GitHub API (`gh release list`
needs an authenticated `gh` here, so the anonymous REST endpoint was used
instead):

```bash
curl -s https://api.github.com/repos/Rene-Kuhm/vaulta/releases \
  | python3 -c "import sys,json; [print(r['tag_name'], r['name'], r['published_at'], *[(a['name'], a['size'], a['updated_at']) for a in r['assets']], sep='\n    ') for r in json.load(sys.stdin)]"
```

```text
dev-latest Vaulta para Android (dev) 2026-06-09T23:29:50Z
    SHA256SUMS 77 2026-10-25T11:44:48Z
    vaulta.apk 68777847 2026-10-25T11:44:49Z
v1.0.22 Vaulta v1.0.22 - Soporte oficial para Windows desktop 2026-06-11T09:00:20Z
    vaulta-windows-bundle.zip 13546694 2026-06-11T09:10:23Z
    vaulta.apk 57192457 2026-06-11T09:00:19Z
```

`v1.0.22` still holds `vaulta.apk` (57 192 457 bytes) and
`vaulta-windows-bundle.zip` (13 546 694 bytes), unchanged since 2026-06-11.
`dev-latest` is rewritten by CI — its assets were recreated on 2026-10-25 —
and now holds `vaulta.apk` plus a `SHA256SUMS` asset, which is what the
in-app updater downloads.

## Unverified

Stated rather than deleted, because an auditor should not have to guess
which claims were checked and which were not.

- **The API < 30 refusal is verified by execution; the API 30+ half with an
  enrolled biometric is not.** The below-30 refusal was executed on an API 29
  emulator on 2026-10-24 and the API-floor refusal was confirmed gone on an
  API 36 emulator (`docs/reference/api30-biometric-refusal-verification.md`). What was
  **not** executed is the branch where a biometric is actually enrolled and
  the envelope key is minted: an AVD cannot enrol a fingerprint, so
  "minted key + `isAvailable` → `true`" is still read from the code and not
  observed (`docs/reference/api30-biometric-refusal-verification.md`, "The API 30 and
  above half"). That branch needs a device with a real fingerprint enrolled.
- **The instrumented suite does not run in CI.** It needs an emulator with
  KVM, which no workflow provides (`docs/reference/api30-biometric-refusal-verification.md`,
  "What this does not cover"). `scripts/verify_api30_biometric_refusal.sh` is
  a manual, reproducible check.
- **One Kotlin test is all this repository has.** `git ls-files
  android/app/src/androidTest` lists exactly one file, and there is still no
  `android/app/src/test/` directory and no JVM unit test. The native halves of
  autofill (`VaultaAutofillService.kt`), of the update verifier
  (`UpdateChannel.kt:499-508`), of the clipboard sensitive-content flag
  (`SensitiveClipboard.kt:74-76`) and of screen-capture protection are
  therefore still covered by reading only. Nothing in this page claims an
  on-device run for them except the sync run and the API-29 run described
  above.
- **Autofill has no recorded end-to-end run in the repository.**
  `integration_test/seed_autofill_vault_test.dart` seeds a real vault on a
  device so a person can exercise the fill flow by hand, and the Dart tests
  (`test/features/autofill/`) fake the platform channel; there is no artifact
  in the tree showing that a fill was executed on a device at this snapshot.
- **The migrations run in CI, but against a stand-in, not against a real
  Supabase project, and no deployment's migration state is visible from the
  repository.** `.github/workflows/supabase-migrations-ci.yml:39` applies every
  file of `supabase/migrations/` to a clean `postgres:15` container, in
  file-name order, with `psql -v ON_ERROR_STOP=1`; the objects Supabase
  provides (`auth` schema, `auth.uid()`, `auth.jwt()`, the `anon` /
  `authenticated` / `service_role` roles) come from the versioned shim
  `supabase/ci/shim_supabase_objects.sql`. `supabase/ci/excluded_migrations.txt`
  is empty at this snapshot, so all eight migration files are replayed. What
  that still does not prove is which migrations a given **real** deployment
  has: nothing in the repository records that, and the only execution against
  a real Postgres remains the manual run of 2026-10-23
  (`odd/tasks/vault-key-cross-device-sync.md` L2), which pushed a v4 item with
  its salt and read a `vault_keys` row — so those columns and RPCs accepted
  writes on that backend — but the log does not say which migration files were
  applied to it. A deployment that skips them fails closed: the client returns
  `null` instead of queueing a v4 upsert whose columns are missing
  (`local_encrypted_vault_repository.dart:402-407`), never a broken row. The
  Dart side of that wire is tested.
- **The security screen's answers were never captured on real hardware at this
  snapshot.** The probe and the three states are tested with fakes; the
  real-device behaviour of `probeCapability` and
  `probeHardwareBackedKeyAvailability` on an API < 30 device is a gap the
  API-29 run does not close, because that run drives the Kotlin channel, not
  the Dart capability panel.
- **The API-30-aware copy has never been rendered on a device that cannot
  express biometric-only auth.** The settings subtitle that names the API 30
  floor (`lib/l10n/app_en.arb:29`) is selected by the native answer the
  emulator run exercised on the Kotlin channel, but no run in this repository
  shows that subtitle on an API < 30 device.
- **"Hardware-backed" cannot be proven from the Dart side.** The row of
  that name reports that the KeyStore-held key exists and is usable
  (`KeystoreChannel.isAvailable`, via
  `probeHardwareBackedKeyAvailability`); it does **not** report
  `KeyInfo.isInsideSecureHardware`, which the channel does not expose.
  On a device where AndroidKeyStore keys are software-backed the label
  is therefore optimistic, which is why the row's copy says
  "KeyStore-held key" (`lib/l10n/app_en.arb:60`) rather than
  "hardware-backed". Reading the TEE/StrongBox flag would need a new native
  call and was not added here.
- **Release contents and the Windows PE header were re-checked on 2026-10-25;
  nothing else in this page was verified by downloading an artifact.** Every
  other claim rests on the tree at `4148fd59`, its tests, or the log entry
  named beside it.
- **The open issues are named, not predicted.** As of 2026-10-25 the open
  issues are #33 (this page) and the repository-hygiene and documentation
  issues #36–#43. Issues #18, #19, #20, #21, #22, #23, #31 and #32 are
  closed, and their pull requests are in the tree this snapshot describes.
  This page does not predict what the open issues will change: a later
  snapshot must re-read these rows rather than assume this one still holds.
  Unmerged security work under an unresolved decision is not described
  anywhere above.
