# Import your existing passwords

**What you need:** an export file from the password manager you are leaving,
and Vaulta unlocked on the device you want to import into.

**What you will end up with:** the credentials from that export, stored and
encrypted in Vaulta — after you have seen exactly what is going in.

> The dashboard action is labelled **Importar desde CSV o JSON**. That label
> is still hard-coded in Spanish in the app; the rest of the interface
> follows the language you picked in **Settings → Language**.

---

## Before you start: export, then protect the export

Most password managers can export their vault to a file. Get that file
first, then start the import.

The export file is **plaintext**. It contains every password you own, with no
encryption, in whatever folder your downloads go to. Two rules:

1. Import it, then **delete the export file**. Do not leave it in
   Downloads, and do not upload it to a cloud drive "just in case".
2. **Export in a format Vaulta can read.** The only encrypted file Vaulta
   opens is a KeePass database (`.kdbx`). If your old manager offers an
   encrypted export as well, take the plain one: Vaulta parses the
   decrypted CSV or JSON, not the encrypted container. If the only export
   your manager produces is encrypted, decrypt it there first and export
   the plain form.

## Step 1 — Open the import screen

Unlock the vault, then on the dashboard find the **Importar desde CSV o JSON**
quick action (the one with the upload icon, under **Create encrypted
entry**).

The screen lists the formats Vaulta recognises:

| Format | File |
| --- | --- |
| Generic CSV | `.csv` with no vendor-specific layout |
| Notion CSV | Notion database export |
| Chrome CSV | Chrome's built-in password manager export |
| Bitwarden CSV | Unencrypted Bitwarden CSV export |
| Bitwarden JSON | Bitwarden JSON export |
| 1Password CSV | 1Password CSV export |
| LastPass CSV | LastPass CSV export |
| KeePass CSV | KeePass CSV export |
| KeePass KDBX | Encrypted KeePass database (`.kdbx`) |
| JSON | Generic JSON object or array of credentials |

Vaulta detects the format from the file itself — you do not choose it.

## Step 2 — Choose the file

Tap **Elegir archivo** and pick the export. The file is read **on the
device**. Nothing is uploaded.

If you picked a `.kdbx` database, the screen asks for its **master password**
and, optionally, a **key file** before it can open the database. A wrong
master password is reported as such; it is not retried silently.

## Step 3 — Read the preview before you commit

This is the part that matters. The screen shows a **preview** of what will
be created, and **nothing is written to your vault until you confirm**.

The preview tells you three things:

- **How many entries are importable.** The counter in the app bar shows it.
- **Which rows have warnings.** A warning means the row was kept but you
  should look at it — for example, a missing title that Vaulta filled in
  from another column, or a field that the source format did not carry.
- **Which rows are duplicates.** Vaulta compares each candidate against
  the entries you already have. Two candidates match when their normalized
  title, username and website are all equal, or when they share the same
  secret and at least one of username, website or title. A duplicate is
  **not importable**: it is listed, with the reason, so you can decide that
  the existing entry is the one you want to keep.

Rows with **errors** are not importable either. They stay in the list with
the reason, so you can fix the source file and come back, or add those
few entries by hand.

## Step 4 — Import

Confirm the import. The count in the app bar tells you how many entries are
about to be created, and every one of them is encrypted with the vault's
per-item key as it is saved — the plaintext never lands on disk in the
clear.

## Step 5 — Tidy up

After the import:

1. **Delete the export file.** This is the one step people skip.
2. Open the **Vault health report** on the dashboard. An import brings in
   whatever weaknesses the old manager had: passwords that are too short,
   reused across entries, or reused across services.
3. Rotate what the report flags. The generator in the entry editor is the
   fastest way.
4. Check the **Favorites** filter and mark what you reach for daily.

## Step 6 — Back up the result

Your vault now exists in two places: the old export (which you are about to
delete) and the device. Export an encrypted `.vaulta` backup from
**Settings → Encrypted backup → Export backup** and store it outside the
device — it is encrypted under a **separate backup password** that you
choose at export time. See
[Create your first vault](./create-your-first-vault.md#step-9--make-a-backup-because-the-app-has-no-cloud-copy)
and [ADR 0006](../adr/0006-encrypted-backup-format.md).

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| "Choose a file" finds nothing useful | The format is not one Vaulta detects | Export again as CSV or JSON instead of a proprietary archive |
| A `.kdbx` file will not open | Wrong master password, or the database needs a key file | Re-enter both; a wrong master password is reported explicitly |
| An entry is listed but cannot be imported | It is a duplicate of an entry you already have | Delete the old entry first, or keep the existing one and skip the row |
| An entry is listed with an error | The source row is missing something Vaulta needs, such as a title | Fix the row in the source file, or add that entry by hand |
| The import looks empty | The file parsed, but every row had an error | Read the error text on each row before retrying |

## What this tutorial did not cover

- **Moving a vault between devices.** Import is for moving *credentials* into
  an empty vault. To bring a whole Vaulta vault to another device, use the
  encrypted `.vaulta` backup instead.
- **Remote sync.** Off in published builds; see
  [ADR 0002](../adr/0002-sync-versioning-cas-idempotency-tombstones.md).
- **Plaintext export back out.** Vaulta can export to CSV or JSON, behind a
  warning and a re-authentication, if you need to migrate again.
