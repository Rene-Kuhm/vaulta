import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/master_password_record.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/password_policy.dart';

/// Pins the v3 master-password contract: one Argon2id run split with
/// HKDF-SHA256, NFC-normalized input, and a NIST-aligned policy.
///
/// The fast test KDF is enabled, so these assert the *structure* of the
/// derivation (single salt, HKDF split, labels) rather than Argon2id's
/// memory-hardness. That is the part this change owns; the Argon2id
/// parameters themselves are asserted separately in the ADR.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const password = 'un-corrector-de-caballo';
  final service = MasterPasswordService.test();

  // A real-Argon2id service with tiny parameters. The fast test KDF is a
  // stub, so any test that recomputes the derivation independently has to
  // use this one, or the recomputation will not match.
  final realKdfService = MasterPasswordService(
    encryptionIterations: 1,
    argon2MemoryKiB: 1024,
    argon2Parallelism: 1,
  );

  /// Recomputes the expected verifier from a v3 record's own inputs.
  ///
  /// If the implementation ever runs Argon2id twice again, or derives the
  /// verifier straight from the KDF output without the HKDF split, this
  /// stops matching and the test fails.
  Future<List<int>> expectedVerifierFromRecord(
    MasterPasswordRecord record, {
    required String rawPassword,
  }) async {
    final kdf = record.kdf!;
    final argon2 = Argon2id(
      memory: kdf['memory_kib'] as int,
      parallelism: kdf['parallelism'] as int,
      iterations: kdf['iterations'] as int,
      hashLength: kdf['dk_len'] as int,
    );
    final masterKey = await argon2.deriveKeyFromPassword(
      password: PasswordPolicy.normalize(rawPassword),
      nonce: base64Decode(kdf['salt_b64'] as String),
    );
    final verifierHalf = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(
      secretKey: masterKey,
      info: utf8.encode('vaulta:v3:verifier'),
    );
    return verifierHalf.extractBytes();
  }

  group('record v3 shape', () {
    test('writes version 3 and marks the password NFC-normalized', () async {
      final record = await service.createRecord(password);

      expect(record.version, MasterPasswordRecord.currentVersion);
      expect(record.version, 3);
      expect(record.pwNorm, MasterPasswordRecord.nfcMarker);
      expect(record.isCurrentFormat, isTrue);
    });

    test('uses a single salt for both the verifier and the KEK', () async {
      final record = await service.createRecord(password);

      // The structural proof that Argon2id runs once: v2 kept two
      // independent 16-byte salts and derived twice. v3 shares one.
      expect(record.verifierSalt, record.encryptionSalt);
      expect(record.verifierSalt, record.kdf!['salt_b64']);

      final salt = base64Decode(record.kdf!['salt_b64'] as String);
      expect(salt, hasLength(16));
    });

    test('derives the verifier as an HKDF split of a 64-byte KDF output',
        () async {
      final record = await realKdfService.createRecord(password);

      expect(record.kdf!['dk_len'], 64);
      expect(record.kdf!['split'], 'hkdf-sha256-v3');

      final expected = await expectedVerifierFromRecord(
        record,
        rawPassword: password,
      );
      expect(record.verifier, base64Encode(expected));
    });

    test('the verifier half and the KEK half are not the same bytes',
        () async {
      final record = await realKdfService.createRecord(password);
      final kdf = record.kdf!;

      final argon2 = Argon2id(
        memory: kdf['memory_kib'] as int,
        parallelism: kdf['parallelism'] as int,
        iterations: kdf['iterations'] as int,
        hashLength: 64,
      );
      final masterKey = await argon2.deriveKeyFromPassword(
        password: password,
        nonce: base64Decode(kdf['salt_b64'] as String),
      );
      final kekHalf = await Hkdf(
        hmac: Hmac.sha256(),
        outputLength: 32,
      ).deriveKey(
        secretKey: masterKey,
        info: utf8.encode('vaulta:v3:kek'),
      );

      expect(base64Decode(record.verifier), isNot(await kekHalf.extractBytes()));
    });
  });

  group('verify and derive', () {
    test('accepts the correct password and rejects a wrong one', () async {
      final record = await service.createRecord(password);

      expect(await service.verify(record: record, password: password), isTrue);
      expect(
        await service.verify(record: record, password: 'not-the-password'),
        isFalse,
      );
    });

    test('deriveVaultKey unwraps the same DEK that createRecord wrapped',
        () async {
      final record = await service.createRecord(password);
      final key = await service.deriveVaultKey(
        record: record,
        password: password,
      );
      final bytes = await key.extractBytes();

      expect(bytes, hasLength(32));
      // Deterministic: same password and record must yield the same DEK.
      final again = await service.deriveVaultKey(
        record: record,
        password: password,
      );
      expect(await again.extractBytes(), bytes);
    });

    test('a record with no wrapped DEK fails with the typed error', () async {
      final record = await service.createRecord(password);
      final stripped = MasterPasswordRecord(
        version: record.version,
        verifierIterations: record.verifierIterations,
        verifierSalt: record.verifierSalt,
        verifier: record.verifier,
        encryptionIterations: record.encryptionIterations,
        encryptionSalt: record.encryptionSalt,
        keyId: record.keyId,
        createdAt: record.createdAt,
        kdf: record.kdf,
        pwNorm: record.pwNorm,
      );

      // The password still verifies: only the wrap is gone.
      expect(await service.verify(record: stripped, password: password),
          isTrue);
      await expectLater(
        service.deriveVaultKey(record: stripped, password: password),
        throwsA(
          isA<VaultKeyUnavailableException>().having(
            (error) => error.reason,
            'reason',
            'missing_dek_wrap',
          ),
        ),
      );
    });

    test('a corrupt wrapped DEK fails with the typed error', () async {
      final record = await service.createRecord(password);
      final damagedWrap = {
        ...record.dekWrap!,
        'tag_b64': base64Encode(List<int>.filled(16, 7)),
      };
      final damaged = MasterPasswordRecord(
        version: record.version,
        verifierIterations: record.verifierIterations,
        verifierSalt: record.verifierSalt,
        verifier: record.verifier,
        encryptionIterations: record.encryptionIterations,
        encryptionSalt: record.encryptionSalt,
        keyId: record.keyId,
        createdAt: record.createdAt,
        kdf: record.kdf,
        dekWrap: damagedWrap,
        pwNorm: record.pwNorm,
      );

      // The old code let SecretBoxAuthenticationError out of here, which
      // reached the widget layer as a raw crypto string.
      await expectLater(
        service.deriveVaultKey(record: damaged, password: password),
        throwsA(
          isA<VaultKeyUnavailableException>().having(
            (error) => error.reason,
            'reason',
            contains('SecretBoxAuthenticationError'),
          ),
        ),
      );
    });
  });

  group('NFC normalization', () {
    // "café" as e + combining acute, versus the precomposed form.
    const decomposed = 'cafe\u{0301}-secreto-de-prueba';
    const composed = 'caf\u{00E9}-secreto-de-prueba';

    test('a decomposed password verifies with its composed spelling', () async {
      final record = await service.createRecord(decomposed);

      expect(
        await service.verify(record: record, password: composed),
        isTrue,
        reason: 'the same logical password must derive the same key',
      );
    });

    test('both spellings derive the same vault key', () async {
      final record = await service.createRecord(decomposed);
      final a = await service.deriveVaultKey(
        record: record,
        password: decomposed,
      );
      final b = await service.deriveVaultKey(
        record: record,
        password: composed,
      );

      expect(await b.extractBytes(), await a.extractBytes());
    });

    test('a v2 record still verifies against the raw bytes', () async {
      // Regression guard for the upgrade path: v1/v2 records hashed the
      // raw input. If v2 verification ever normalized, every existing
      // vault with a non-ASCII password would stop unlocking.
      final salt = List<int>.generate(16, (i) => i + 1);
      final legacyVerifier = await Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ).deriveKeyFromPassword(password: decomposed, nonce: salt);

      final legacyRecord = MasterPasswordRecord(
        version: 2,
        verifierIterations: 1,
        verifierSalt: base64Encode(salt),
        verifier: base64Encode(await legacyVerifier.extractBytes()),
        encryptionIterations: 1,
        encryptionSalt: base64Encode(salt),
        keyId: 'legacy',
        createdAt: DateTime.utc(2026),
        kdf: {
          'name': 'argon2id',
          'salt_b64': base64Encode(salt),
          'memory_kib': 1024,
          'iterations': 1,
          'parallelism': 1,
          'dk_len': 32,
        },
        dekWrap: {
          'alg': 'AES-256-GCM',
          'nonce_b64': base64Encode(List<int>.filled(12, 1)),
          'ciphertext_b64': base64Encode(List<int>.filled(32, 2)),
          'tag_b64': base64Encode(List<int>.filled(16, 3)),
        },
      );

      expect(legacyRecord.isCurrentFormat, isFalse);
      expect(
        await realKdfService.verify(record: legacyRecord, password: decomposed),
        isTrue,
      );
      expect(
        await realKdfService.verify(record: legacyRecord, password: composed),
        isFalse,
        reason: 'a legacy record must keep hashing the exact bytes it stored',
      );
    });
  });

  group('v2 records still derive their DEK', () {
    // Regression guard for a lockout bug. `verify` branched correctly on
    // the record version, but `deriveVaultKey` branched on the *current*
    // version, so a v2 record fell through to the v1 PBKDF2 path and
    // produced the wrong key: verify passed and the vault would not open.
    // Every user on a v2 record was locked out.
    Future<MasterPasswordRecord> buildV2Record({
      required String password,
      required List<int> dek,
    }) async {
      final salt = List<int>.generate(16, (i) => i + 3);
      final kek = await Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ).deriveKeyFromPassword(password: password, nonce: salt);
      final box = await AesGcm.with256bits().encrypt(
        dek,
        secretKey: kek,
      );
      return MasterPasswordRecord(
        version: 2,
        verifierIterations: 1,
        verifierSalt: base64Encode(salt),
        verifier: base64Encode(List<int>.filled(32, 9)),
        encryptionIterations: 1,
        encryptionSalt: base64Encode(salt),
        keyId: 'legacy-v2',
        createdAt: DateTime.utc(2026),
        kdf: {
          'name': 'argon2id',
          'salt_b64': base64Encode(salt),
          'memory_kib': 1024,
          'iterations': 1,
          'parallelism': 1,
          'dk_len': 32,
        },
        dekWrap: {
          'alg': 'AES-256-GCM',
          'nonce_b64': base64Encode(box.nonce),
          'ciphertext_b64': base64Encode(box.cipherText),
          'tag_b64': base64Encode(box.mac.bytes),
        },
      );
    }

    test('unwraps the DEK a v2 record actually wrapped', () async {
      final dek = List<int>.generate(32, (i) => i * 3 + 1);
      final record = await buildV2Record(
        password: password,
        dek: dek,
      );

      final key = await realKdfService.deriveVaultKey(
        record: record,
        password: password,
      );

      expect(await key.extractBytes(), dek);
    });

    test('a v2 record is flagged as needing migration', () async {
      final record = await buildV2Record(password: password, dek: [1]);

      expect(record.isCurrentFormat, isFalse);
    });
  });

  group('password policy', () {
    test('no longer requires character-class diversity', () {
      // This is the NIST SP 800-63B §3.1.1.2 change: the old policy
      // rejected this exact password.
      expect(service.validate('todasminusculas123'), isNull);
      expect(service.validate('Sin-Numeros-Ni-Simbolos'), isNull);
      expect(
        service.validate('unicodearabe\u0627\u0644\u0645\u0631\u062d\u0628\u0627'),
        isNull,
        reason: 'composition rules reject non-Latin scripts for no benefit',
      );
    });

    test('still enforces the minimum length', () {
      expect(
        service.validate('corto1!A'),
        'Usa al menos ${MasterPasswordService.minimumLength} caracteres.',
      );
    });

    test('rejects a long input so Argon2id cannot be used as a DoS lever', () {
      final tooLong = 'a' * (PasswordPolicy.defaultMaximumLength + 1);
      expect(service.validate(tooLong), isNotNull);
    });

    test('rejects passwords on the leaked list', () {
      expect(service.validate('password12345'), isNotNull);
      expect(service.validate('letmein12345'), isNotNull);
    });

    test('rejects character-class mutations of a leaked password', () {
      // The fold is what gives a short curated list real reach.
      expect(PasswordPolicy.isCommon('p@ssw0rd1234'), isTrue);
      expect(PasswordPolicy.isCommon('P@ssw0rd!'), isTrue);
      expect(PasswordPolicy.isCommon('pa55word123'), isTrue);
      expect(
        service.validate('p@ssw0rd1234'),
        isNotNull,
        reason: 'the policy routes through the same fold',
      );
    });

    test('accepts an ordinary passphrase', () {
      expect(service.validate('un-corrector-de-caballo'), isNull);
    });
  });
}