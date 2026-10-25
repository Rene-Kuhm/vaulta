# Vaulta final store submission checklist

This checklist tracks the external assets, secrets, accounts, and policy decisions required before submitting Vaulta to Google Play, Apple App Store, Mac App Store, and obvious desktop/web distribution channels. It intentionally does **not** contain secrets.

## Repository-ready configuration already present

- App name/label: `Vaulta` on Android, iOS, macOS, and web.
- Android package/application ID: `com.insyd.gestor_contrasenas`.
- iOS/macOS bundle ID: `com.insyd.gestorContrasenas`.
- Flutter version source: `pubspec.yaml` `version: 1.0.12+13`.
- Android release signing does not fall back to debug signing; see `docs/how-to/android-release-signing.md`.
- Android backup/data extraction is disabled for local vault data.
- Android cleartext traffic is disabled.
- Android biometric vault unlock is implemented with Android KeyStore + `BiometricPrompt` / `BIOMETRIC_STRONG`; iOS/macOS biometric vault unlock remains pending unless a platform binding is added.
- macOS sandbox allows outbound network access for optional Supabase sync.
- Supabase sync remains optional/experimental and should stay disabled for the public MVP unless release QA covers sessions, conflicts, revocation, restore, offline/online behavior, and privacy copy.

## Google Play blockers

- [ ] Create/verify Play Console app for package `com.insyd.gestor_contrasenas`.
- [ ] Generate Android upload keystore locally/CI and keep it outside the repo.
- [x] Configure GitHub Actions `VAULTA_UPLOAD_KEYSTORE_BASE64`, `VAULTA_UPLOAD_STORE_PASSWORD`, `VAULTA_UPLOAD_KEY_ALIAS`, and `VAULTA_UPLOAD_KEY_PASSWORD` for the rolling OTA APK.
- [ ] Decide whether Supabase sync is enabled. MVP recommendation: keep it disabled by default. If yes, pass `--dart-define=SUPABASE_URL=...` and `--dart-define=SUPABASE_ANON_KEY=...` from CI only and complete operational QA first.
- [ ] Complete Play Data Safety: user-provided password-vault data is sensitive; local entries are encrypted; if Supabase sync is enabled, encrypted snapshots/device IDs/session metadata may be transmitted to Supabase.
- [ ] Provide privacy policy URL, support URL/email, app category (`Productivity` or `Tools`), screenshots, feature graphic, store descriptions, and release notes.
- [ ] Confirm target SDK requirements at submission time.
- [ ] Migrate Android/Kotlin Gradle Plugin usage to Flutter's built-in Kotlin plugin path before the Flutter version that makes the current warning fatal.
- [ ] Confirm encryption/export compliance statements for password-management cryptography.

## Apple App Store / TestFlight blockers

- [ ] Register Bundle ID `com.insyd.gestorContrasenas` or intentionally change all platform IDs before release.
- [ ] Configure signing team, certificates, provisioning profiles, and App Store Connect app record outside the repo.
- [ ] Complete App Privacy questionnaire: sensitive user vault data; local encryption; optional Supabase encrypted sync metadata if enabled; no tracking unless SDKs are added later.
- [ ] Provide privacy policy URL, support URL, category (`Productivity` or `Utilities`), screenshots, app icon, store copy, and release notes.
- [ ] Explain in App Review notes that Android has biometric vault unlock, while iOS/macOS require master password unless a native binding is added before submission.
- [ ] Answer export compliance/encryption questions for AES-256-GCM/Argon2id password-vault cryptography.

## Mac App Store / desktop blockers

- [ ] Decide whether macOS distribution is Mac App Store, notarized direct download, or both.
- [ ] Configure Developer ID / Mac App Store certificates and provisioning outside the repo.
- [ ] Verify sandbox entitlements match release behavior. Current release sandbox allows outbound network client access for optional Supabase sync.
- [ ] Provide desktop screenshots, category, description, support URL, privacy policy URL.
- [ ] Confirm encryption/export compliance.

## Web distribution blockers

- [ ] Choose production domain and hosting.
- [ ] Publish reviewed privacy policy and update metadata/store listings with the final public URL.
- [ ] Decide whether web release may enable Supabase sync; if yes, configure environment at build/deploy time without committing secrets.
- [ ] Verify PWA icons, theme color, manifest, caching behavior, and offline messaging.

## Security/release review before submission

- [ ] Run `flutter analyze` and `flutter test` before every release candidate.
- [ ] Manual QA matrix: fresh install, signed OTA update, master password create/unlock, biometric activation, biometric unlock, biometric removal/re-enrollment, master password change, CRUD, search, password generation, clipboard auto-clear, background/idle auto-lock, and optional Supabase sync if enabled.
- [ ] Review `docs/adr/0001-crypto-key-derivation-and-encrypted-blob.md`, `docs/adr/0002-sync-versioning-cas-idempotency-tombstones.md`, and `docs/adr/0003-session-policy-and-revocation.md` for user-facing claims.
- [ ] Avoid claiming third-party audit, breach monitoring, autofill, passkeys, or non-Android biometric vault unlock unless implemented and verified.
