import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_backup_service.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

import '../../features/backup/backup_test_support.dart';

void main() {
  final createdAt = DateTime.utc(2026, 10, 19, 9, 30);
  late VaultBackupService service;
  late List<VaultItem> items;

  setUp(() {
    service = VaultBackupService.test(clock: () => createdAt);
    items = [
      testItem(
        id: 'a',
        title: 'GitHub',
        secret: 'gh-Secret!123',
        website: 'github.com',
        notes: 'recovery codes in drawer',
        category: VaultCategory.work,
      ),
      testItem(id: 'b', title: 'Bank', secret: 'B4nk!Secret'),
    ];
  });

  Future<Uint8List> exportSample() => service.export(
    items: items,
    backupPassword: testBackupPassword,
    appVersion: '1.0.21+22',
  );

  Map<String, dynamic> decode(Uint8List bytes) =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

  Map<String, dynamic> kdfOf(Map<String, dynamic> envelope) =>
      envelope['kdf'] as Map<String, dynamic>;

  Map<String, dynamic> cipherOf(Map<String, dynamic> envelope) =>
      envelope['cipher'] as Map<String, dynamic>;

  Uint8List encode(Map<String, dynamic> envelope) =>
      Uint8List.fromList(utf8.encode(jsonEncode(envelope)));

  Future<VaultBackupFailure?> failureOf(Uint8List bytes) async {
    try {
      await service.decrypt(bytes: bytes, backupPassword: testBackupPassword);
      return null;
    } on VaultBackupException catch (error) {
      return error.failure;
    }
  }

  group('VaultBackupService round trip', () {
    test('export then decrypt restores every item and field', () async {
      final bytes = await exportSample();
      final contents = await service.decrypt(
        bytes: bytes,
        backupPassword: testBackupPassword,
      );

      expect(contents.items.length, 2);
      for (var i = 0; i < items.length; i++) {
        expect(contents.items[i].toJson(), items[i].toJson());
      }
      expect(contents.exportedAt, createdAt);
      expect(contents.header.createdAt, createdAt);
      expect(contents.header.appVersion, '1.0.21+22');
    });

    test('envelope has the documented shape and no plaintext', () async {
      final bytes = await exportSample();
      final envelope = decode(bytes);

      expect(envelope.keys.toSet(), {
        'format',
        'v',
        'created_at',
        'app_version',
        'kdf',
        'cipher',
        'ciphertext_b64',
        'tag_b64',
      });
      expect(envelope['format'], 'vaulta-backup');
      expect(envelope['v'], 1);
      final kdf = envelope['kdf'] as Map<String, dynamic>;
      expect(kdf['name'], 'argon2id');
      expect(kdf['memory_kib'], greaterThanOrEqualTo(65536));
      expect(kdf['iterations'], greaterThanOrEqualTo(3));
      expect(kdf['parallelism'], 1);
      expect(kdf['dk_len'], 32);
      expect(base64Decode(kdf['salt_b64'] as String).length, 16);
      final cipher = envelope['cipher'] as Map<String, dynamic>;
      expect(cipher['alg'], 'AES-256-GCM');
      expect(base64Decode(cipher['nonce_b64'] as String).length, 12);
      expect(base64Decode(envelope['tag_b64'] as String).length, 16);

      final text = utf8.decode(bytes);
      for (final needle in ['gh-Secret!123', 'GitHub', 'recovery codes']) {
        expect(text.contains(needle), isFalse, reason: needle);
      }
    });

    test('every export uses a fresh salt and nonce', () async {
      final first = decode(await exportSample());
      final second = decode(await exportSample());
      expect(kdfOf(first)['salt_b64'], isNot(kdfOf(second)['salt_b64']));
      expect(
        cipherOf(first)['nonce_b64'],
        isNot(cipherOf(second)['nonce_b64']),
      );
    });

    test('readHeader exposes metadata without the password', () async {
      final header = service.readHeader(await exportSample());
      expect(header.version, 1);
      expect(header.createdAt, createdAt);
      expect(header.memoryKiB, 65536);
      expect(header.iterations, 3);
    });

    test('an empty vault round-trips', () async {
      final bytes = await service.export(
        items: const [],
        backupPassword: testBackupPassword,
        appVersion: '1',
      );
      final contents = await service.decrypt(
        bytes: bytes,
        backupPassword: testBackupPassword,
      );
      expect(contents.items, isEmpty);
    });
  });

  group('VaultBackupService rejects', () {
    test('a wrong backup password', () async {
      final bytes = await exportSample();
      await expectLater(
        service.decrypt(bytes: bytes, backupPassword: 'Wrong#Pass2026'),
        throwsA(
          isA<VaultBackupException>().having(
            (e) => e.failure,
            'failure',
            VaultBackupFailure.decryptionFailed,
          ),
        ),
      );
    });

    // Fields that still pass structural validation when modified: the
    // only thing that can catch these is the AES-GCM AAD (or, for the
    // salt and KDF cost, the derived key).
    final aadTampers = <String, void Function(Map<String, dynamic>)>{
      'created_at': (e) => e['created_at'] = '2020-01-01T00:00:00.000Z',
      'app_version': (e) => e['app_version'] = '9.9.9+99',
      'kdf.salt_b64': (e) =>
          kdfOf(e)['salt_b64'] = base64Encode(List.filled(16, 7)),
      'kdf.memory_kib': (e) => kdfOf(e)['memory_kib'] = 131072,
      'kdf.memory_kib (lowered, still above floor)': (e) =>
          kdfOf(e)['memory_kib'] = 19456,
      'kdf.iterations': (e) => kdfOf(e)['iterations'] = 4,
      'kdf.iterations (lowered, still above floor)': (e) =>
          kdfOf(e)['iterations'] = 2,
      'kdf.parallelism': (e) => kdfOf(e)['parallelism'] = 2,
      'cipher.nonce_b64': (e) =>
          cipherOf(e)['nonce_b64'] = base64Encode(List.filled(12, 1)),
    };
    for (final entry in aadTampers.entries) {
      test('tampered header field ${entry.key}', () async {
        final envelope = decode(await exportSample());
        entry.value(envelope);
        expect(
          await failureOf(encode(envelope)),
          VaultBackupFailure.decryptionFailed,
        );
      });
    }

    test('header tamper is caught by AAD alone (same key)', () async {
      // created_at does not feed the KDF, so the key is identical; the
      // failure proves the header is authenticated.
      final envelope = decode(await exportSample());
      envelope['created_at'] = createdAt
          .add(const Duration(seconds: 1))
          .toIso8601String();
      expect(
        await failureOf(encode(envelope)),
        VaultBackupFailure.decryptionFailed,
      );
    });

    final structuralTampers =
        <String, (void Function(Map<String, dynamic>), VaultBackupFailure)>{
          'format': (
            (e) => e['format'] = 'other-backup',
            VaultBackupFailure.malformed,
          ),
          'kdf.name': (
            (e) => kdfOf(e)['name'] = 'pbkdf2',
            VaultBackupFailure.malformed,
          ),
          'kdf.dk_len': (
            (e) => kdfOf(e)['dk_len'] = 16,
            VaultBackupFailure.malformed,
          ),
          'cipher.alg': (
            (e) => cipherOf(e)['alg'] = 'AES-128-GCM',
            VaultBackupFailure.malformed,
          ),
          'extra header field': (
            (e) => e['note'] = 'hello',
            VaultBackupFailure.malformed,
          ),
          'extra kdf field': (
            (e) => kdfOf(e)['pepper'] = 'x',
            VaultBackupFailure.malformed,
          ),
          'missing app_version': (
            (e) => e.remove('app_version'),
            VaultBackupFailure.malformed,
          ),
          'short nonce': (
            (e) => cipherOf(e)['nonce_b64'] = base64Encode(List.filled(8, 1)),
            VaultBackupFailure.malformed,
          ),
          'memory above the import ceiling': (
            (e) => kdfOf(e)['memory_kib'] = 4 * 1048576,
            VaultBackupFailure.malformed,
          ),
          'iterations above the import ceiling': (
            (e) => kdfOf(e)['iterations'] = 1000,
            VaultBackupFailure.malformed,
          ),
        };
    for (final entry in structuralTampers.entries) {
      test('tampered ${entry.key}', () async {
        final envelope = decode(await exportSample());
        entry.value.$1(envelope);
        expect(await failureOf(encode(envelope)), entry.value.$2);
      });
    }

    test('a flipped ciphertext byte', () async {
      final envelope = decode(await exportSample());
      final ciphertext = base64Decode(envelope['ciphertext_b64'] as String);
      ciphertext[0] ^= 0x01;
      envelope['ciphertext_b64'] = base64Encode(ciphertext);
      expect(
        await failureOf(encode(envelope)),
        VaultBackupFailure.decryptionFailed,
      );
    });

    test('a truncated ciphertext', () async {
      final envelope = decode(await exportSample());
      final ciphertext = base64Decode(envelope['ciphertext_b64'] as String);
      envelope['ciphertext_b64'] = base64Encode(
        ciphertext.sublist(0, ciphertext.length - 1),
      );
      expect(
        await failureOf(encode(envelope)),
        VaultBackupFailure.decryptionFailed,
      );
    });

    test('a flipped tag byte', () async {
      final envelope = decode(await exportSample());
      final tag = base64Decode(envelope['tag_b64'] as String);
      tag[15] ^= 0x80;
      envelope['tag_b64'] = base64Encode(tag);
      expect(
        await failureOf(encode(envelope)),
        VaultBackupFailure.decryptionFailed,
      );
    });

    test('KDF memory below the import floor (downgrade)', () async {
      final envelope = decode(await exportSample());
      kdfOf(envelope)['memory_kib'] = 19455;
      expect(await failureOf(encode(envelope)), VaultBackupFailure.insecureKdf);
      expect(
        () => service.readHeader(encode(envelope)),
        throwsA(isA<VaultBackupException>()),
      );
    });

    test('KDF iterations below the import floor (downgrade)', () async {
      final envelope = decode(await exportSample());
      kdfOf(envelope)['iterations'] = 1;
      expect(await failureOf(encode(envelope)), VaultBackupFailure.insecureKdf);
    });

    test('an unknown format version', () async {
      final envelope = decode(await exportSample());
      envelope['v'] = 2;
      expect(
        await failureOf(encode(envelope)),
        VaultBackupFailure.unsupportedVersion,
      );
    });

    test('a non-integer version', () async {
      final envelope = decode(await exportSample());
      envelope['v'] = '1';
      expect(await failureOf(encode(envelope)), VaultBackupFailure.malformed);
    });

    test('non-JSON, empty and oversized input', () async {
      expect(
        await failureOf(Uint8List.fromList(utf8.encode('name,password'))),
        VaultBackupFailure.malformed,
      );
      expect(await failureOf(Uint8List(0)), VaultBackupFailure.malformed);
      expect(
        await failureOf(Uint8List(VaultBackupService.maxEnvelopeBytes + 1)),
        VaultBackupFailure.malformed,
      );
    });
  });

  group('VaultBackupService with production Argon2id', () {
    test('round-trips and rejects a wrong password', () async {
      final production = VaultBackupService(clock: () => createdAt);
      final bytes = await production.export(
        items: items,
        backupPassword: testBackupPassword,
        appVersion: '1.0.21+22',
      );
      final contents = await production.decrypt(
        bytes: bytes,
        backupPassword: testBackupPassword,
      );
      expect(contents.items.map((item) => item.toJson()).toList(), [
        for (final item in items) item.toJson(),
      ]);

      await expectLater(
        production.decrypt(bytes: bytes, backupPassword: 'Wrong#Pass2026'),
        throwsA(
          isA<VaultBackupException>().having(
            (e) => e.failure,
            'failure',
            VaultBackupFailure.decryptionFailed,
          ),
        ),
      );
      // A backup made by the fast test KDF cannot be opened by the
      // production derivation and vice versa.
      await expectLater(
        service.decrypt(bytes: bytes, backupPassword: testBackupPassword),
        throwsA(isA<VaultBackupException>()),
      );
    });
  });

  group('VaultBackupService export parameters', () {
    test('refuses KDF parameters weaker than the vault', () {
      expect(() => VaultBackupService(memoryKiB: 32768), throwsArgumentError);
      expect(() => VaultBackupService(iterations: 2), throwsArgumentError);
      expect(() => VaultBackupService(parallelism: 0), throwsArgumentError);
      expect(VaultBackupService.new, returnsNormally);
    });

    test('canonical header encoding sorts keys at every level', () {
      final a = VaultBackupService.canonicalHeaderBytes({
        'b': 1,
        'a': {'y': 'x', 'x': 2},
      });
      final b = VaultBackupService.canonicalHeaderBytes({
        'a': {'x': 2, 'y': 'x'},
        'b': 1,
      });
      expect(a, b);
      expect(utf8.decode(a), '{"a":{"x":2,"y":"x"},"b":1}');
    });
  });
}
