import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/common_password_blocklist.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/password_policy.dart';

/// Every line of the shipped corpus asset.
final RegExp _digestLine = RegExp('^[0-9a-f]{$breachDigestHexLength}\$');

/// Witnesses, chosen from the NCSC corpus so each one exercises a different
/// lookup form. They are not in the in-source curated list, so anything the
/// tests below observe as rejected came from the corpus.
///
/// * `pletnevakaterina` — a corpus entry as typed (raw form).
/// * `Somanypickles27` — the same entry typed with its original case.
/// * `somanypickles` — *not* an entry: only the digit-stripped form of
///   `Somanypickles27` reaches it.
/// * `iq` — *not* an entry: only the folded form of `!q` reaches it.
/// * `un-corrector-de-caballo` — absent from the corpus in all four forms.
const String _rawCorpusEntry = 'pletnevakaterina';
const String _rawCorpusEntryAsTyped = 'Somanypickles27';
const String _digitStrippedWitness = 'somanypickles';
const String _foldedWitness = 'iq';
const String _absentPassphrase = 'un-corrector-de-caballo';
const String _curatedOnlyWitness = 'p@ssw0rd1234';

/// Pins the shipped breach corpus: the asset's own shape, the synchronous
/// screening API that consumes it, and the degraded-but-never-wrong state the
/// app is in until [loadBreachCorpus] finishes.
///
/// The API under test is synchronous by design (`PasswordPolicy.evaluate`,
/// `MasterPasswordService.validate`, `PasswordPolicy.isCommon`), so these
/// tests deliberately avoid `await` on anything except the loader itself. If
/// a future change makes screening async, these tests stop compiling.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Every test starts from "the corpus has not been loaded yet", which is the
  // state the app is in for the first few frames after launch.
  setUp(breachCorpus.clear);

  Future<List<String>> assetLines() async {
    final data = await rootBundle.load(breachCorpusAssetPath);
    final text = utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      allowMalformed: true,
    );
    expect(
      text.contains('\r'),
      isFalse,
      reason: 'the asset is generated LF-only; a CR would make every digest '
          'after the first line fail to match',
    );
    return text.split('\n').where((line) => line.isNotEmpty).toList();
  }

  group('breach corpus asset', () {
    test('every line is a truncated lowercase SHA-256 digest', () async {
      final lines = await assetLines();

      expect(lines, isNotEmpty, reason: 'an empty asset screens nothing');
      final notADigest =
          lines.where((line) => !_digestLine.hasMatch(line)).toList();
      expect(
        notADigest,
        isEmpty,
        reason: 'the asset must contain digests only, never plaintext: '
            '${notADigest.take(5)}',
      );
    });

    test('ships the full corpus, so a truncated download fails the build',
        () async {
      final lines = await assetLines();

      // Floor first: this is the assertion that catches a half-downloaded or
      // wrongly-filtered regeneration. The exact count then pins the artifact
      // this review approved; refreshing the corpus is a deliberate change.
      expect(
        lines.length,
        greaterThanOrEqualTo(50000),
        reason: 'a shorter asset is a silently weaker screen',
      );
      expect(lines.length, 161426);
    });

    test('the loader accepts every line of the asset', () async {
      final lines = await assetLines();

      final digestCount = await loadBreachCorpus();

      expect(digestCount, lines.length);
      expect(breachCorpus.digestCount, lines.length);
      expect(breachCorpus.malformedLineCount, 0);
    });

    test('skips and counts lines that are not digest-shaped', () async {
      const good = '0123456789abcdef';
      final bundle = _StringAssetBundle(
        '$good\r\n'
        '\n'
        '   \n'
        'not-a-digest\n'
        'tooshort\n'
        'ffffffffffffffff\n',
      );

      final digestCount = await loadBreachCorpus(bundle: bundle);

      // Only the two well-shaped digests land in memory; a garbage line is
      // counted instead of silently becoming an entry that never matches.
      expect(digestCount, 2);
      expect(breachCorpus.malformedLineCount, 2);
      expect(breachCorpus.isLoaded, isTrue);
    });
  });

  group('screening with the corpus loaded', () {
    test('rejects a password that is in the loaded corpus', () async {
      await loadBreachCorpus();

      expect(PasswordPolicy.isCommon(_rawCorpusEntry), isTrue);
      expect(
        PasswordPolicy.isCommon(_rawCorpusEntryAsTyped),
        isTrue,
        reason: 'the lookup is case-insensitive: the corpus is indexed by the '
            'lowercased form of every entry',
      );
      expect(
        const PasswordPolicy().evaluate(_rawCorpusEntry),
        PasswordPolicyVerdict.breached,
      );
    });

    test('rejects a candidate that is only the digit-stripped corpus form',
        () async {
      await loadBreachCorpus();

      expect(PasswordPolicy.isCommon(_digitStrippedWitness), isTrue);
      expect(
        const PasswordPolicy().evaluate(_digitStrippedWitness),
        PasswordPolicyVerdict.breached,
        reason: 'the corpus is indexed with trailing digits stripped too, with '
            'the same stripTrailingDigits the candidate uses',
      );
    });

    test('rejects a candidate that is only the folded corpus form', () async {
      await loadBreachCorpus();

      expect(PasswordPolicy.isCommon(_foldedWitness), isTrue);
      expect(
        const PasswordPolicy().evaluate(_foldedWitness),
        PasswordPolicyVerdict.tooShort,
        reason: 'screening still fired; the length bound is evaluated first',
      );
    });

    test('accepts a password that is absent from the corpus and not weak',
        () async {
      await loadBreachCorpus();

      expect(PasswordPolicy.isCommon(_absentPassphrase), isFalse);
      expect(
        const PasswordPolicy().evaluate(_absentPassphrase),
        PasswordPolicyVerdict.acceptable,
      );
    });

    test('still rejects the curated mutations the corpus knows nothing about',
        () async {
      await loadBreachCorpus();

      expect(PasswordPolicy.isCommon(_curatedOnlyWitness), isTrue);
      expect(PasswordPolicy.isCommon('P@ssw0rd!'), isTrue);
      expect(PasswordPolicy.isCommon('pa55word123'), isTrue);
    });

    test('MasterPasswordService.validate sees the corpus without going async',
        () async {
      final service = MasterPasswordService.test();
      expect(
        service.validate(_rawCorpusEntry),
        isNull,
        reason: 'before loading, the screen is the curated list only',
      );

      await loadBreachCorpus();

      expect(
        service.validate(_rawCorpusEntry),
        PasswordPolicy.explain(
          PasswordPolicyVerdict.breached,
          PasswordPolicy.defaultMinimumLength,
        ),
        reason: 'validate() delegates to PasswordPolicy.evaluate, which now '
            'consults the corpus; the return type is still String?, not Future',
      );
      expect(service.validate(_absentPassphrase), isNull);
    });
  });

  group('screening before the corpus is loaded', () {
    test('reports the corpus as not loaded', () {
      expect(breachCorpus.isLoaded, isFalse);
      expect(PasswordPolicy.isBreachCorpusLoaded, isFalse);
      expect(PasswordPolicy.breachDigestCount, 0);
    });

    test('falls back to the in-source list and throws nothing', () {
      expect(PasswordPolicy.isCommon(_curatedOnlyWitness), isTrue);
      expect(PasswordPolicy.isCommon('password12345'), isTrue);
      expect(PasswordPolicy.isCommon('letmein12345'), isTrue);
      expect(
        const PasswordPolicy().evaluate(_curatedOnlyWitness),
        PasswordPolicyVerdict.breached,
      );
    });

    test('degrades to a miss, never to a wrong rejection', () {
      // The dangerous direction would be rejecting a good password because the
      // corpus is missing. Unloaded, this corpus password is simply accepted;
      // loaded, it is rejected.
      expect(PasswordPolicy.isCommon(_rawCorpusEntry), isFalse);
      expect(
        const PasswordPolicy().evaluate(_rawCorpusEntry),
        PasswordPolicyVerdict.acceptable,
      );
    });

    test('an empty or oversized candidate throws nothing', () {
      expect(PasswordPolicy.isCommon(''), isFalse);
      expect(
        PasswordPolicy.isCommon('a' * (PasswordPolicy.defaultMaximumLength + 1)),
        isFalse,
      );
      expect(
        const PasswordPolicy().evaluate(''),
        PasswordPolicyVerdict.tooShort,
      );
    });
  });

  group('loading', () {
    test('loading the corpus twice is idempotent', () async {
      final first = await loadBreachCorpus();
      expect(first, greaterThanOrEqualTo(50000));
      expect(breachCorpus.isLoaded, isTrue);

      // A second load must not re-read: a key that does not exist would throw
      // if the cache were bypassed.
      final second = await loadBreachCorpus(
        assetKey: 'assets/security/there-is-no-such-corpus.txt',
      );

      expect(second, first);
      expect(breachCorpus.digestCount, first);
      expect(breachCorpus.malformedLineCount, 0);
      expect(PasswordPolicy.isCommon(_rawCorpusEntry), isTrue);
    });

    test('is observable once loaded', () async {
      final digestCount = await loadBreachCorpus();

      expect(PasswordPolicy.isBreachCorpusLoaded, isTrue);
      expect(PasswordPolicy.breachDigestCount, digestCount);
      expect(breachCorpus.isLoaded, isTrue);
    });

    test('clear drops the corpus and returns to the fallback', () async {
      await loadBreachCorpus();
      expect(PasswordPolicy.isCommon(_rawCorpusEntry), isTrue);

      breachCorpus.clear();

      expect(breachCorpus.isLoaded, isFalse);
      expect(breachCorpus.digestCount, 0);
      expect(PasswordPolicy.isCommon(_rawCorpusEntry), isFalse);
      expect(
        PasswordPolicy.isCommon(_curatedOnlyWitness),
        isTrue,
        reason: 'the in-source list is not part of the loaded corpus',
      );
    });
  });
}

/// Minimal [AssetBundle] over an in-memory string, for the loader's malformed
/// input handling. [AssetBundle] has a single abstract member.
class _StringAssetBundle extends AssetBundle {
  _StringAssetBundle(this.contents);

  final String contents;

  @override
  Future<ByteData> load(String key) async {
    final bytes = utf8.encode(contents);
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}