# Create your first vault

**What you need:** an Android phone (Android 11 or newer for biometric
unlock) or a Windows machine, and about five minutes.

**What you will end up with:** a vault protected by a master password you
chose, one credential stored and encrypted, and a working lock/unlock
cycle. You will also learn the one thing that matters about a password
manager: there is no reset.

> The app interface is bilingual. Switch it in **Settings → Language →
> App language** if the labels below do not match what you see.

---

## Step 1 — Install Vaulta

**Android.** Download the signed APK from the latest
[GitHub release](https://github.com/Rene-Kuhm/vaulta/releases/latest/download/vaulta.apk)
and install it, or push it over ADB:

```bash
adb install -r vaulta.apk
```

**Windows.** Download the
[bundle](https://github.com/Rene-Kuhm/vaulta/releases/latest/download/vaulta-windows-bundle.zip),
extract **everything** into one folder (for example `C:\Program Files\Vaulta\`)
and run `vaulta.exe`. The executable needs the DLLs and the `data/` folder
next to it; moving it on its own will not start the app. Windows
SmartScreen may ask you to confirm the run because the binary is not
code-signed — that is expected.

Your vault is stored encrypted in the platform's secure storage (Android
Keystore / Windows Credential Manager). The current build keeps it as a
single encrypted blob; an encrypted local database is implemented and
tested but switched off by default — see
[ADR 0007](../adr/0007-encrypted-local-database.md).

## Step 2 — Choose a master password

On first launch Vaulta shows the **Secure onboarding** screen and asks for a
master password twice.

There is no "forgot my password" link, and there will never be one. The
master password is the only key to the vault: it is what derives the key
that encrypts your entries. Nobody — including the Vaulta team — can
recover a vault whose master password is lost.

**What Vaulta accepts**, enforced by `lib/core/security/password_policy.dart`
and following NIST SP 800-63B §3.1.1.2:

| Rule | Value | Why |
| --- | --- | --- |
| Minimum length | 12 characters | Above the NIST minimum of 8, because this password is the only thing between a stolen vault blob and every credential you own |
| Maximum length | 1024 characters | Bounds the key-derivation input so a huge paste cannot make unlock hang |
| Breached-password screening | A shipped list, checked offline | Catches `password`, `letmein12345`, `P@ssw0rd` and similar |

What Vaulta deliberately does **not** require, per the same NIST section:

- **No character-class rules.** You do not need an upper case, a digit and a
  symbol. Those rules push people toward predictable patterns like
  `Password1!`, which are weaker than a long passphrase.
- **No periodic rotation.** Your master password is not supposed to expire.
- **Paste is not blocked.** Use your password manager to paste it.

**The screening never touches the network.** Vaulta checks the candidate
against a bundled list on the device. No password, prefix or hash of your
password is sent anywhere.

**A note on typing the same password two ways.** Vaulta normalizes the
master password to Unicode NFC before deriving the key, so `café` typed as
`café` and as `café` (the accent composed two different ways) unlock the
same vault. This holds for vaults created on the current record format.

**Write it down somewhere safe.** A password manager that cannot recover
your data is only as good as the copy of the password you keep outside it.
A good place is a sealed envelope, a hardware key, or another password
manager you already trust.

## Step 3 — Store your first credential

Once the master password is accepted, the **dashboard** opens. It is the
Vault tab, and it shows the security posture of your vault.

1. Tap **Create encrypted entry** (the primary action on the dashboard).
2. Fill in the **New entry** form:
   - **Title** — what this entry is, for example `GitHub`.
   - **Username or email** — the account identifier.
   - **Password or secret** — the value to store.
   - **Website or app** — optional; it is what the autofill service matches
     on Android.
   - **Notes** — optional.
   - **Category** — Work, Finance, Personal or Infrastructure.
   - **Favorite entry** — optional; favourites get their own filter on the
     dashboard.
3. Need a password? Use the **Password generator** inside the editor: pick
   the length and which character sets to use, then **Generate and
   insert**. The generated value is written into the encrypted payload, not
   left in a buffer.
4. Save.

The entry is encrypted before it touches storage, title included: the
whole item is sealed under its own key, so nothing readable is written to
disk. In the current build, searching the vault decrypts the items it
searches through — that cost is exactly what the encrypted database in
[ADR 0007](../adr/0007-encrypted-local-database.md) is designed to remove.

**Eight characters is a floor, not a target.** The editor asks for at least
8 characters for an entry secret. That is a floor to catch typos, not a
security target. For the services that matter, use the generator.

## Step 4 — Copy the secret

Open the entry and copy the secret with the copy button.

Vaulta clears the clipboard about **30 seconds** later, and only if the
copied content has not changed in the meantime — so copying one secret and
then another does not wipe the second one early.

## Step 5 — Lock the vault

Vaulta locks itself, and you can also lock it on demand:

- **Auto-lock on background** is on by default. The vault locks when the app
  becomes inactive, paused or detached.
- **Foreground idle auto-lock** is 15 minutes by default and is configurable
  in **Settings → Foreground idle auto-lock**.
- **Settings → Lock now** locks immediately.

## Step 6 — Unlock again

The unlock screen accepts the master password. On Android, if you enabled
biometrics in Step 7, the fingerprint button is available there instead.

If you mistype the master password too many times, Vaulta applies an
**exponential lockout**: the wait grows with each failure and is stored on
the device, so restarting the app does not reset it. That is deliberate —
it is what stops an attacker with your unlocked phone from grinding through
candidate passwords.

## Step 7 — Turn on biometric unlock (Android)

**Settings → Use biometrics to unlock on Android.**

Requirements and behaviour:

- **Android 11 (API 30) or newer.** Below that, Vaulta refuses to create
  the biometric key instead of creating a weaker one that your device PIN
  could also authorize. The refusal is verified by an instrumented test on
  a real device; see
  [the verification record](../reference/api30-biometric-refusal-verification.md).
- The key is an RSA-2048 key generated in the **Android KeyStore**, tied to
  strong biometrics. It wraps the vault's data key, and that key is only
  released after a successful `BiometricPrompt`.
- **The master password is still the recovery path.** You need it to
  activate biometrics, to re-enroll them, and whenever the biometric
  envelope cannot be unwrapped.
- **Changing the master password re-enrolls biometrics**, because the
  wrapped key changes with it.
- If you remove the enrolled biometrics in the Android settings, Vaulta
  falls back to the master password and asks you to enrol again.

On iOS, macOS and web there is no biometric binding yet; those platforms
unlock with the master password only.

## Step 8 — Check what you have

Two screens are worth opening once your vault has a few entries:

- **Vault health report** (dashboard quick action) lists the passwords that
  need rotation and the secrets shared between entries.
- **Favorites** filter, next to search, shows the entries you marked.

## Step 9 — Make a backup, because the app has no cloud copy

The published builds ship with remote sync **off**: no Supabase keys are
defined in the release pipeline, so the app is offline-only. That means the
only copy of your vault is the device.

Export an encrypted backup from **Settings → Encrypted backup → Export
backup** and keep the file somewhere else. It is a `.vaulta` file,
encrypted with **a separate backup password** that you choose at export
time — not your master password. The backup password follows the same
policy as the master password (at least 12 characters, and it is screened
against the leaked-password list), and Vaulta cannot recover it for you
either. The backup is designed to be stored in places you do not control
(cloud drive, USB stick, e-mail to yourself) and to be restored on a new
device.

Read [How Vaulta encrypts your vault](../explanation/how-vaulta-encrypts-your-vault.md)
for what the backup file contains, and
[ADR 0006](../adr/0006-encrypted-backup-format.md) for the full decision.

---

## What this tutorial did not cover

- **Remote sync.** Off in published builds, experimental by design. See
  [ADR 0002](../adr/0002-sync-versioning-cas-idempotency-tombstones.md).
- **Plaintext export.** **Settings → Encrypted backup → Export unencrypted
  (CSV/JSON)** exports the vault in the clear, behind a warning and a
  re-authentication, for migrating to another manager. Those files are
  unencrypted: treat them as a live copy of your passwords and delete them
  when you are done.
- **Autofill.** Android only, and only on Android 12 or newer for
  web-domain matching. See
  [ADR 0008](../adr/0008-android-autofill.md).
- **Changing the master password.** Doable in **Settings → Change master
  password**. It re-derives the vault key and re-enrolls biometrics.

## If something goes wrong

| Symptom | What it means |
| --- | --- |
| The unlock screen says the wait is longer after several wrong attempts | The exponential lockout is running. Wait it out; it is stored on the device |
| Biometric unlock is unavailable | Either no biometrics are enrolled on the device, or the Android version is below 11. The subtitle in **Settings** tells you which |
| The dashboard says it could not decrypt the local vault | Lock and unlock again with the master password, then retry. The app hides the details on purpose |
| The master password is lost | The vault cannot be recovered. Not by you, not by Vaulta. This is why Step 2 tells you to write it down |
