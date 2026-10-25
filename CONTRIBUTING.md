# Contributing to Vaulta

Vaulta is an offline-first password manager. A change here can expose a
user's whole vault, so contributions are welcome but they follow a
defined flow: **Conventional Commits 1.0.0**, **atomic commits**, **small
pull requests**, and **Conventional Comments** in the review.

This guide is the reference for that flow. Read it before opening a pull
request.

- **Code of Conduct:** [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- **Security vulnerabilities:** [SECURITY.md](SECURITY.md) — never a
  public issue, discussion, or pull request
- **License:** MIT, see [LICENSE](LICENSE)

## What we accept

- Bug reports, with steps to reproduce.
- UX feedback.
- Feature requests (use the feature request form).
- Documentation fixes and improvements.
- Code contributions through pull requests.
- Security concerns reported privately to the maintainer.

## What we do not accept

- Public redistribution of beta builds.
- Contributions that ship real vault contents, master passwords, or
  other people's data. Use a throwaway test vault.
- Unreviewed mega-PRs. Split the work; see
  [Small pull requests](#small-pull-requests).
- Dependency bumps without a stated reason and a green CI run.
- Changes that weaken an existing security control without a threat
  model in the pull request.

## Before you start

1. Search the open and closed issues first: the problem may already be
   tracked.
2. For a bug, use the
   [bug report form](.github/ISSUE_TEMPLATE/bug_report.yml). For a new
   capability, use the
   [feature request form](.github/ISSUE_TEMPLATE/feature_request.yml).
3. For anything larger than a small fix, open an issue first and agree
   on the approach before writing code. That keeps the pull request
   reviewable and avoids duplicated work.
4. Beta testers without repository access keep using the bug report
   form — see [docs/private-beta.md](docs/private-beta.md). A bug report
   never needs a fork.

## Local setup

Requirements:

- Flutter **3.47.7** (pinned in [`mise.toml`](mise.toml); the project
  targets Dart SDK `^3.11.3`).
- Android toolchain for Android builds.
- Visual Studio 2022 Build Tools with the **Desktop development with
  C++** workload for Windows builds.

```bash
mise install          # installs the pinned Flutter toolchain
flutter pub get
flutter analyze
flutter test
```

The same checks run in CI ([`.github/workflows/flutter-ci.yml`](.github/workflows/flutter-ci.yml)):
`flutter analyze`, `flutter test`, `flutter test --coverage` plus the
coverage gate below, and a Windows build smoke test on every pull
request.

```bash
flutter test --coverage
bash scripts/check_coverage.sh coverage/lcov.info lib/core/security 60
```

Pull requests that change Supabase migrations also run
[`.github/workflows/supabase-migrations-ci.yml`](.github/workflows/supabase-migrations-ci.yml),
which applies the migrations against a real Postgres instance.

## The contribution flow

1. **Branch from `master`.** Use a descriptive prefix:
   `feature/short-slug`, `fix/short-slug`, `docs/short-slug`,
   `chore/short-slug`, `refactor/short-slug`, `test/short-slug`.
2. **Commit in atomic steps.** One logical change per commit.
3. **Open a pull request against `master`** and fill in the template
   ([`.github/pull_request_template.md`](.github/pull_request_template.md)).
4. **Keep CI green.** Analyze, tests, the coverage gate, and the
   Windows smoke test must pass before review starts.
5. **Review with Conventional Comments.** The reviewer uses the prefixes
   below; `issue:` and `todo:` block the merge.
6. **Merge.** The maintainer merges once the review is resolved and the
   branch is up to date with `master`.

### Commits: Conventional Commits 1.0.0

Every commit message follows
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

```text
<type>(<scope>)!: <description>
```

| Type       | Use it for                                                  |
| ---------- | ----------------------------------------------------------- |
| `feat`     | a new user-visible capability                                |
| `fix`      | a bug fix                                                    |
| `docs`     | documentation only                                           |
| `style`    | formatting only, no behavior change                          |
| `refactor` | restructuring, neither a fix nor a feature                   |
| `perf`     | a performance improvement                                    |
| `test`     | adding or fixing tests                                      |
| `build`    | build system, dependencies, packaging                       |
| `ci`       | CI configuration and workflows                               |
| `chore`    | maintenance that fits no other type                         |
| `revert`   | reverting a previous commit                                 |

Rules:

- The scope is optional and names the area: `feat(sync): ...`,
  `fix(ci): ...`, `docs(adr): ...`.
- A `!` after the scope or type marks a breaking change, and the body
  must explain it with a `BREAKING CHANGE:` footer.
- The description is imperative ("add", not "added"), lower case, no
  trailing period, at most 72 characters.
- The body explains **why**, not what the diff already shows. Reference
  the issue with `Closes #40` or `Refs #40`.

Examples from this repository:

```text
feat(security): block screen capture and harden secret copy on Android
fix(ci): revert public_member_api_docs to lib/core/ scope (was breaking CI)
docs(adr): add Status section to ADR-004 and ADR-005
refactor(sync): consolidate DeviceSyncLifecycle onto a single syncService param
chore(lint): extend public_member_api_docs to lib (info)
```

### Atomic commits

A commit is atomic when it does exactly one thing and can be reverted
without undoing unrelated work.

- One commit = one logical change. A refactor and the behavior change it
  enables are two commits.
- Tests and docs for a change travel in the same commit as the change.
- Do not mix formatting sweeps into functional commits.
- Fixup commits are for your own branch: squash them locally before
  pushing (`git rebase -i`) so the history the reviewer reads is the
  history that lands.

### Small pull requests

- One topic per pull request. If the description needs an "and", split
  it.
- Aim for **400 changed lines or fewer** (excluding lockfiles and
  generated files). A larger change is split into a chain of pull
  requests, each merged and reviewed on its own.
- A pull request that needs more than a few minutes of review is a
  pull request that needs splitting.
- Refactors land before the features that depend on them.

### Pull request expectations

- The title is the Conventional Commit subject of the main commit, so
  the squash-merge title stays Conventional Commits.
- The body follows the template: **Context and motivation**,
  **Changes**, **Reviewer guide**, **Evidence**, **Production
  checklist**.
- The issue is linked with `Closes #<id>` when the change resolves it.
- The Evidence section states the commands that were run and their
  result. "Should work" is not evidence.
- Force-push after a review started is fine (rebase), but ask the
  reviewer for a re-review.
- Dependabot pull requests are exempt from the Evidence section, but
  they still need a green CI run.

### Reviews: Conventional Comments

Reviews use the
[Conventional Comments](https://conventionalcomments.org) prefixes so
that the disposition of each comment is explicit.

| Prefix       | Meaning                                             | Blocks the merge |
| ------------ | --------------------------------------------------- | ---------------- |
| `praise:`    | appreciation, no action needed                      | no               |
| `nitpick:`   | a small, non-critical detail                        | no               |
| `suggestion:`| a suggested improvement to consider                  | no               |
| `question:`  | a question about the change                          | no               |
| `note:`      | an observation, out of scope for this pull request  | no               |
| `issue:`     | a problem that must be fixed before merging         | yes              |
| `todo:`      | a task that must be done before merging             | yes              |

```text
suggestion: Extract the key derivation into a helper so the test can pin it.
issue: lib/core/security/session.dart logs the master password at line 84.
todo: Add a regression test for the empty-vault case.
```

Non-blocking comments are advisory: the author decides whether to act
on them. A pull request is merged when no `issue:` or `todo:` is open.

### Production checklist

Every pull request confirms the items that apply to it:

- [ ] `flutter analyze` is clean.
- [ ] `flutter test` passes, and new behavior has a test.
- [ ] The coverage gate on `lib/core/security` still passes if that
      area changed.
- [ ] Documentation and `CHANGELOG.md` describe the change as it ships.
- [ ] The version in `pubspec.yaml` is bumped if the change ships
      behavior (the build number must increase on every release).
- [ ] Migrations, when present, are applied against a real database in
      CI and are reversible or documented as one-way.
- [ ] No secrets, credentials, real vault data, or signing material are
      included in the diff.

### Documentation contributions

Code, code comments, and public API docs are written in English. Some
repository documentation is written in Spanish — keep the language of
the file you are editing, and keep it consistent with its neighbors.
Claims about what the app does must match the code: if you change
behavior, update
[docs/security/hardening-status.md](docs/security/hardening-status.md)
and the README in the same pull request.

## Security-sensitive contributions

Changes to cryptography, key storage, unlock protections, data leakage
paths, sync authentication, or the in-app updater get a focused review.
Say so explicitly in the **Reviewer guide** section, name the threat you
are addressing, and include the evidence that the control still holds
(the test vectors, the refusal path, the threat-model entry). Never
report a vulnerability you found through a pull request — use
[SECURITY.md](SECURITY.md).

## Maintainer notes

Repository settings that enforce this flow:

- Do not grant write access to beta testers.
- Keep the repository private if the code should remain private.
- Enable branch protection on `master`.
- Require pull request review from the owner if collaborators are ever
  added.
- Require the Flutter CI checks to pass before merging.
- Cut releases from `master` only: `release.yml` refuses a tag whose
  commit is not an ancestor of `origin/master`.
