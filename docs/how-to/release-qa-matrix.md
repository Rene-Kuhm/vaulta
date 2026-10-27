# Vaulta release QA matrix

Run this matrix before promoting any APK/App Store/TestFlight/public build.

## Android signed OTA

- [ ] Confirm the installed APK and the OTA APK use the same signing key. Android will reject an in-place update when moving from a debug-signed install to the release upload key.
- [ ] Install a clean signed APK.
- [ ] Create a master password and confirm the vault opens.
- [ ] Lock and unlock with the master password.
- [ ] Activate biometric unlock with the master password.
- [ ] Lock and unlock with biometrics.
- [ ] Remove or change enrolled biometrics in Android settings, then verify Vaulta falls back to master password and asks for re-enrollment.
- [ ] Change the master password and verify biometric unlock is re-enrolled for the new vault DEK.
- [ ] Publish a new `dev-latest` signed APK from GitHub Actions and update in place from Settings.
- [ ] Confirm app data, vault records, biometric enrollment, and secure storage survive the OTA update.

## Core vault behavior

- [ ] Create, edit, view, search, and delete vault entries.
- [ ] Generate a password and insert it into a vault entry.
- [ ] Copy a secret and verify clipboard auto-clear when unchanged.
- [ ] Verify background auto-lock.
- [ ] Verify foreground idle auto-lock.
- [ ] Verify wrong master password and weak master password error states.

## Optional Supabase sync

Supabase sync is outside the default public MVP until all items below pass.

- [ ] Start with `SUPABASE_URL` and `SUPABASE_ANON_KEY` absent and confirm the app remains offline-first.
- [ ] Enable Supabase in a staging project with test accounts only.
- [ ] Verify device registration, session revocation, push, pull, conflict resolution, and restore.
- [ ] Verify offline edits sync correctly after reconnect.
- [ ] Verify privacy policy and store data-safety answers match the enabled sync behavior.

## Platform scope

- [ ] Android: biometric vault unlock works with `BIOMETRIC_STRONG`.
- [ ] iOS/macOS: do not claim biometric vault unlock unless a native binding is implemented and tested.
- [ ] Web/desktop: do not claim biometric vault unlock unless implemented and tested.
