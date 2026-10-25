# Executed verification: the API < 30 biometric refusal

Vaulta refuses to mint the biometric envelope key below Android 11 (API 30)
instead of minting one that the device PIN could also authorize. Until this
run that decision was verified by reading code only
(`docs/reference/security-hardening-status.md`, "Unverified"); it is now verified by
execution on an API 29 device, and this page records the run, the device and
what is still not covered.

What is being verified, in the production code:

- `android/app/src/main/kotlin/com/insyd/gestor_contrasenas/KeystoreChannel.kt`
  - `MIN_BIOMETRIC_ONLY_AUTH_SDK = Build.VERSION_CODES.R` (30) — the floor.
  - `isAvailable()` answers `false` below API 30, before it probes enrolment.
  - `buildKeySpecForDevice()` throws `UnsupportedOperationException` below
    API 30, and `ensureKey()` builds the spec **before** it checks the alias,
    so a leftover key cannot keep unlocking.
  - `rsaEncrypt()` calls `ensureKey()` itself, so the seed-wrapping path
    cannot mint a key either.

No line of `KeystoreChannel.kt` was changed for this verification.

## The test

`android/app/src/androidTest/kotlin/com/insyd/gestor_contrasenas/KeystoreChannelApiRefusalTest.kt`

It runs through `androidx.test.runner.AndroidJUnitRunner`
(`testInstrumentationRunner` in `android/app/build.gradle.kts`) and drives the
production channel through the same entry point Dart uses —
`KeystoreChannel.onMethodCall` — with a real `FlutterEngine` and the real
`AndroidKeyStore` of the device it is installed on. No fakes, no reflection
into the refusal logic, and no assertion over `Build.VERSION.SDK_INT`: the API
level only selects which behaviour this device is supposed to show.

| Test | What it asserts |
|---|---|
| `belowApi30ReportsUnavailableAndMintsNoKey` | API < 30: `isAvailable` → `false`; `ensureKey` → `KEYSTORE` error naming the API 30 floor; no key at `vaulta_biometric_envelope_v1` before or after; `rsaEncrypt` errors and mints nothing either. |
| `belowApi30RefusesEvenWhenALeftoverAliasExists` | API < 30 with an entry already sitting at the production alias: `ensureKey` still refuses (spec built before the alias check) and never hands the leftover key to Dart. |
| `atApi30AndAboveHasNoApiLevelRefusal` | API ≥ 30: no API-floor refusal is left. With a strong biometric enrolled the key is minted and `isAvailable` → `true`; with nothing enrolled the platform refuses the keygen (`At least one biometric must be enrolled ...`), no key exists, `isAvailable` → `false`, and the reported error is never the API-floor message. |

Tests that do not apply to the device they run on are skipped with JUnit
assumptions, so a single class runs on both an API 29 and an API 30+ device.

## Run recorded here: API 29 emulator

- Date: 2026-10-24.
- Device: AVD `vaulta-a10`, `system-images;android-29;google_apis;x86_64`,
  Android 10, **API 29**, x86_64, booted headless with
  `-gpu swiftshader_indirect` (no KVM problem: `/dev/kvm` present).
- Command, from the repository root:

  ```bash
  ANDROID_HOME=~/Android/Sdk bash scripts/verify_api30_biometric_refusal.sh
  ```

  The script boots the AVD (and creates it from the API 29 image when it is
  missing), builds `:app:assembleDebug` and `:app:assembleDebugAndroidTest`,
  installs both APKs, runs
  `am instrument -w -r -e class com.insyd.gestor_contrasenas.KeystoreChannelApiRefusalTest com.insyd.gestor_contrasenas.test/androidx.test.runner.AndroidJUnitRunner`,
  prints the per-test outcome and stops the emulator it started.

- Result: **PASSED on API 29** (`OK`, `INSTRUMENTATION_CODE: -1`):

  ```text
    PASS     belowApi30RefusesEvenWhenALeftoverAliasExists
    PASS     belowApi30ReportsUnavailableAndMintsNoKey
    SKIPPED  atApi30AndAboveHasNoApiLevelRefusal
  [verify-api30] RESULT: PASSED on API 29
  ```

  On this device the refusal is therefore observed by execution: the envelope
  key provider answers unavailable, `ensureKey` and `rsaEncrypt` refuse, and
  the `AndroidKeyStore` holds no envelope key afterwards — including when a
  leftover entry at the alias is present.

## The assertion is not a tautology

Checked once, on the same API 29 emulator: the below-30 branch of
`buildKeySpecForDevice` was temporarily replaced with a key build (the shape
of the regression this test guards), the suite was re-run, and it **failed**:

```text
  FAIL     belowApi30RefusesEvenWhenALeftoverAliasExists
  FAIL     belowApi30ReportsUnavailableAndMintsNoKey
java.lang.AssertionError: the refusal must name the API floor, got:
  java.lang.IllegalStateException: At least one biometric must be enrolled
  to create keys requiring user authentication for every use
[verify-api30] RESULT: FAILED on API 29
```

`KeystoreChannel.kt` was restored immediately afterwards; the committed diff
does not touch it.

## The API 30 and above half

Executed on a throwaway AVD (`system-images;android-36;google_apis;x86_64`,
Android 16, API 36), same APKs, same `am instrument` command:

```text
  SKIPPED  belowApi30ReportsUnavailableAndMintsNoKey
  SKIPPED  belowApi30RefusesEvenWhenALeftoverAliasExists
  PASS     atApi30AndAboveHasNoApiLevelRefusal
OK (3 tests)
```

So at API 36 the API-floor refusal is confirmed gone by execution: `isAvailable`
and `ensureKey` are driven by the device's enrolment state, and the error the
channel reports is the platform's enrolment error, not the API-30 message.

**Not executed:** the "minted key + `isAvailable` → `true`" branch of that
test, because the AVD has no biometric enrolled. Android refuses to generate an
auth-per-use key without one (`IllegalStateException: At least one biometric
must be enrolled to create keys requiring user authentication for every use`),
and enrolling a fingerprint on an emulator needs the Settings UI — `adb shell
cmd fingerprint` exposes `fingerdown` and `sync` only, no enrolment. That
branch needs a device or AVD with an enrolled fingerprint; the assertions are
in the test and are skipped by the `if` on `BiometricManager.canAuthenticate`.

The machine's shared `vaulta-a16` AVD could not be used for this half: it boots
with user 0 in `RUNNING_LOCKED`, so nothing can be instrumented there
(`SecurityException: Package com.insyd.gestor_contrasenas is not encryption
aware!`). The throwaway AVD was deleted after the run.

## What this does not cover

- The Dart half of the gate (`AndroidKeystoreEnvelopeKeyProvider`) keeps its
  own tests; this suite covers the Kotlin half only.
- The user-facing consequence (the biometric toggle staying off and the master
  password remaining the only unlock) is Dart behaviour, not asserted here.
- No CI job runs this suite: it needs an emulator with KVM, which the current
  workflows do not provide. It is a manual/release check, reproducible with the
  script above.
- `docs/reference/security-hardening-status.md` still says the refusal is "not
  test-covered"; that page is outside this change and needs its own update.

## Reproducing

```bash
export ANDROID_HOME=~/Android/Sdk          # or ANDROID_SDK_ROOT
bash scripts/verify_api30_biometric_refusal.sh [avd_name]
```

Exit codes: `0` every test applicable to the device passed, `1` a test failed,
`2` the environment cannot run the suite (missing SDK, image, KVM or flutter).
`KEEP_EMULATOR=1` leaves the emulator running for a second run.
