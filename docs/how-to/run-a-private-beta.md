# Vaulta private beta

Vaulta private beta is for trusted friends/testers only. Testers receive an app build or hosted demo link, not repository access.

## Rules for testers

- Do not request repository access.
- Do not submit pull requests.
- Do not modify, fork, decompile, redistribute, or publish the app.
- Do not store real production passwords during beta testing.
- Report problems with clear steps, screenshots/video if possible, and device/browser details.
- Treat all shared links/builds as private.

## What testers should report

- App crashes, freezes, or blank screens.
- Vault unlock/create/password-change problems.
- Entry create/edit/delete/search/generator problems.
- Confusing copy, broken layout, clipped text, bad translations.
- Security/UX concerns: clipboard, lock timing, biometric messaging, lost data.

## What testers should not do

- Do not test with passwords you actually use.
- Do not try to bypass app security beyond normal usage unless explicitly asked.
- Do not share builds/screenshots publicly.
- Do not send secrets in bug reports.

## Suggested beta distribution

Choose one path per beta round:

1. **Web preview** — fastest feedback, easiest sharing. Use for UI/flow validation.
2. **Android APK** — best mobile feedback before Play Store. Share only through private channel.
3. **iOS direct testing** — requires Apple signing/TestFlight/device setup; do later if needed.

## Owner checklist before sharing

- [ ] Run `flutter analyze`.
- [ ] Run `flutter test`.
- [ ] Test unlock/lock flow locally.
- [ ] Create/edit/delete/search one fake entry.
- [ ] Test password generator.
- [ ] Test clipboard copy and wait for auto-clear.
- [ ] Confirm build/link is shared privately.
- [ ] Tell testers not to use real passwords.

## Feedback format

Ask testers to use `.github/ISSUE_TEMPLATE/bug_report.yml` or copy this:

```text
Title:
Device/browser:
App version/build:
What happened:
What I expected:
Steps to reproduce:
Screenshots/video:
Did it happen again after restart?:
Notes:
```
