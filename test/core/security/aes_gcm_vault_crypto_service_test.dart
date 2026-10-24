import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';

void main() {
  // Deterministic 32-byte key reused across every test so we can compare
  // ciphertexts to expected values when needed.
  final keyBytes = List<int>.generate(32, (i) => i);
  final secretKey = SecretKey(keyBytes);
  const keyId = 'test-key-id';

  group('AesGcmVaultCryptoService', () {
    Matcher rejectedWith(VaultPayloadRejection reason) => throwsA(
      isA<VaultPayloadRejectedError>().having(
        (error) => error.reason,
        'reason',
        reason,
      ),
    );

    String retag(String ciphertext, Map<String, Object?> overrides) {
      final decoded = jsonDecode(ciphertext) as Map<String, dynamic>;
      decoded.addAll(overrides);
      return jsonEncode(decoded);
    }

    test('encrypts a v3 payload bound to record id and key id', () async {
      final service = AesGcmVaultCryptoService();
      const plaintext = 'hunter2';

      final ciphertext = await service.encrypt(
        plaintext: plaintext,
        secretKey: secretKey,
        keyId: keyId,
        recordId: 'rec-a',
      );
      final decoded = jsonDecode(ciphertext) as Map<String, dynamic>;

      expect(decoded['v'], AesGcmVaultCryptoService.payloadVersionV4);
      expect(decoded['keyId'], keyId);
      expect(decoded['rid'], 'rec-a');
      expect(decoded['payload'], isA<Map<String, dynamic>>());
      expect(ciphertext, isNot(contains(plaintext)));
      expect(service.inspect(ciphertext).recordId, 'rec-a');

      final recovered = await service.decrypt(
        ciphertext: ciphertext,
        secretKey: secretKey,
        expectedKeyId: keyId,
        recordId: 'rec-a',
        minimumVersion: 3,
      );
      expect(recovered, plaintext);
    });

    test('v3 round-trip through a v2 session keeps the KDF metadata', () async {
      final service = AesGcmVaultCryptoService();
      const plaintext = 'correct horse battery staple';
      final session = VaultSession.v2(
        keyId: keyId,
        secretKey: secretKey,
        kdf: const {'alg': 'argon2id', 't': 3, 'm': 65536, 'p': 4},
        dekWrap: const {'alg': 'aes-256-gcm', 'ct': '...', 'nonce': '...'},
      );

      final ciphertext = await service.encrypt(
        plaintext: plaintext,
        secretKey: session,
        keyId: keyId,
        recordId: 'rec-a',
      );
      final decoded = jsonDecode(ciphertext) as Map<String, dynamic>;

      expect(decoded['v'], AesGcmVaultCryptoService.payloadVersionV4);
      expect(decoded['kdf'], isA<Map<String, dynamic>>());
      expect(decoded['dek_wrap'], isA<Map<String, dynamic>>());

      final recovered = await service.decrypt(
        ciphertext: ciphertext,
        secretKey: session,
        expectedKeyId: keyId,
        recordId: 'rec-a',
      );
      expect(recovered, plaintext);
    });

    test('associated data is the canonical vaulta:item:v3 string', () {
      expect(
        utf8.decode(
          AesGcmVaultCryptoService.itemAssociatedData(
            recordId: 'rec-a',
            keyId: keyId,
          ),
        ),
        'vaulta:item:v3|rec-a|$keyId',
      );
      expect(
        () => AesGcmVaultCryptoService.itemAssociatedData(
          recordId: 'a|b',
          keyId: keyId,
        ),
        throwsArgumentError,
      );
      expect(
        () => AesGcmVaultCryptoService.itemAssociatedData(
          recordId: 'rec-a',
          keyId: '',
        ),
        throwsArgumentError,
      );
    });

    test('a ciphertext swapped onto another record id fails', () async {
      final service = AesGcmVaultCryptoService();
      final forRecordA = await service.encrypt(
        plaintext: 'secret of A',
        secretKey: secretKey,
        keyId: keyId,
        recordId: 'rec-a',
      );

      // Asking for record B with A's envelope is refused up front.
      await expectLater(
        service.decrypt(
          ciphertext: forRecordA,
          secretKey: secretKey,
          expectedKeyId: keyId,
          recordId: 'rec-b',
        ),
        rejectedWith(VaultPayloadRejection.recordMismatch),
      );

      // Relabelling the clear-text header does not help: GCM
      // authenticates the record id, so the tag no longer verifies.
      await expectLater(
        service.decrypt(
          ciphertext: retag(forRecordA, {'rid': 'rec-b'}),
          secretKey: secretKey,
          expectedKeyId: keyId,
          recordId: 'rec-b',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a ciphertext relabelled with another keyId fails', () async {
      final service = AesGcmVaultCryptoService();
      final ciphertext = await service.encrypt(
        plaintext: 'secret',
        secretKey: secretKey,
        keyId: 'key-generation-1',
        recordId: 'rec-a',
      );

      await expectLater(
        service.decrypt(
          ciphertext: retag(ciphertext, {'keyId': 'key-generation-2'}),
          secretKey: secretKey,
          expectedKeyId: 'key-generation-2',
          recordId: 'rec-a',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('v3 decrypt without a record id is refused', () async {
      final service = AesGcmVaultCryptoService();
      final ciphertext = await service.encrypt(
        plaintext: 'secret',
        secretKey: secretKey,
        keyId: keyId,
        recordId: 'rec-a',
      );

      await expectLater(
        service.decrypt(
          ciphertext: ciphertext,
          secretKey: secretKey,
          expectedKeyId: keyId,
          recordId: null,
        ),
        rejectedWith(VaultPayloadRejection.recordMismatch),
      );
    });

    test('still decrypts legacy v1 and v2 payloads without AAD', () async {
      final service = AesGcmVaultCryptoService();
      final session = VaultSession.v2(
        keyId: keyId,
        secretKey: secretKey,
        kdf: const {'alg': 'argon2id'},
        dekWrap: const {'alg': 'aes-256-gcm'},
      );
      final v1 = await service.encryptLegacyForTesting(
        plaintext: 'legacy one',
        secretKey: secretKey,
        keyId: keyId,
      );
      final v2 = await service.encryptLegacyForTesting(
        plaintext: 'legacy two',
        secretKey: session,
        keyId: keyId,
      );

      expect((jsonDecode(v1) as Map<String, dynamic>)['version'], 1);
      expect((jsonDecode(v2) as Map<String, dynamic>)['v'], 2);
      expect(service.inspect(v1).version, 1);
      expect(service.inspect(v2).recordId, isNull);
      expect(
        await service.decrypt(
          ciphertext: v1,
          secretKey: secretKey,
          expectedKeyId: keyId,
          recordId: null,
        ),
        'legacy one',
      );
      expect(
        await service.decrypt(
          ciphertext: v2,
          secretKey: session,
          expectedKeyId: keyId,
          recordId: null,
        ),
        'legacy two',
      );
    });

    test('refuses v1/v2 payloads below the minimum version', () async {
      final service = AesGcmVaultCryptoService();
      final v1 = await service.encryptLegacyForTesting(
        plaintext: 'legacy',
        secretKey: secretKey,
        keyId: keyId,
      );

      await expectLater(
        service.decrypt(
          ciphertext: v1,
          secretKey: secretKey,
          expectedKeyId: keyId,
          recordId: null,
          minimumVersion: 3,
        ),
        rejectedWith(VaultPayloadRejection.downgrade),
      );
    });

    test('rejects payloads with an unsupported version', () async {
      final service = AesGcmVaultCryptoService();
      final payload = jsonEncode({
        'version': 99,
        'algorithm': 'aes-256-gcm',
        'keyId': keyId,
        'nonce': base64Encode(List<int>.filled(12, 0)),
        'ciphertext': base64Encode([1, 2, 3]),
        'mac': base64Encode(List<int>.filled(16, 0)),
      });

      expect(
        () => service.decrypt(
          ciphertext: payload,
          secretKey: secretKey,
          expectedKeyId: keyId,
          recordId: null,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects payloads whose keyId does not match expected', () async {
      final service = AesGcmVaultCryptoService();
      final ciphertext = await service.encrypt(
        plaintext: 'irrelevant',
        secretKey: secretKey,
        keyId: 'old-key',
        recordId: 'rec-a',
      );

      expect(
        () => service.decrypt(
          ciphertext: ciphertext,
          secretKey: secretKey,
          expectedKeyId: 'new-key',
          recordId: 'rec-a',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a malformed envelope with a structured error', () {
      final service = AesGcmVaultCryptoService();
      expect(
        () => service.inspect('not json'),
        rejectedWith(VaultPayloadRejection.malformed),
      );
    });

    test('rejects secretKey values that are neither SecretKey nor VaultSession',
        () async {
      final service = AesGcmVaultCryptoService();
      expect(
        () => service.encrypt(
          plaintext: 'x',
          secretKey: 'definitely-not-a-key',
          keyId: keyId,
          recordId: 'rec-a',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('VaultSession', () {
    test('v1 factory yields a non-v2 session', () {
      final session = VaultSession.v1(keyId: keyId, secretKey: secretKey);
      expect(session.isV2, isFalse);
      expect(session.kdf, isNull);
      expect(session.dekWrap, isNull);
    });

    test('v2 factory yields a v2 session with both kdf and dekWrap set', () {
      final session = VaultSession.v2(
        keyId: keyId,
        secretKey: secretKey,
        kdf: const {'alg': 'argon2id'},
        dekWrap: const {'alg': 'aes-256-gcm'},
      );
      expect(session.isV2, isTrue);
      expect(session.kdf, isA<Map<String, dynamic>>());
      expect(session.dekWrap, isA<Map<String, dynamic>>());
    });

    test('v2 factory throws on empty kdf', () {
      expect(
        () => VaultSession.v2(
          keyId: keyId,
          secretKey: secretKey,
          kdf: const {},
          dekWrap: const {'alg': 'aes-256-gcm'},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('v2 factory throws on empty dekWrap', () {
      expect(
        () => VaultSession.v2(
          keyId: keyId,
          secretKey: secretKey,
          kdf: const {'alg': 'argon2id'},
          dekWrap: const {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
