# CLAUDE.md

This file is a pointer, not a manual.

**The operating manual for this repository is [`AGENTS.md`](AGENTS.md).** Read
it before changing anything: it covers the toolchain, the build, test and lint
commands, the conventions (English artifacts, Conventional Commits, the
`public_member_api_docs` lint, Mermaid diagrams over images), the code layout,
the definition of done, and the rules that are not negotiable.

The two documents it depends on:

| Document | What it answers |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | How do I build, verify and change this repository? |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | How is the code put together, and which boundaries hold? |

The minimum needed to verify a change:

```bash
mise install        # once: installs the pinned Flutter 3.47.7
flutter pub get
flutter analyze     # must report "No issues found!"
flutter test        # the whole suite
```

Two things that are easy to get wrong:

- **Everything in `docs/`, `README.md`, `ARCHITECTURE.md` and `AGENTS.md` is
  written in English**, and so is every code comment, doc comment, identifier
  and commit message. Only the user-facing strings are localized, through
  `lib/l10n/app_*.arb`.
- **The cryptographic parameters, the lint rules and the coverage gate are
  fixed.** They are not obstacles to route around; changing one is a decision
  that needs an ADR.
