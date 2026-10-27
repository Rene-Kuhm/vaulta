# Reference

Lookup-oriented documentation. Each page here is a fact you consult: a
contract, a table, a status, a template. You are not supposed to read them
start to finish.

| Page | What you get |
| --- | --- |
| [Crypto architecture](./crypto-architecture.md) | The entry point for an external crypto audit: source index, cryptographic contract, and the questions still open for the auditor |
| [Security hardening status](./security-hardening-status.md) | What each security control does today, with `file:line` evidence and the commit that shipped it |
| [API < 30 biometric refusal verification](./api30-biometric-refusal-verification.md) | The recorded run of the instrumented test that proves the refusal happens on a real API 29 device |
| [Privacy policy template](./privacy-policy-template.md) | The template to adapt and publish before store submission |

## How to read these

- **Snapshot pages name their commit.** Pages that describe the state of the
  code say which commit they were checked against and when. If the commit
  moved on, the page is stale until it is refreshed — the code wins.
- **Evidence is `file:line`.** Claims about behaviour point at the file and
  line that implement them, so you can check them instead of trusting them.
- **Templates are not legal advice.** The privacy policy template needs
  legal and product review before it is published anywhere.

## Not in this folder

- Procedures live in [`../how-to/`](../how-to/).
- Walkthroughs live in [`../tutorials/`](../tutorials/).
- The reasoning behind the contracts lives in
  [`../explanation/`](../explanation/), and the decisions that produced them in
  [`../adr/`](../adr/).
