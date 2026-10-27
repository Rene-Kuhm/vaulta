# Set up your development environment

**What you need:** a machine with the Flutter toolchain, and about ten
minutes.

**What you will end up with:** a checked-out Vaulta that builds, whose tests
pass, and whose coverage gate is green — the same three checks CI runs on
every pull request.

---

## Step 1 — Install the toolchain

Vaulta pins its Flutter version in `mise.toml`:

```toml
[tools]
flutter = "3.47.7"
```

The project's Dart SDK constraint is `^3.11.3`, which is the one Flutter
3.47.7 ships. Installing a different Flutter version is the most common
cause of a confusing local failure, so use the pinned one.

**With [mise](https://mise.jdx.dev/):**

```bash
mise install          # installs Flutter 3.47.7 from mise.toml
mise exec -- flutter --version
```

**Without mise:** install Flutter 3.47.7 yourself and put it on `PATH`. The
rest of this tutorial is identical.

You also need, depending on what you plan to build:

| Target | Requirement |
| --- | --- |
| Android | Android SDK and a toolchain (Android Studio is the easy path) |
| Windows | Visual Studio 2022 Build Tools with the **Desktop development with C++** workload and the **C++ ATL** component |
| Linux / macOS desktop | The equivalent desktop toolchain for your platform |

## Step 2 — Fetch the dependencies

```bash
flutter pub get
```

## Step 3 — Run the three checks CI runs

```bash
flutter analyze
flutter test
```

`flutter analyze` must print `No issues found!`. The project enables
`public_member_api_docs` across `lib/**` (see
[ADR 0005](../adr/0005-repository-hygiene-lints-and-coverage.md)), so an
undocumented public member is reported as a warning, not a style nit.

`flutter test` runs the whole suite. If a test fails, fix it or understand
why before moving on: the suite is the project's regression net.

## Step 4 — Run the coverage gate

CI does not just run the tests, it measures them:

```bash
flutter test --coverage
bash scripts/check_coverage.sh coverage/lcov.info lib/core/security 60
```

The script prints the measured coverage and exits non-zero below the
threshold. **The threshold CI enforces is 60% over `lib/core/security/`**
(`scripts/check_coverage.sh` defaults to 50, so pass the threshold
explicitly, as the workflow does).

The gate measures `lib/core/security/` only, by decision: it is the part of
the codebase where a silent regression is a security regression. Coverage
elsewhere is printed for visibility but does not block.

## Step 5 — Run the app

```bash
flutter run                 # on the attached device or emulator
flutter devices             # what is available
```

## Step 6 — Build the release artifacts

```bash
flutter build apk --release
flutter build windows --release
```

The Windows build lands in `build/windows/x64/runner/Release/`. The
executable it produces is named `gestor_contrasenas.exe`; the published
bundle renames it to `vaulta.exe` when packaging, and it has to ship with
the DLLs and the `data/` folder next to it.

**A release APK must not be signed with the debug keystore.** Set up the
upload key before you build one:
[Sign an Android release](../how-to/android-release-signing.md).

## Step 7 — Run the Android instrumented test

One security behaviour cannot be tested on the JVM: the refusal to mint a
biometric envelope key below Android 11. It is verified on a real API 29
emulator:

```bash
bash scripts/verify_api30_biometric_refusal.sh
```

The script boots the `vaulta-a10` AVD (API 29), installs the debug APK and
the test APK, and runs `KeystoreChannelApiRefusalTest`. It needs
`ANDROID_HOME`, the `system-images;android-29;google_apis;x86_64` image and
KVM. The recorded run is in
[the verification reference](../reference/api30-biometric-refusal-verification.md).

## Step 8 — Run the database migrations (only if you touch sync)

The migrations under `supabase/migrations/` are applied by CI to a
throwaway PostgreSQL on every pull request, so a broken migration fails the
PR instead of a deployment. To do it locally, see
[Apply the Supabase migrations](../how-to/apply-supabase-migrations.md).

Remote sync is **off** in published builds: it only activates when the build
defines `SUPABASE_URL` and `SUPABASE_ANON_KEY`. The CI pipeline does not
define them.

---

## Where things live

| Path | What it holds |
| --- | --- |
| `lib/core/` | The domain: security, sync, storage. This is where the cryptography and the sync contract live |
| `lib/features/` | One folder per feature: vault, security, settings, access, autofill, backup, health, totp, sync |
| `lib/app/` | Design system, theming, localisation, bootstrap |
| `test/` | The test suite, mirroring `lib/` |
| `docs/` | The documentation, organised with Diátaxis — see [`docs/README.md`](../README.md) |
| `odd/tasks/` | The task documents that recorded how each feature was built |
| `openspec/changes/` | The change proposals and their specs |
| `supabase/migrations/` | The SQL that creates the optional sync backend |

## Before you open a pull request

```bash
flutter analyze
flutter test
flutter test --coverage && bash scripts/check_coverage.sh coverage/lcov.info lib/core/security 60
```

Then check the documentation you touched: the pages under `docs/` are the
ones users read, and they state where the code is. If you changed behaviour,
the matching page is now wrong, and the code wins.

Two rules the project holds itself to:

- **Where a page and the code disagree, the code wins.** Fix the page.
- **Do not weaken a security control to make a test pass.** The security
  posture is documented, with evidence, in
  [the hardening status](../reference/security-hardening-status.md).
