# AGENTS.md — `lib/core/update`

The in-app update check: the release channel, the download and the
verification of what was downloaded. It is one file, `update_service.dart`,
and it is the only place where the app fetches and installs an APK.

The map of this module: `mise run repo-map --module lib/core/update`.

## Invariants

- Nothing is installed that was not verified. A download without a published
  digest is refused (`checksumMissing`), a file whose SHA-256 does not match
  the published one is refused (`checksumMismatch`) and a file signed by
  another signer is refused (`signatureMismatch`). The verification happens
  in this layer, not on the native side.
- The digest and the signer are checked against the release the check
  returned, so the two cannot be mixed: the file that is verified is the file
  that is offered.
- A verified file is remembered by its path and its expected digest, and the
  install prompt re-checks that digest before the install. A file that was
  replaced between the download and the install is refused.
- The release channel is the user's choice and is persisted
  (`vaulta_update_channel_v1`); the default is `stable`. The `dev` channel is
  opt-in and is verified exactly like the stable one.
- The update check is opt-in and never runs on its own at startup: the
  Settings section asks first.
- The last seen release id and the build fingerprint are persisted, so the
  same release is not offered twice.

## How it is tested

- `test/core/update/update_service_test.dart` — the check, the channel
  selection, the persistence and the version comparison.
- `test/core/update/update_service_verification_test.dart` — the
  verification: the missing digest, the mismatched digest, the mismatched
  signer and the re-check before the install.
- The helpers `sha256ForAsset`, `remoteVersionFromChangelogForTest` and
  `isRemoteVersionNewerForTest` are the seam the tests drive; the version
  comparison is covered by the same file.

## Do not touch

- The `MethodChannel` name `com.insyd.vaulta/update`. It exists exactly once
  in Dart and once in Kotlin (`UpdateChannel.kt`); renaming one is a
  two-file change that has to land together.
- The verification order — digest first, then signer, then the install
  re-check. Skipping a step turns "verified" into "downloaded".
- The persisted keys (`vaulta_update_channel_v1` and the build fingerprint).
  Renaming one silently resets the user's channel and re-offers a release the
  user already installed.
- The `UpdateVerificationFailure` values. The Settings screen and the tests
  switch on them.
- The rule that the published builds define neither Supabase nor any
  development channel: a default build must not pull a pre-release.

## Boundaries

- Depends on: `lib/core/security` — the secure storage where the channel
  and the last-seen release are persisted.
- Never imports: `lib/features/*/presentation` and `lib/app`. The Settings
  section renders what this service returns.
- Never imports: `lib/core/sync` and `lib/core/storage`. The updater is
  independent of the vault.
- Never downloads anything else: no asset, no metadata and no telemetry
  outside the release the check returned.
