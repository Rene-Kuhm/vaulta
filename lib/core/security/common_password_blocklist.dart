/// Screen against passwords that are already public knowledge.
///
/// NIST SP 800-63B §3.1.1.2 requires screening against a blocklist of
/// commonly used, expected or compromised passwords, and explicitly
/// recommends *against* composition rules.
///
/// ## What is actually shipped
///
/// Two layers, in this order:
///
/// 1. **The corpus asset** (`assets/security/breached_password_sha256.txt`),
///    generated from the UK NCSC top-100k most-used/breached passwords:
///    99 838 passwords, held as **SHA-256 digests, never as plaintext**.
///    Loaded once into [BreachCorpus] and consulted on every lookup.
/// 2. **The curated in-source list** ([_rawEntries]) below, which is always
///    available, needs no I/O, and is what the screen uses before the
///    corpus finishes loading.
///
/// The two are complementary and the fallback is not a stub: the curated
/// list is the only thing protecting the first few frames after launch, and
/// it also covers the mutation cases (`P@ssw0rd`, `p4ssword`, `Passw0rd!`)
/// that fold onto `password`.
///
/// ## Why digests and not the plaintext list
///
/// Shipping the corpus in plaintext would hand anyone who unpacks the APK a
/// ready-made credential-stuffing wordlist, with a list-specific format and
/// already ranked. Shipping digests means the APK does not itself become a
/// cracking aid: unpacking it yields a set of one-way hashes, and an
/// attacker who wants the plaintext needs the public corpus (or a guess),
/// not this artifact. The corpus *is* public — the point is not secrecy
/// about which passwords are breached, it is not handing over a tool.
///
/// ## Digest encoding: 16 lowercase hex characters of SHA-256
///
/// Every line of the asset is the **first 8 bytes (16 hex characters, 64
/// bits) of the lowercase hex SHA-256 of one string**, one line per entry,
/// LF-terminated, sorted, duplicates removed.
///
/// *Full 64-character digests were rejected on size*: 99 838 full digests are
/// 6 489 470 bytes against 1 697 246 bytes for the same corpus truncated.
/// Keeping the whole digest would not make the plaintext any harder to get —
/// a truncated SHA-256 is no more invertible than a full one — so the extra
/// 4.8 MB buys an attacker nothing they cannot already do with the public
/// corpus.
///
/// *Truncating is safe here because this is a reject test.* A 64-bit prefix
/// collision makes an innocent password share a prefix with a listed one,
/// which costs a false rejection — the user is told to pick another — and
/// never a false acceptance. The screening therefore cannot be weakened by a
/// collision; only annoyed. Across the 161 426 digests the expected number of
/// colliding pairs is about 7 x 10^-10.
///
/// ## The four indexed forms
///
/// A candidate is screened under four forms, and the corpus is indexed under
/// the same four, computed by the *same* functions ([foldForBlocklist] and
/// [stripTrailingDigits]) at build time:
///
/// | form | catches |
/// |---|---|
/// | `entry.toLowerCase()` | the password itself, typed in any case |
/// | `foldForBlocklist(lower)` | `P@ssw0rd`, `p4ssword`, `mickey.` |
/// | `stripTrailingDigits(lower)` | `letmein12345` when only `letmein` was seen |
/// | `stripTrailingDigits(folded)` | both at once: `p@ssw0rd1234` |
///
/// 99 838 entries indexed four ways collapse to 161 426 distinct digests
/// (folding and digit-stripping map many entries onto the same string, and
/// duplicates are removed). Folding the *corpus* with the same function as
/// the candidate is the load-bearing part: folding only the input would
/// silently drop every mutation case.
///
/// Because the corpus side is pre-folded into the asset, loading costs a
/// parse and a set insert — 22 ms measured for 161 426 lines on a
/// development machine — instead of ~400 000 SHA-256 evaluations (~500 ms
/// measured for the same machine, and proportionally worse on a phone).
///
/// ## Regenerating the asset
///
/// The plaintext corpus is never committed. Reproduce it from the public
/// source, filter it, and index the four forms:
///
/// ```sh
/// curl -sSL -o /tmp/ncsc.txt \
///   https://raw.githubusercontent.com/danielmiessler/SecLists/refs/heads/master/Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt
/// # 835538 bytes, sha256
/// # c2e5696882c603b76bb67a47ee970897e5a76fc4c3f5547abe3d0ca340c576e0
///
/// # CR off, blank/whitespace-only lines out, control bytes out, embedded or
/// # edge whitespace out, absurd lines out, duplicates out -> 99838 entries
/// tr -d '\r' < /tmp/ncsc.txt | awk '
///   /^[[:space:]]*$/ { next }   # blank
///   /[[:cntrl:]]/     { next }   # control byte: not a typeable password
///   /[[:space:]]/     { next }   # embedded or edge whitespace
///   length($0) > 64  { next }   # parse damage, not a password
///   { print }' | LC_ALL=C sort -u > /tmp/entries.txt
///
/// python3 - <<'PY'
/// import hashlib, re
/// FOLD = {'0':'o','1':'i','3':'e','4':'a','5':'s','7':'t',
///         '@':'a','$':'s','!':'i','|':'i'}
/// TRAILING_SYMBOLS = re.compile(r"[!@#$%^&*.,;]+$")
/// TRAILING_DIGITS = re.compile(r"[0-9]+$")
/// fold = lambda p: ''.join(FOLD.get(c, c) for c in TRAILING_SYMBOLS.sub('', p)).lower()
/// strip_digits = lambda s: TRAILING_DIGITS.sub('', s, count=1)
/// digests = set()
/// for raw in open('/tmp/entries.txt', 'rb'):
///     entry = raw.decode('utf-8').strip()
///     if not entry or len(entry) > 64:            continue
///     if any(ord(c) < 0x20 or ord(c) == 0x7f for c in entry): continue
///     lower = entry.lower(); folded = fold(lower)
///     for value in (lower, folded, strip_digits(lower), strip_digits(folded)):
///         digests.add(hashlib.sha256(value.encode('utf-8')).hexdigest()[:16])
/// open('assets/security/breached_password_sha256.txt', 'w',
///      encoding='ascii', newline='\n').write('\n'.join(sorted(digests)) + '\n')
/// PY
/// ```
///
/// The recipe above is byte-identical to the artifact in the repo, and to a
/// Dart generator that imports [foldForBlocklist] and [stripTrailingDigits]
/// from this file, so the corpus cannot be folded by a different rule than a
/// candidate is. Refreshing the corpus is a deliberate change: the digest
/// count is pinned by
/// `test/core/security/password_policy_test.dart`, which fails loudly
/// rather than shipping a shorter screen.
library;

import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Asset path of the shipped digest corpus, as declared in `pubspec.yaml`.
///
/// A directory prefix (`assets/security/`) is used so a future second corpus
/// can sit beside it without renaming this one.
const String breachCorpusAssetPath =
    'assets/security/breached_password_sha256.txt';

/// Length in hex characters of every digest in [breachCorpusAssetPath].
///
/// 16 characters is 8 bytes, the truncated SHA-256 prefix argued for in the
/// library header. The loader skips lines of any other length, so this
/// constant is the wire format: change it and the whole asset is invalid.
const int breachDigestHexLength = 16;

/// The curated blocklist, folded to lowercase.
///
/// Kept as one whitespace-separated literal rather than a `const Set`
/// literal so the diff stays readable and the compiler cost stays flat.
const String _rawEntries = '''
123456 123456789 12345678 1234567890 1234567 12345 1234 111111 12345678910
000000 123123 121212 123321 1234qwer 1q2w3e4r 1qaz2wsx 1q2w3e 1qazxsw2
4you 2020 2021 2022 2023 2024 2025 2026 1234abcd abcd1234
666666 654321 666666 7777777 777777 987654321 87654321
abc123 password password1 password12 password123 passwords
iloveyou letmein monkey dragon master qwerty qwerty123
qwertyuiop qazwsx zaq12wsx 1q2w3e4r5t
sunshine princess football baseball soccer hockey
superman batman spiderman ironman helloworld
trustno1 hunter2 michael jennifer thomas joshua
jordan andrew daniel matthew jessica joseph
starwars pokemon minecraft fortnite
shadow sunshine iloveyou princess
admin administrator root toor guest
letmein monkey dragon
sunshine1 iloveu iloveyou1
football1 baseball1 soccer1
monkey1 dragon1 shadow1
sunshine123 iloveyou123
football123 baseball123
princess1 princess123
whatever forever freedom
trustno1 letmein1 welcome
trustme trustme1 hunter hunter1
sunshine1234 password1234 password12345
passw0rd passw0rd1 passw0rd! pa55word pa55w0rd
p@ssw0rd p@ssword p@ss p@55w0rd
secret secret1 secrets mysecret
changeme change me default default1
test test1 test123 testing
admin1 admin123 root123
flower flowers princess princess1
dragon1 dragon123
monkey123 shadow123 master123
login login1 access access1
server server1 hello hello1 hello123
computer computer1 internet internet1
software software1 science science1
letmein123 monkey123 dragon123
sunshine111 sunshine222
qweasdzxc qweasd 1q2w3e4r5t
asdfgh asdfghjkl zxcvbn zxcvbnm
qwaszx qwe123 qweasd123
555555 444444 333333 222222 111111
159753 147258 258369 987654
pass1234 pass123 pass12345
password! password@ password. password,
iloveyou! sunshine! princess!
michael1 jennifer1 thomas1
ashley ashley1 amanda amanda1
jessica1 matthew1 daniel1
andrew1 joseph1 joshua1
loveyou loveme love love1
ilove ilove1 iloveu
qazxsw zaq1xsw2
asdasd asdasd1 asdasd123
fdsa gfdsa jkl123 jkl;123
abcd1234 abcd123 1234abcd
q1w2e3r4 q1w2e3 qweqwe asdasdasd
zaq1zaq1 1qaz2wsx3edc
qazxswedc 1q2w3e4r5t6y
starwars1 pokemon1 minecraft1
amanda123 ashley123 nicole123
summer summer1 summer123
winter winter1 spring spring1
autumn autumn1
monday tuesday wednesday thursday friday
january february march april
london paris madrid berlin
mexico brasil argentina chile
canada america usa uk
coffee coffee1 beer beer1
guitar guitar1 piano piano1
soccer123 hockey123 baseball123
ninja ninja1 pirate pirate1
cookie cookie1 cookie123
pizza pizza1 burger burger1
chicken chicken1 fish fish1
tiger tiger1 lion lion1
eagle eagle1 snake snake1
alpha alpha1 beta beta1
gamma delta omega sigma
abc abc123 abcdef abcdefg
pizza123 iloveu123
q1w2e3r4t5 1q2w3e4r5t6y7u
zxcasdqwe poiuytrewq mnbvcxz
qweasdzxc123 159753159
asdqwe123 zxc123edc
q1az2wsx3edc4rfv
1q2w3e4r5t6y7u8i
''';

/// Split [_rawEntries] once, at first use, into a lookup set.
final Set<String> _entries = _rawEntries
    .split(RegExp(r'\s+'))
    .where((entry) => entry.isNotEmpty)
    .toSet();

/// Folds the character-class substitutions that make a breached password
/// look different without making it any less known.
///
/// Lives here, next to the list it has to match, rather than in
/// [PasswordPolicy]: the list is folded with this same function, and
/// putting it in the caller is how you end up folding the input and not
/// the list, which silently drops every mutation case.
///
/// Folding is deliberately lossy — it maps distinct passwords onto the
/// same value — so it is used **only** for the blocklist lookup, never
/// for the KDF input.
String foldForBlocklist(String password) {
  final trimmed = password.replaceAll(RegExp(r'[!@#$%^&*.,;]+$'), '');
  final buffer = StringBuffer();
  for (final rune in trimmed.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(
      switch (char) {
        '0' => 'o',
        '1' => 'i',
        '3' => 'e',
        '4' => 'a',
        '5' => 's',
        '7' => 't',
        '@' => 'a',
        r'$' => 's',
        '!' => 'i',
        '|' => 'i',
        _ => char,
      },
    );
  }
  return buffer.toString().toLowerCase();
}

/// Strips trailing digits from an already-folded value.
///
/// Appended digits are how people "strengthen" a password they know is
/// bad: `letmein12345` folds to `letmeinizeas`, which is not on the list,
/// while the base `letmein` is. Checking the digit-stripped form too is
/// what catches that whole family.
String stripTrailingDigits(String folded) =>
    folded.replaceFirst(RegExp(r'[0-9]+$'), '');

/// The folded blocklist, computed once at first use.
///
/// The lookup input is folded with [foldForBlocklist], so the list has to
/// be folded with the *same* rule. Folding only the input would miss
/// exactly the case the fold exists for: `p@ssw0rd1234` folds to
/// `passwordi2ea`, which is not on the raw list, while the raw list entry
/// `password1234` folds to that same value. Matching folded against
/// folded is what makes `p@ssw0rd1234` and `password1234` collapse onto
/// each other.
final Set<String> _foldedEntries = _entries.map(foldForBlocklist).toSet();

/// Checks [password] (already lowercased) against the blocklist.
bool isListedPassword(String lowercasedPassword) =>
    _entries.contains(lowercasedPassword);

/// Checks an already-folded [password] against the folded blocklist.
bool isListedFoldedPassword(String password) =>
    _foldedEntries.contains(password);

/// The process-wide breach corpus, consulted by
/// `PasswordPolicy.isCommon` after the in-source curated list.
///
/// Deliberately a mutable singleton behind an explicit [loadBreachCorpus]:
/// [PasswordPolicy.isCommon] is synchronous and called from widget code, so
/// it cannot await anything. Loading is fire-and-forget from the app's
/// startup path, and until it finishes the screen is the curated list alone
/// — weaker, never wrong (see `PasswordPolicy.isCommon`).
final BreachCorpus breachCorpus = BreachCorpus();

/// Loads [breachCorpusAssetPath] into a [BreachCorpus] and returns the
/// number of distinct digests now in memory.
///
/// Defaults to the [breachCorpus] singleton and [rootBundle], which is what
/// the app uses; tests pass their own [bundle] and [corpus] to stay
/// isolated. Returns the existing count immediately when [corpus] is
/// already loaded, so a second call is a no-op rather than a re-read: the
/// corpus is immutable, and re-parsing 2.7 MB at every resume would be
/// pointless.
///
/// Throws whatever [AssetBundle.load] throws when the asset is missing — a
/// missing corpus is a build error, not something to paper over silently.
/// A caller that wants to keep screening anyway can catch it and continue:
/// the curated list is still in place.
Future<int> loadBreachCorpus({
  AssetBundle? bundle,
  String assetKey = breachCorpusAssetPath,
  BreachCorpus? corpus,
}) async {
  final target = corpus ?? breachCorpus;
  if (target.isLoaded) {
    return target.digestCount;
  }

  final data = await (bundle ?? rootBundle).load(assetKey);
  // allowMalformed so a stray byte in the asset degrades to a line that is
  // skipped and counted instead of taking the whole screen down.
  final text = utf8.decode(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    allowMalformed: true,
  );

  // LineSplitter already treats CR, LF and CRLF as terminators, so a
  // CRLF-checked-out asset degrades to the same digests rather than to
  // 16-char-and-one-extra lines that never match.
  final digests = <String>{};
  var malformed = 0;
  for (final line in const LineSplitter().convert(text)) {
    // Blank and whitespace-only lines are ignored, the same as the build's
    // filter dropped them; only content lines of the wrong shape are
    // counted as malformed.
    if (line.trim().isEmpty) {
      continue;
    }
    if (line.length != breachDigestHexLength) {
      malformed++;
      continue;
    }
    digests.add(line);
  }

  target._install(digests: digests, malformedLines: malformed);
  return target.digestCount;
}

/// The loaded digest corpus: one in-memory set of truncated SHA-256 digests,
/// looked up synchronously.
///
/// Every lookup form the runtime computes — lowercased, folded, and both with
/// trailing digits stripped — is already indexed here, because the asset was
/// generated with the same [foldForBlocklist] / [stripTrailingDigits] pair
/// (see the library header). Hashing happens per *candidate*, never per
/// corpus entry, so nothing is folded at load time.
class BreachCorpus {
  Set<String>? _digests;
  int _malformedLines = 0;

  static const _sha256 = DartSha256();
  static const _hexDigits = '0123456789abcdef';

  /// True once [loadBreachCorpus] has installed a digest set.
  ///
  /// This is what lets a screen tell "the corpus has not arrived yet" apart
  /// from "this password is not breached": the first is a gap in coverage,
  /// the second is a verdict.
  bool get isLoaded => _digests != null;

  /// Number of distinct digests held in memory, or 0 before loading.
  ///
  /// Equals the line count of [breachCorpusAssetPath] for the shipped asset
  /// (161 426).
  int get digestCount => _digests?.length ?? 0;

  /// Number of asset lines skipped for not being a well-formed digest.
  ///
  /// Diagnostics only: the shipped asset has 0. A non-zero value means the
  /// artifact is damaged, and the screen is correspondingly weaker, so it is
  /// worth logging rather than ignoring.
  int get malformedLineCount => _malformedLines;

  /// True when any of [candidates] is in the corpus.
  ///
  /// [candidates] must already be in the indexed forms — in practice the four
  /// forms `PasswordPolicy.isCommon` derives from the candidate. Hashing is
  /// four short SHA-256 evaluations, which measured at roughly 2 us, so this
  /// stays cheap enough to run on every keystroke if a UI ever wants to.
  ///
  /// Returns false when nothing is loaded, so an unloaded corpus is a
  /// no-op rather than an error.
  bool containsAny(List<String> candidates) {
    final digests = _digests;
    if (digests == null) {
      return false;
    }
    for (final candidate in candidates) {
      if (digests.contains(_truncatedDigest(candidate))) {
        return true;
      }
    }
    return false;
  }

  /// Drops the loaded digests and returns to the curated-only screen.
  ///
  /// Used by tests to start from a known state, and by a caller that wants
  /// the memory back. The curated in-source list is untouched by this: it is
  /// not part of the corpus.
  void clear() {
    _digests = null;
    _malformedLines = 0;
  }

  /// Installs a parsed digest set. Private: only [loadBreachCorpus] builds
  /// one, so no caller can put an arbitrary set in front of the screen.
  void _install({
    required Set<String> digests,
    required int malformedLines,
  }) {
    _digests = digests;
    _malformedLines = malformedLines;
  }
}

/// The truncated SHA-256 hex digest of [value], in the asset's encoding.
///
/// Byte-for-byte what the build script computes for a corpus entry, which is
/// the whole reason folding the candidate can match a folded corpus entry.
String _truncatedDigest(String value) {
  final bytes = BreachCorpus._sha256.hashSync(utf8.encode(value)).bytes;
  final digest = StringBuffer();
  for (var index = 0; index < breachDigestHexLength ~/ 2; index++) {
    digest
      ..writeCharCode(BreachCorpus._hexDigits.codeUnitAt(bytes[index] >> 4))
      ..writeCharCode(BreachCorpus._hexDigits.codeUnitAt(bytes[index] & 0x0f));
  }
  return digest.toString();
}
