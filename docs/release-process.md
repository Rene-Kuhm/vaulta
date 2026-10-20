# Release process

How a Vaulta release is cut, what it publishes, and how users and the
app verify what they download.

## Channels

| Channel | Source | Built by | GitHub release | Used by the app when |
| ------- | ------ | -------- | -------------- | -------------------- |
| Stable  | `vX.Y.Z` tag | `.github/workflows/release.yml` | `vX.Y.Z`, marked **Latest** | default |
| Dev     | every push to `master` | `.github/workflows/dev-apk-release.yml` | `dev-latest`, marked **pre-release** | Settings → Updates → *Dev channel* is on |

Because `dev-latest` is a pre-release, GitHub's `/releases/latest`
endpoint always resolves to the newest stable tag. Both channels sign
the APK with the same upload key (`VAULTA_UPLOAD_*` secrets), so a
device can switch between them and still update in place.

## Cutting a stable release

1. On a branch, bump `version:` in `pubspec.yaml` (`X.Y.Z+N`; the build
   number `N` must increase on every release, Android uses it as
   `versionCode`).
2. Add a `## [X.Y.Z] - YYYY-MM-DD` section to `CHANGELOG.md`. This
   section becomes the release notes verbatim.
3. Open a PR, wait for Flutter CI (analyze, tests, coverage gate,
   Windows build) to pass, merge.
4. Tag the merge commit and push the tag:

   ```sh
   git switch master && git pull
   git tag -a vX.Y.Z -m "Vaulta vX.Y.Z"
   git push origin vX.Y.Z
   ```

5. `release.yml` then:
   - fails fast if the tag is not exactly `v` + the pubspec version name,
     or if `CHANGELOG.md` has no section for it;
   - runs analyze + tests and builds the signed APK, rejecting a
     debug-signed result (`apksigner verify --print-certs`);
   - builds the Windows bundle on `windows-latest` and zips it with the
     executable renamed to `vaulta.exe`;
   - generates `SHA256SUMS` over both assets and creates the release
     with `vaulta.apk`, `vaulta-windows-bundle.zip` and `SHA256SUMS`.

If a run fails after the tag is pushed, fix the problem on `master`,
delete the tag locally and remotely, and tag again. Never edit assets
of a published stable release by hand: `SHA256SUMS` would no longer
match and the in-app updater would refuse the APK.

## What the in-app updater checks (Android)

Before the system installer is opened, the app:

1. fetches the release from `/releases/latest` (or `dev-latest` on the
   dev channel);
2. downloads `SHA256SUMS` from the same release and finds the line for
   the APK asset name — if the file or the line is missing, the update
   is refused before the APK is downloaded;
3. downloads the APK and compares its SHA-256 with that line;
4. checks that the APK is signed by the same certificate as the
   installed app (`GET_SIGNING_CERTIFICATES` on Android 9+,
   `GET_SIGNATURES` before);
5. re-checks the digest and signer natively right before launching the
   installer.

Any failure deletes the download and shows a localized error. The
checksum catches corrupted, truncated or swapped downloads; the
certificate pin is what stops an APK that was not signed with Vaulta's
key, even if it was uploaded to a release with a matching checksum.

## Verifying a download manually

Download the asset(s) and `SHA256SUMS` from the same release into one
folder.

Linux / macOS:

```sh
sha256sum --check --ignore-missing SHA256SUMS
# macOS without coreutils (download every asset listed in SHA256SUMS first):
shasum -a 256 --check SHA256SUMS
```

Windows (PowerShell):

```powershell
$expected = (Select-String -Path SHA256SUMS -Pattern 'vaulta-windows-bundle.zip').Line.Split(' ')[0]
$actual = (Get-FileHash vaulta-windows-bundle.zip -Algorithm SHA256).Hash.ToLower()
if ($actual -eq $expected) { 'OK' } else { 'MISMATCH - do not run it' }
```

To check who signed the APK (requires Android build-tools):

```sh
apksigner verify --print-certs vaulta.apk
```

The certificate digest must be the same across releases. A different
digest means the APK was not signed with Vaulta's key: do not install
it, and report it as described in [`SECURITY.md`](../SECURITY.md).

The Windows bundle is not Authenticode-signed yet, so SmartScreen will
warn on first launch; the `SHA256SUMS` check is the integrity check for
Windows today.
