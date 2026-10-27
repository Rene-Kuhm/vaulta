# Explanation

Understanding-oriented documentation. Each page here answers *why* Vaulta
behaves the way it does. It is written for a reader who wants the reasoning,
not the steps.

| Page | What it explains |
| --- | --- |
| [Threat model](./threat-model.md) | What Vaulta defends against, what it explicitly does not, and the residual risks the user accepts by choosing it |
| [How Vaulta encrypts your vault](./how-vaulta-encrypts-your-vault.md) | From master password to stored record: key derivation, the DEK, per-item keys, and what is stored in the clear |

## How to read these

- **These pages are honest about limits.** Vaulta is a young product and its
  documentation says so. A page that hid a limitation would be worse than no
  page at all.
- **Claims point at the code.** When a page makes a claim about behaviour, it
  names the file and line, so you can check it.
- **Design decisions are separate.** The *what* of a decision is in
  [`../adr/`](../adr/); these pages explain the reasoning that a reader
  outside the project needs.

## Not in this folder

- Procedures live in [`../how-to/`](../how-to/).
- Walkthroughs live in [`../tutorials/`](../tutorials/).
- Facts you look up live in [`../reference/`](../reference/).
