# ADR-008: Autofill, the feature a password manager is judged by

- Status: Proposed
- Date: 2026-10-21
- Supersedes: none. Depends on ADR-001 (crypto) and ADR-007 (storage).

## Context

Vaulta stores credentials well and does not fill them. Today `AndroidManifest.xml`
declares no `<service>` at all, so there is no `AutofillService` and no
`AccessibilityService`; the "Access" tab is informational copy. That means the
user copies a secret out of the app by hand, which is the definition of a
password *store* rather than a password *manager*.

The reason this is not a small feature is one sentence: **when Android asks for a
credential, the vault is locked.** The DEK lives in memory only after unlock
(ADR-001), and the app locks on background (`autoLockOnBackgroundEnabled`, default
true) and after an idle timeout. The system asks on behalf of another app, while
Vaulta is not in the foreground, with no session.

So autofill is not "read a row and return it". It is a design for **asking the
user to unlock inside the system's fill UI**, safely, and then answering.

## Decision

### 1. A real `AutofillService`, with a two-phase answer

Declare a service bound by `android.permission.BIND_AUTOFILL_SERVICE`.

`onFillRequest` has two states and must never blur them:

- **Unlocked session available** → build datasets from the vault and return them.
- **Locked** → return a `FillResponse` with **no datasets** and an
  `authentication` intent (`FillResponse.setAuthentication`) pointing at a
  dedicated unlock activity. Android shows it, the user authenticates, and the
  system calls `onFillRequest` again. Only that second call returns data.

Two surfaces, two different rules — they were conflated in the first draft of this
ADR and the distinction matters:

- **The authentication affordance** (the "Unlock Vaulta" row the system shows while
  the vault is locked) carries a static label and an icon: **never a secret, never a
  title, never a username, never an item count**. Android renders it outside this
  process and it can be screenshotted, and it is shown *before* the user proves who
  they are.
- **The dataset rows** (the fill menu the user picks a credential from) do carry the
  item title and the username. That is the entire point of a fill menu: choosing
  blind is not a choice. They never carry the secret in the label.

The line is "what the user sees before authenticating" versus "what the user sees
in order to choose". The first leaks; the second is the product.

### 1b. One engine, and no headless one

The obvious way to make a system-started service talk to Dart is to give it its own
`FlutterEngine`. That is rejected, and the reason is not style:

- The service runs in the app's process: it declares no `android:process`, and
  `MainActivity` is a `FlutterFragmentActivity` with a single engine and no
  `FlutterEngineGroup`.
- A second engine has its own Dart heap. It **cannot see the unlocked session**, so
  it could not decrypt anything the main engine holds. The only ways to make it work
  would be to cache a session or a plaintext index somewhere both can read, or to
  reimplement the crypto in Kotlin — both are worse than having no autofill.
- A service holding its own engine also invites exactly the thing this ADR forbids
  (section 4): a place where decrypted data outlives the request.

So the service asks **the app's engine** over a MethodChannel. When that engine or
the channel is not available — app not running, vault locked — the answer is "not
available" and the response is the authentication intent from section 1. The bridge
holds a channel handle and nothing else: no session, no items, no cache.

### 2. The unlock path is the existing one, not a second one

The unlock activity calls `BiometricUnlockService.unlock()`, the same path the app
uses, so the Keystore envelope, the prompt policy and the attempt limiter cannot
diverge. If biometrics are unavailable it falls back to asking for the master
password, again through the existing service.

The activity sets `FLAG_SECURE`. It is the one screen in the product that a
screenshot could expose a credential next to.

### 3. Matching: host first, then explicit search

Android hands the service an `AssistStructure` for the requesting app. Matching
runs in this order, and the order is the decision:

1. **Exact host match** against `vault_hosts`, populated from `VaultItem.website`
   (the index ADR-007 already builds). A browser reports the page's web domain, so
   this covers the biggest real case.
2. **Package match**, when the requesting package's own declared web domains are
   known, resolved through `PackageManager.getVerifiedDomains` where the platform
   exposes it.
3. **Search-only dataset.** When neither matches, return a single dataset that
   opens Vaulta's picker scoped to that app, so the user can still fill without
   leaving the flow. This is the safety net: no silent no-op, no guessing.

**No fuzzy or substring matching on its own.** An autofill menu that offers the
wrong vault item next to a bank login is a phishing assist. A miss costs a tap; a
wrong suggestion costs a credential.

### 4. What the service may hold in memory, and for how long

The service process is the app process. An unlocked session in memory because the
user just filled a form is the same exposure the app already accepts while open,
so it is not a new class of risk — but it must not extend it:

- the fill flow never disables the existing lock policy;
- if `autoLockOnBackgroundEnabled` is on, the service does not keep a session
  beyond what `VaultSession` already lives for;
- **nothing is cached on disk**: no decrypted index, no "last filled" plaintext.

### 5. Storage: the blob works for the first version, and the measurement says for how long

The index lookup (`findByHost`) lives on the SQLite storage. On the blob path the
only way to answer is to decrypt the whole vault, which on the lock-free path
takes the cost measured in ADR-007: 501 encryptions and 179 KB for a save — the
read side is the same order.

That is acceptable **for a first version gated behind an experimental flag**, and
unacceptable as a default. The gate: with a 1,000-item vault, a locked→unlock→fill
round trip on the blob must be measured and recorded here. If it exceeds roughly
1.5 s of our own work, autofill ships only on the SQLite storage, and the flag
decision moves ahead of it.

### 6. Nothing leaves the device and nothing is logged

- No network call in the fill path.
- The service logs the request package and whether it answered from unlock, match
  or search — never a title, a username, a secret or a URL with a query string.
- Datasets are built only from the vault, never from anything the requesting app
  supplies.

## Consequences

Positive: Vaulta becomes a password manager instead of a password store, without a
second unlock path and without weakening the lock policy.

Negative and accepted:

- **More surface in the app process**: a system-bound service that can be started
  by other apps (through the framework, with the framework's permission model).
  This is risk item 2 and the reason the fill path gets its own review.
- **The first version needs the vault to be unlockable**: a user who removes
  biometrics and forgets the master password gets no fill. That is correct.
- **Package matching will miss some apps** until a curated mapping exists. The
  search-only dataset is the honest fallback.

## Rejected alternatives

- **Keep the vault unlocked to make filling easy.** Turns every fill into an
  unauthenticated read and defeats the product.
- **A separate autofill password or PIN.** A second credential to forget, and a
  second unlock implementation to keep in sync with the Keystore envelope.
- **AccessibilityService scraping instead of the Autofill framework.** Broader
  permissions, reads every screen of every app, and Play rejects it for this
  purpose.
- **Cache a decrypted index to disk.** One file away from a plaintext vault.
- **Return a "best guess" dataset when nothing matches.** Phishing assist.

## Verification plan

1. **Manifest and binding**: the service is declared, binds with
   `BIND_AUTOFILL_SERVICE`, and appears in the system's autofill settings.
2. **Locked request returns no data**: a test asserts that with no session the
   response has zero datasets and only an authentication intent.
3. **Two-phase flow on a real device**: fill in a browser with the vault locked →
   prompt appears → unlock → correct credential fills. Repeat with an unlocked
   vault: no prompt.
4. **No secret in the presentation**: assert the authentication label contains no
   title, username or item count.
5. **Wrong-app safety**: with no host and no package match, the only dataset is the
   search one; assert no vault item is offered directly.
6. **No plaintext in logs**: run the flow with logcat captured and grep the
   secret, the title and the username out of it.
7. **Round-trip timing** on the blob with 1,000 items, recorded in this ADR, to
   decide whether autofill can ship before the storage flag is default.

## Out of scope

Filling on iOS (Credential Provider), browser extensions, passkeys/WebAuthn
assertions, and any change to the crypto, storage or sync layers.
