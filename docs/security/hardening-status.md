# Security hardening status

What security controls Vaulta actually ships, what is being built on a branch, and what is only planned. This page exists so that the README, store listings and release notes never claim more than the code does. When this page and the code disagree, the code wins and this page is wrong.

Snapshot of `master` at `64b2260` (2026-08-13). Line numbers refer to that commit.

## How to read the table

| Status | Meaning |
|---|---|
| **Shipped** | On `master` and in the published builds. Evidence points at the code. |
| **In progress (branch)** | Code exists on a feature branch, not merged, not in any release. |
| **Planned** | No code yet. Listed in the README roadmap. |

"Published builds" means the `vaulta.apk` that `.github/workflows/dev-apk-release.yml` uploads to the `dev-latest` release, and the manually uploaded stable release (`v1.0.22` at the time of writing, containing `vaulta.apk` and `vaulta-windows-bundle.zip`).

## Controls

### Vault cryptography

| Control | Status | Evidence |
|---|---|---|
| Argon2id KEK derivation from the master password, 64 MiB, 3 iterations, parallelism 1, 32-byte output | Shipped | `lib/core/security/master_password_service.dart:53-56` (defaults), `:225-230` (Argon2id call) |
| Random 16-byte salts for verifier and KEK | Shipped | `lib/core/security/master_password_service.dart:101-102` |
| Random 32-byte DEK per vault, wrapped with AES-256-GCM under the KEK | Shipped | `lib/core/security/master_password_service.dart:57`, `:116-117`, `_wrapDek` at `:286` |
| Vault item payloads encrypted with AES-256-GCM under the DEK | Shipped | `lib/core/security/aes_gcm_vault_crypto_service.dart:16` (`AesGcm.with256bits()`), `encrypt` at `:53-79` |
| DEK held only in the in-memory session; dropped on lock | Shipped | `lib/core/security/vault_security_controller.dart:578-582` (`lock` sets `_vaultSession = null`) |
| External cryptographic audit | Planned | None. See the security note in `README.md` and `docs/architecture/CRYPTO.md`. |

### Unlock

| Control | Status | Evidence |
|---|---|---|
| Master password unlock on every platform | Shipped | `lib/core/security/vault_security_controller.dart:404-483` (`unlockWithPassword`) |
| Android biometric unlock bound to hardware: RSA-2048 KeyStore key, `setUserAuthenticationRequired(true)`, per-use `AUTH_BIOMETRIC_STRONG` on API 30+ | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/KeystoreChannel.kt:150-171` |
| Android unlock prompt uses `BIOMETRIC_STRONG` with a `CryptoObject` wrapping the KeyStore cipher | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/MainActivity.kt:209`, `:313` |
| Android bypasses `local_auth` so the capability gate and the prompt read the same `BiometricManager` state | Shipped | `lib/app/bootstrap/password_manager_app.dart:112-128` (`_buildBiometricAuthService`) |
| Biometric unlock on Windows (Windows Hello), iOS, macOS, Linux | Not shipped | Non-Android targets get a no-op envelope key provider (`_buildEnvelopeKeyProvider` and `_NullEnvelopeKeyProvider`, `lib/app/bootstrap/password_manager_app.dart:98-147`), and `_isBiometricCapableTarget` returns false outside Android and iOS (`lib/core/security/biometric_unlock_service.dart:291-296`), so `unlock` returns `BiometricUnlockUnavailable` (`:208-212`). `local_auth` only names "Windows Hello" in a label (`lib/core/security/biometric_auth_service.dart:53-54`). |
| Master password attempt throttling: persisted exponential lockout, 30 s doubling to a 15 min cap | In progress (branch) | Branch `feat/unlock-attempt-throttling`. On `master`, a wrong password only sets a message and returns false (`lib/core/security/vault_security_controller.dart:418-421`); there is no attempt counter. |

### Session and screen

| Control | Status | Evidence |
|---|---|---|
| Auto-lock when the app leaves the foreground (on by default) | Shipped | `lib/core/security/vault_security_controller.dart:109` (default `true`), `:778-808` (`handleAppLifecycleState`) |
| Idle auto-lock, 900 s (15 min) default, configurable, 0 disables | Shipped | `lib/core/security/vault_security_controller.dart:89`, `:606-624` |
| Clipboard auto-clear 30 s after copying a secret, only if the clipboard still holds that secret | Shipped | `lib/features/vault/presentation/vault_entry_detail_screen.dart:52`, `:268-288` |
| Screen-capture protection on Android (`FLAG_SECURE`: blocks screenshots, screen recording and the recents thumbnail) plus the sensitive-content flag on copied secrets so Android 13+ hides them in the clipboard preview | In progress (branch) | Branch `feat/android-screen-clipboard-protection`. On `master`, `FLAG_SECURE` appears nowhere under `android/` and `_copySecret` sets plain `ClipboardData` (`lib/features/vault/presentation/vault_entry_detail_screen.dart:269`). |

### Storage and platform

| Control | Status | Evidence |
|---|---|---|
| Secrets in `flutter_secure_storage` (Android Keystore-backed, Windows Credential Manager) | Shipped | `lib/core/security/flutter_secure_storage_service.dart:21-27` |
| Android cloud backup and device-transfer extraction disabled | Shipped | `android/app/src/main/AndroidManifest.xml:15-17`, `android/app/src/main/res/xml/data_extraction_rules.xml` |
| Cleartext HTTP disallowed on Android | Shipped | `android/app/src/main/AndroidManifest.xml:18` |
| Main activity not exported; only the launcher alias is | Shipped | `android/app/src/main/AndroidManifest.xml:23`, `:39-45` |
| Native Android autofill service | Planned | No `<service>` with `BIND_AUTOFILL_SERVICE` in `android/app/src/main/AndroidManifest.xml`, and no `AutofillService` class in `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/` (only `BiometricChannel.kt`, `KeystoreChannel.kt`, `MainActivity.kt`, `UpdateChannel.kt`). The "Access" tab (`lib/features/access/presentation/access_screen.dart`) is an explainer screen only. |

### Distribution and updates

| Control | Status | Evidence |
|---|---|---|
| Release APK signed with a persistent upload key from CI secrets; the build fails if a secret is missing | Shipped | `.github/workflows/dev-apk-release.yml:56-73`, `android/app/build.gradle.kts:20-23`, `:64-80` |
| In-app update channel: queries the `dev-latest` GitHub release and hands the APK to the system installer | Shipped | `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/UpdateChannel.kt:134` |
| Update integrity relies on Android refusing an in-place update signed with a different key; the app does not verify a hash or signature itself | Shipped (as described) | No hash or signature check in `UpdateChannel.kt` or `lib/core/update/update_service.dart` |
| Windows code signing (Authenticode) | Planned | The `vaulta.exe` in `v1.0.22/vaulta-windows-bundle.zip` has an empty PE security directory (checked, see below). No workflow builds Windows. |
| Optional Supabase sync, off in published builds | Experimental, off | `lib/core/sync/device_sync_bootstrap.dart:46-50` returns `null` without `SUPABASE_URL`/`SUPABASE_ANON_KEY`; `.github/workflows/dev-apk-release.yml:73` builds with no `--dart-define`. Account sync is Planned. |
| Encrypted export / backup | Planned | No export feature on `master`. |
| Integrated TOTP | Planned | No TOTP or `otpauth` code under `lib/`. |

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

Missing controls on `master` were checked by searching the tree: `grep -rn FLAG_SECURE android/` and `grep -rni "throttl\|lockout\|failedAttempt" lib` find no implementation (the only `lockout` hits are `local_auth` error codes in `lib/core/security/biometric_auth_service.dart:118-119`).

## Unverified

- The contents of the two in-progress branches beyond their names and intent. At the time of writing `feat/android-screen-clipboard-protection` has one commit beyond `master` (`400dfc4 feat(security): block screenshots and recents thumbnail on Android`), and `feat/unlock-attempt-throttling` has none yet. Update the rows to Shipped, with evidence, when they merge.
- Whether the in-app security screen's capability flags are accurate. It reads a static `PlatformSecurityPlan` (`lib/core/security/local_encrypted_vault_repository.dart:58-65`) that reports `biometricUnlock: false` and `hardwareBackedKeys: false`, which contradicts the Android KeyStore path above. That is a code issue, not covered by this page.
