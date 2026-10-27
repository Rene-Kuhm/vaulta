# Android release signing

Vaulta release builds must not use the debug keystore.

## Option A: `android/key.properties`

Create this file locally. Do not commit it.

```properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

On Windows, prefer forward slashes in `storeFile`, for example
`F:/Vaulta-release-secrets/vaulta-upload-keystore.jks`. Raw backslashes
can be interpreted as escapes by Gradle/Kotlin and produce an invalid
path.

## Option B: environment variables

Set these in CI or your shell:

- `VAULTA_UPLOAD_STORE_FILE`
- `VAULTA_UPLOAD_STORE_PASSWORD`
- `VAULTA_UPLOAD_KEY_ALIAS`
- `VAULTA_UPLOAD_KEY_PASSWORD`
- `VAULTA_RELEASE_TOKEN` (optional fallback for publishing GitHub Release assets when the built-in Actions token is rejected by the Releases API)

If none are present, Gradle leaves `release` unsigned instead of falling back to debug signing. That is intentional.

Android only accepts in-place updates when the installed app and the
incoming APK are signed with the same key. A debug-signed development
install cannot be updated to the release upload key via OTA; migrate by
installing a matching debug build for development, or by uninstalling
and installing the release-signed APK for store/OTA validation.

## GitHub Actions OTA secrets

The rolling `dev-latest` OTA workflow builds Flutter's internal
`app-release.apk`, then publishes the release asset as `vaulta.apk`, so
GitHub must also have:

- `VAULTA_UPLOAD_KEYSTORE_BASE64`
- `VAULTA_UPLOAD_STORE_PASSWORD`
- `VAULTA_UPLOAD_KEY_ALIAS`
- `VAULTA_UPLOAD_KEY_PASSWORD`

From a machine that has `android/key.properties` and the keystore, set them without printing secret values:

```powershell
$props = @{}
Get-Content android\key.properties | ForEach-Object {
  if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
    $props[$matches[1].Trim()] = $matches[2].Trim()
  }
}
$storeFile = $props['storeFile']
if (-not [System.IO.Path]::IsPathRooted($storeFile)) {
  $storeFile = Join-Path (Resolve-Path android).Path $storeFile
}
[Convert]::ToBase64String([System.IO.File]::ReadAllBytes($storeFile)) |
  gh secret set VAULTA_UPLOAD_KEYSTORE_BASE64 --repo Rene-Kuhm/vaulta
$props['storePassword'] | gh secret set VAULTA_UPLOAD_STORE_PASSWORD --repo Rene-Kuhm/vaulta
$props['keyAlias'] | gh secret set VAULTA_UPLOAD_KEY_ALIAS --repo Rene-Kuhm/vaulta
$props['keyPassword'] | gh secret set VAULTA_UPLOAD_KEY_PASSWORD --repo Rene-Kuhm/vaulta
```

Verify only names/timestamps, never values:

```bash
gh secret list --repo Rene-Kuhm/vaulta
```
