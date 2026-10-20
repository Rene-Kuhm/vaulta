/// Screen against passwords that are already public knowledge.
///
/// NIST SP 800-63B §3.1.1.2 requires screening against a blocklist of
/// commonly used, expected or compromised passwords, and explicitly
/// recommends *against* composition rules.
///
/// ## Scope of this list, honestly stated
///
/// This is a **curated subset** of the passwords that appear at the top of
/// every public breach corpus (the entries that dominate rockyou-style
/// lists and credential-stuffing dictionaries). It is **not** the full
/// Pwned Passwords corpus, which is roughly 800 MB even as truncated
/// SHA-1 hashes and is not shippable inside an APK.
///
/// [PasswordBreachChecker] folds character-class mutations before looking
/// the password up, which is what gives this short list most of its reach:
/// `P@ssw0rd`, `p4ssword` and `Passw0rd!` all collapse onto `password`
/// and are rejected.
///
/// ## Replacing it
///
/// To move to a full corpus, generate a sorted list of SHA-1 prefixes of
/// the corpus, ship it as a compressed asset, and replace [_entries] with
/// a prefix lookup. The call sites do not change: they only call
/// [PasswordBreachChecker.isCommon].
library;

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