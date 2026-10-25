# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **TOTP (RFC 6238) on vault items.** An item can carry an `otpauth://`
  URI and the detail screen shows the current code with a countdown and a
  copy action. HMAC-SHA1 by default, SHA256/SHA512 and 6/8 digits when the
  URI asks for them. Verified against the eight RFC 6238 Appendix B test
  vectors, including the 8-digit value that starts with a zero.
- **KeePass `.kdbx` import.** KDBX 3.1 and 4.x, with a password and
  optionally a key file. A wrong master password produces a clear error
  instead of an empty item list. Every previous import format keeps
  working, and a test pins that CSV still skips the password prompt.
- **Password history per item.** Rotating a secret keeps the previous one
  with the instant it was replaced, capped at 10 entries, shown newest
  first on the detail screen with a copy action. An item that never had a
  history serializes byte-identically to before.
- **Vault health report.** A screen that names which items are weak and
  which share a secret with another item, each tappable to open it, with a
  real empty state for a healthy vault.
- **Clear-text CSV and JSON export**, next to the encrypted `.vaulta`
  export and not replacing it. It requires acknowledging an explicit
  warning and re-entering the master password, and the encrypted export
  stays the default.

### Changed

- **The security screen reports the real device capability set.** It used
  to show `false` for hardware-backed keys and biometric unlock even when
  the Android KeyStore path worked. It now carries three states — supported,
  unsupported, and could-not-determine — so an unknown is never disguised
  as a negative.
- **`README.md` no longer contradicts the code**: the encrypted export is
  documented as shipped (it was listed as unavailable) and the coverage
  gate is stated as 60%, which is what CI enforces.

### Internal

- **Encrypted local database (ADR-007).** SQLite 3.54 built as SQLite3
  Multiple Ciphers through native assets, `STRICT` tables, per-item payload
  encryption unchanged, and a verified one-time migration that keeps the
  legacy blob as the rollback. Off by default behind
  `--dart-define=VAULTA_SQLITE_STORAGE=true`; the release default still uses
  the encrypted blob. A save drops from 501 encryptions and 179.433 bytes to
  2 encryptions and 277 bytes on a 500-item vault.
- **Sync decoupled from the blob** through a narrow `RemoteSnapshotApplier`
  port, now implemented by both storages.

## [1.1.0] - 2026-10-19

### Security

- **Master-password attempts are throttled (#3).** After 4 failed
  attempts the lock screen locks out for 30 seconds, doubling with
  each further failure up to 15 minutes. The counter and lockout are
  stored in secure storage as a single atomic record, so killing or
  restarting the app does not reset them, and they are checked
  before any Argon2id work. Unreadable state fails closed. Clock
  rollbacks keep the device locked; a clock that was ahead and is
  then corrected never locks the user out for longer than one
  lockout period. Biometric setup from the lock screen and changing
  the master password go through the same limiter. The unlock
  screen shows a localized countdown.
- **Screen and clipboard protection on Android (#4).**
  - `FLAG_SECURE` on the main window blocks screenshots, screen
    recording, casting and the recents thumbnail (plus
    `setRecentsScreenshotEnabled(false)` on Android 13+).
  - Copied secrets are flagged as sensitive so keyboards and the
    Android 13+ clipboard preview hide them, and are cleared after
    30 seconds by a native alarm that survives the app being frozen
    or killed. Locking the vault clears them immediately. Vaulta only
    clears clips it put there.
  - Revealed secrets are kept out of the text toolbar (Copy, Share,
    Translate / `PROCESS_TEXT`) and keyboard copy/cut, and password
    fields disable autocorrect and suggestions so keyboards do not
    learn them.
- **Verified in-app updates.** The updater now follows the latest
  stable release instead of the rolling dev build, and refuses to
  install an APK unless its SHA-256 matches the release's
  `SHA256SUMS` and it is signed with the same certificate as the
  installed app. A missing checksum, a mismatch or a different signer
  shows a localized error and the download is deleted. An optional
  *Dev channel* switch in *Settings > Updates* follows `dev-latest`
  with the same checks.

### Added

- **Stable release pipeline.** Pushing a `vX.Y.Z` tag builds the
  signed APK and the Windows bundle (`vaulta.exe` inside
  `vaulta-windows-bundle.zip`) in CI, publishes them with a
  `SHA256SUMS` file, and uses this changelog section as the release
  notes. The tag must match the `pubspec.yaml` version. See
  `docs/how-to/release-process.md`.
- `SECURITY.md` with supported versions and private reporting through
  GitHub Security Advisories.
- Dependabot for pub, Gradle and GitHub Actions dependencies.

### Changed

- The `dev-latest` build is now published as a pre-release with its
  own `SHA256SUMS`, so it is never shown as the latest release.
- CI pins Flutter 3.47.7 and every GitHub Action to a commit SHA,
  builds Windows on pull requests, and requires 60% line coverage on
  `lib/core/security` (was 50%).

### Documentation

- The README describes only what ships today, with unshipped work
  (autofill, Windows Hello unlock, signed Windows binary) moved to a
  roadmap, and a security hardening status page was added under
  `docs/security/` (#2).

## [1.0.21] - 2026-06-10

### Fixed

- **Import flow was getting the vault locked mid-pick.** Opening
  the system file picker from the import screen takes the
  foreground away from Flutter, which the security controller
  treated as a "user left the app" signal and auto-locked the
  vault. The user came back to the SecurityGate and the import
  preview was lost, with no clear explanation. The import screen
  now asks the controller to stand down on the background
  auto-lock for the duration of the pick, and restores it as soon
  as the picker resolves (or the screen is disposed). The
  controller exposes `beginLongRunningFlow` / `endLongRunningFlow`
  as a stack so future flows can request the same courtesy
  independently. `lock()` clamps the stack back to zero so a
  screen that died without releasing the counter cannot leave the
  vault permanently un-lockable.

## [1.0.20] - 2026-06-10

### Changed

- **Longer idle auto-lock window.** The default idle timeout before
  the vault auto-locks raised from 5 minutes (`300s`) to 15 minutes
  (`900s`). This gives users more breathing room during flows that
  take a while — for example, picking a Bitwarden file, comparing
  it in a spreadsheet, then coming back to the import screen. Users
  who want the old window can change it from
  *Ajustes > Seguridad > Bloqueo automatico por inactividad*.

  > **Note on background auto-lock.** This change does NOT affect the
  > separate `autoLockOnBackground` setting, which still locks the
  > vault the moment the app loses foreground (for example, when the
  > system file picker takes over the screen). Long flows like
  > import that go through a system UI therefore still get locked
  > the moment the foreground switches. If that becomes a problem,
  > the workaround is *Ajustes > Seguridad > Auto-lock al ir a
  > background* turned off while importing, or moving the import
  > flow into a self-contained in-app picker.

## [1.0.19] - 2026-06-10

### Fixed

- **Import failed with a cryptic error when the vault session was
  locked.** If the user opened the import screen while the vault was
  locked (auto-lock by inactivity, fresh install, or backgrounded
  the app long enough for the DEK to drop from memory), tapping
  "Importar N entradas" surfaced the raw
  `Bad state: Vault encryption key unavailable. Unlock with the
  master password first.` from the repository. The screen now
  detects that specific error, replaces it with the actionable
  "Tu sesion de Vaulta esta bloqueada. Desbloquea con la master
  password para poder importar." message, and pops back to the
  dashboard so the SecurityGate can take over and prompt the user
  to unlock. The selected preview is discarded on purpose; after
  unlocking, the user picks the file again and the import runs with
  a fresh session in memory.

## [1.0.18] - 2026-06-10

### Fixed

- **Vault import button was effectively invisible.** The "Importar N
  entradas" button lived at the bottom of a scrollable list, so on
  short devices or with a long preview it scrolled below the
  viewport and looked unresponsive. The button now lives in the
  Scaffold's `bottomNavigationBar`, stays anchored to the bottom of
  the screen, and the AppBar shows the live "Importar (N)" count so
  the user always knows the picker has parsed their file.
- **File picker failures were silent.** Cancelling the picker, an
  empty selection, and an unreadable file all used to return without
  feedback. The screen now shows a SnackBar on cancel and a
  descriptive error banner when the file cannot be read.
- **Android import path was over-asking the platform.** The picker
  no longer requests `withReadStream` alongside `withData`; the
  stream path was redundant with the in-memory bytes + filesystem
  fallback and occasionally produced empty reads on Android.
- **No feedback when a file parsed to zero importable entries.** If
  the parser rejected every row, the screen now surfaces a SnackBar
  explaining that no valid entries were detected, in addition to
  the existing rejected-rows banner inside the preview.

## [Unreleased]

### Security

- **Biometric unlock envelope.** Vaulta can now enroll a per-vault
  biometric unlock path. The vault DEK is wrapped with HKDF-SHA256
  over a platform-protected key slot, and only the wrapped envelope is
  persisted on disk. On Android the platform-protected key is an
  RSA-2048 keypair in AndroidKeyStore with
  `setUserAuthenticationRequired(true)` and, on API 30+,
  `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` so the
  private key is released only after a fresh `BiometricPrompt` per
  decrypt. The prompt authenticator set is `BIOMETRIC_STRONG`
  because the operation is bound to a `CryptoObject`; Android device
  credential fallback remains a master-password recovery path rather
  than a KeyStore decrypt path. On non-Android targets the biometric
  vault unlock is reported as unavailable rather than silently
  failing. The platform key provider is pluggable so an iOS Secure
  Enclave binding can be added without touching the controller. If the
  platform reports biometrics are no longer enrolled, Vaulta
  automatically clears both the preference and the envelope.

- **Single source of biometric truth.** The availability check and
  the `BiometricPrompt` itself now share one channel
  (`com.insyd.vaulta/biometric`). The previous implementation mixed
  `local_auth` for the gate and a custom MethodChannel for the
  prompt; on devices with weak biometrics the two would disagree
  and the unlock button would silently disappear. Only Android uses
  the new native vault-unlock service today; iOS / desktop / web keep
  the master-password path until equivalent bindings are added.

- **VaultSession invariant.** The session class now requires `kdf` and
  `dekWrap` to be either both present or both absent. A new
  `VaultSession.v2(...)` factory refuses to build a v2 session with
  missing wrap metadata, so the crypto service never receives a
  session that cannot be unwrapped.

- **Test KDF guard.** `MasterPasswordService` now asserts at
  construction that the fast test KDF is only enabled while running
  under `flutter_test` (`FLUTTER_TEST` env var). The fast KDF can
  never be enabled in a production binary by accident.

- **Master password record migration.** v1 records (PBKDF2-derived
  key) are migrated to the v2 envelope (Argon2id KEK + AES-256-GCM
  wrapped DEK) automatically the first time a user unlocks with their
  master password. The biometric envelope is re-enrolled under the new
  DEK in the same pass.

### Changed

- **Brand attribution.** The locked/onboarding screens now show a
  small `Tecnodespegue.com` footer, and Settings includes an About
  section crediting René Kuhm as founder of Tecnodespegue.
- **Android system icon coverage.** The Android manifest now declares
  Vaulta's adaptive icon, round icon, and themed monochrome icon for
  the app, launcher activity, and AndroidX biometric fallback activity.
  `MainActivity` also reapplies a Vaulta task bitmap after Flutter
  initializes so Samsung/Android system surfaces stop falling back to
  stale/default task icons.
- **Launcher cache bust.** Android now exposes Vaulta through a
  dedicated `.VaultaLauncherActivity` alias instead of using
  `.MainActivity` directly as the launcher component, forcing Samsung
  One UI Launcher to resolve a fresh component/icon pair after upgrades.
- **Adaptive icon framing.** The Android foreground and monochrome
  launcher vectors were redrawn inside the adaptive-icon safe zone so
  Samsung launchers do not crop the Vaulta lock toward the bottom edge.
- **Legacy launcher PNG refresh.** Android legacy `mipmap-*`
  launcher PNGs now use the same centered Vaulta geometry as the
  adaptive icon, covering Samsung/theme fallback paths that rasterize
  legacy resources.
- **Icon parity with app UI.** Android launcher, task, and biometric
  resources now mirror the in-app `VaultaLogomark`: dark surface,
  crimson lock body, paper shackle, and gold key slot.
- **Vault entry cards.** Saved credentials now render as richer cards
  with category icons, metadata chips, strength badges, update time,
  and an affordance to open the detail view.
- **Brand.** The `redesign/brand/*.svg` assets are now wired up as
  the launcher icon on Android, iOS, macOS, Windows and web. The
  vault icon stays the crimson padlock with the gold keyhole.
- **Auto-lock by default.** Background auto-lock and idle auto-lock
  remain on by default. The locked-state UI now reflects the real
  biometric availability instead of a hard-coded "false".
- **Biometric library upgrade.** `androidx.biometric` moves from
  `1.2.0-alpha05` to `1.4.0-alpha07` to pick up the bug fixes that
  the alpha05 line was missing on compileSdk 36 (notably the
  removal of the deprecated `setUserAuthenticationValidityDuration`
  from the public surface).
- **Biometric prompt is now localized.** Copy that used to be
  hardcoded Spanish in `MainActivity.kt` now lives in
  `res/values/strings.xml` and `res/values-en/strings.xml`.
- **CHANGELOG discipline.** This file is now kept in sync with
  notable security-relevant changes from each iteration.
- **OTA updates.** A new "Actualizaciones" section in Settings lets
  the user check for and install a newer signed release APK over the
  air (no uninstall, no Play Store, no data loss when the signing key
  is stable). A GitHub Actions workflow
  (`.github/workflows/dev-apk-release.yml`) rebuilds the signed APK on
  every push to `master` and overwrites the `dev-latest` GitHub
  Release. The app also auto-checks
  silently after unlock and surfaces a SnackBar with an
  "Actualizar" action when a newer build is available.

### Fixed

- **Biometric unlock no longer calls the privileged AndroidX
  biometric-logo API.** The prompt now relies on the app icon that
  AndroidX shows automatically, avoiding the
  `SET_BIOMETRIC_DIALOG_ADVANCED` permission path reserved for
  privileged apps.
- **OTA checks now compare the installed app version against the
  version published in the GitHub Release body.** Opening Android's
  installer is no longer treated as proof that the APK was installed,
  so cancelled or rejected installs won't make the app claim it is
  up to date.
- **OTA update checks no longer run network on Android's main
  thread.** `UpdateChannel` now performs GitHub release queries and
  APK downloads on a background executor, then posts the result back
  to Flutter. This fixes the `NetworkOnMainThreadException` that made
  the Settings screen report "up to date" even when the check had
  actually failed.
- **OTA errors are no longer disguised as "up to date".** Platform
  failures now surface to the update UI as an error banner, while the
  silent dashboard check still logs and stays quiet.
- `unlockWithBiometrics` no longer returns a hard-coded `false`. When
  no envelope is enrolled the controller explains why and points the
  user at the master password path; when an envelope is present and
  biometrics succeed, the controller actually unwraps the DEK and
  builds a `VaultSession` the same way a password unlock would.
- **Biometric unlock button would silently vanish** on devices
  whose only biometric is class-2 (face unlock). The app now separates
  capability probing from KeyStore decrypt eligibility: Android
  vault-key decrypt requires `BIOMETRIC_STRONG`, while weaker biometric
  or credential-only devices stay on the master-password path with a
  clear message.
- **No prompt for "no biometric enrolled"** is no longer
  indistinguishable from "no hardware". The native probe now
  reports the exact `BiometricManager` reason code (`NO_HARDWARE`,
  `NONE_ENROLLED`, `HW_UNAVAILABLE`, `SECURITY_UPDATE_REQUIRED`,
  `UNSUPPORTED`, `LOCKOUT`, `LOCKOUT_PERMANENT`, `TIMEOUT`,
  `USER_CANCELLED`), and the Dart side turns `NONE_ENROLLED` into
  a deep-link to `Settings.ACTION_BIOMETRIC_ENROLL` (API 30+) or
  `Settings.ACTION_SECURITY_SETTINGS` on older devices, surfaced
  from both the unlock screen and the settings screen.
- **Double biometric prompt** during unlock. The previous
  `LocalBiometricAuthService.authenticateForUnlock` was opening a
  `local_auth` prompt before the native `BiometricPrompt` for the
  KeyStore operation fired. The new
  `NativeBiometricAuthService.authenticateForUnlock` is a passive
  availability check; the actual prompt is opened once, by the
  KeyStore provider's `releaseEnvelopeKey`.
- **"Key permanently invalidated" was reported as a generic
  error.** The new `KeyPermanentlyInvalidatedException` is mapped
  to `BIOMETRIC_LOCKOUT_PERMANENT` so the UI can ask the user to
  re-enroll instead of looping on a stale key.
