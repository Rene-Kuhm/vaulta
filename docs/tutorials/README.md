# Tutorials

Learning-oriented documentation. Each tutorial takes you from nothing to a
finished result, in order, with nothing to look up on the side.

| Tutorial | Who it is for | Result |
| --- | --- | --- |
| [Create your first vault](./create-your-first-vault.md) | Anyone installing Vaulta for the first time | A vault with one stored credential, locked and unlocked again |
| [Import your existing passwords](./import-your-existing-passwords.md) | Anyone coming from another password manager | A previewed import, saved and encrypted |
| [Set up your development environment](./set-up-your-development-environment.md) | Anyone who wants to build or contribute to Vaulta | A working toolchain, green tests and a coverage report |

## How to read these

- The tutorials assume the app is already installed. To install it, follow the
  [project README](../../README.md); the first tutorial also covers the first
  launch.
- They do not assume you know the internals. Where a tutorial mentions a
  cryptographic concept (master password, DEK, key derivation), it explains it
  inline and links to
  [How Vaulta encrypts your vault](../explanation/how-vaulta-encrypts-your-vault.md)
  for the full reasoning.
- They do not assume Vaulta is finished. Where a feature is Android-only,
  experimental, or pending a store submission, the tutorial says so.

## Not in this folder

- Recipes for a single goal (release, signing, migrations) live in
  [`../how-to/`](../how-to/).
- Facts you look up (audits, control status, templates) live in
  [`../reference/`](../reference/).
- The reasons behind the design live in [`../explanation/`](../explanation/).
