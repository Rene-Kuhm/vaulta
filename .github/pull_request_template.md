<!--
Pull request template for Vaulta.

Fill every section. Keep the pull request small and focused: one topic,
one reason to review it. The merge is blocked while an `issue:` or
`todo:` comment is open, so leave a section empty only when it truly
does not apply.
-->

## Context and motivation

<!--
What problem does this solve, and for whom?
Link the issue it resolves (for example "Closes #40") and, if the
problem is not in an issue, describe the situation that motivated the
change.
-->

## Changes

<!--
What changed, by area, in a short list. Name the modules, screens, or
files a reviewer has to open. Keep it scoped: one topic per pull
request.
-->

## Reviewer guide

<!--
Help the reviewer. Say:
- where to start reading, and what to check first;
- the risky part of the change and why (security, migrations, data);
- how to run it locally (commands, build flavor, device);
- what is intentionally out of scope, so nobody reads it as an omission.
-->

## Evidence

<!--
What was run, and what came out. Paste the commands and their result
(analyze, tests, coverage gate, manual checks, screenshots or logs).
State explicitly anything you could not verify and why.
-->

## Production checklist

<!--
Confirm the items that apply. Unchecked items need a reason.
-->

- [ ] `flutter analyze` is clean.
- [ ] `flutter test` passes, and new behavior is covered by a test.
- [ ] The coverage gate on `lib/core/security` passes (`bash scripts/check_coverage.sh coverage/lcov.info lib/core/security 60`), if that area changed.
- [ ] Documentation, `CHANGELOG.md`, and `docs/security/hardening-status.md` match what the change actually ships.
- [ ] The version in `pubspec.yaml` is bumped, if the change ships behavior.
- [ ] Migrations apply against a real database and are reversible or documented as one-way.
- [ ] No secrets, credentials, real vault data, or signing material are in the diff.
