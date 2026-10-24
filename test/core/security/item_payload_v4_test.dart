import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/security/vault_session.dart';

/// Pins the v4 item-key contract: every item gets its own key derived
/// from the DEK, and the associated data binds that key to the record,
/// the key generation and the item key version.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = AesGcmVaultCryptoService();
  final dek = SecretKey(List<int>.generate(32, (i) => i + 1));
  final session = VaultSession.v2(
    keyId: 'key-gen-1',
    secretKey: dek,
    kdf: const {'name': 'argon2id'},
    dekWrap: const {'alg': 'AES-256-GCM'},
  );

  Map<String, dynamic> envelopeOf(String ciphertext) =>
      jsonDecode(ciphertext) as Map<String, dynamic>;

  group('v4 at rest', () {
    test('writes version 4 carrying the item key version and salt',
        () async {
      final payload = await service.encrypt(
        plaintext: '{"id":"github"}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );
      final envelope = envelopeOf(payload);

      expect(envelope['v'], AesGcmVaultCryptoService.payloadVersionV4);
      expect(envelope['rid'], 'github');
      expect(envelope['keyId'], session.keyId);
      expect(
        envelope['iv'],
        AesGcmVaultCryptoService.currentItemKeyVersion,
      );
      expect(base64Decode(envelope['salt'] as String), hasLength(16));
    });

    test('the item is not sealed under the DEK', () async {
      // The whole point of v4: opening the envelope with the DEK must
      // fail, which is what makes a single compromised item useless for
      // reaching the rest of the vault.
      final payload = await service.encrypt(
        plaintext: '{"id":"github"}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );
      final envelope = envelopeOf(payload);
      final box = SecretBox(
        base64Decode(
          (envelope['payload'] as Map)['ciphertext_b64'] as String,
        ),
        nonce: base64Decode(
          (envelope['payload'] as Map)['nonce_b64'] as String,
        ),
        mac: Mac(
          base64Decode((envelope['payload'] as Map)['tag_b64'] as String),
        ),
      );

      await expectLater(
        AesGcm.with256bits().decrypt(box, secretKey: dek),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('two items never share an item key', () async {
      final first = envelopeOf(
        await service.encrypt(
          plaintext: 'a',
          secretKey: session,
          keyId: session.keyId,
          recordId: 'a',
        ),
      );
      final second = envelopeOf(
        await service.encrypt(
          plaintext: 'b',
          secretKey: session,
          keyId: session.keyId,
          recordId: 'b',
        ),
      );

      expect(first['salt'], isNot(second['salt']));

      final keyA = await AesGcmVaultCryptoService.itemKeyFor(
        dek: dek,
        salt: base64Decode(first['salt'] as String),
        recordId: 'a',
        keyId: session.keyId,
        itemKeyVersion: AesGcmVaultCryptoService.currentItemKeyVersion,
      );
      final keyB = await AesGcmVaultCryptoService.itemKeyFor(
        dek: dek,
        salt: base64Decode(first['salt'] as String),
        recordId: 'b',
        keyId: session.keyId,
        itemKeyVersion: AesGcmVaultCryptoService.currentItemKeyVersion,
      );

      expect(await keyA.extractBytes(), isNot(await keyB.extractBytes()));
    });

    test('round-trips under the same session', () async {
      const plaintext = '{"id":"github","secret":"hunter2"}';
      final payload = await service.encrypt(
        plaintext: plaintext,
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );

      final recovered = await service.decrypt(
        ciphertext: payload,
        secretKey: session,
        expectedKeyId: session.keyId,
        recordId: 'github',
      );

      expect(recovered, plaintext);
    });

    test('reports its version, record id and item key version', () async {
      final payload = await service.encrypt(
        plaintext: '{}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );

      final header = service.inspect(payload);

      expect(header.version, AesGcmVaultCryptoService.payloadVersionV4);
      expect(header.recordId, 'github');
      expect(header.keyId, session.keyId);
      expect(
        header.itemKeyVersion,
        AesGcmVaultCryptoService.currentItemKeyVersion,
      );
    });
  });

  group('v4 associated data is bound', () {
    test('refuses a payload replayed under another record id', () async {
      final payload = await service.encrypt(
        plaintext: '{"id":"github"}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );

      await expectLater(
        service.decrypt(
          ciphertext: payload,
          secretKey: session,
          expectedKeyId: session.keyId,
          recordId: 'bank',
        ),
        _rejectedWith(VaultPayloadRejection.recordMismatch),
      );
    });

    test('refuses a payload presented under another key generation',
        () async {
      final payload = await service.encrypt(
        plaintext: '{"id":"github"}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );

      await expectLater(
        service.decrypt(
          ciphertext: payload,
          secretKey: session,
          expectedKeyId: 'key-gen-2',
          recordId: 'github',
        ),
        _rejectedWith(VaultPayloadRejection.keyMismatch),
      );
    });

    test('refuses a payload whose item key version was rewritten', () async {
      // iv is in the AAD, so relabelling an item under a new key version
      // changes both the derived item key and the AAD. The envelope stays
      // well-formed, so the refusal comes from the GCM tag, not from a
      // shape check.
      final payload = await service.encrypt(
        plaintext: '{"id":"github"}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );
      final envelope = envelopeOf(payload);
      final tampered = jsonEncode({...envelope, 'iv': 2});

      await expectLater(
        service.decrypt(
          ciphertext: tampered,
          secretKey: session,
          expectedKeyId: session.keyId,
          recordId: 'github',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('a salt injected into a v3 payload is inert', () async {
      // v3 has no salt field. Adding one must not switch the payload onto
      // the v4 key path, and must not grant anything: v3 is still sealed
      // under the DEK, which is exactly why the injected field buys the
      // attacker nothing.
      final payload = await service.encryptV3ForTesting(
        plaintext: '{"id":"github"}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );
      final envelope = envelopeOf(payload);
      final tampered = jsonEncode({
        ...envelope,
        'salt': base64Encode(List<int>.filled(16, 7)),
      });

      expect(
        service.inspect(tampered).version,
        AesGcmVaultCryptoService.payloadVersionV3,
        reason: 'an extra field must not promote the payload to v4',
      );
      expect(
        await service.decrypt(
          ciphertext: tampered,
          secretKey: session,
          expectedKeyId: session.keyId,
          recordId: 'github',
        ),
        '{"id":"github"}',
      );
    });

    test('rejects an empty or separator-bearing AAD field', () {
      expect(
        () => AesGcmVaultCryptoService.itemAssociatedDataV4(
          recordId: '',
          keyId: 'k',
          itemKeyVersion: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AesGcmVaultCryptoService.itemAssociatedDataV4(
          recordId: 'a|b',
          keyId: 'k',
          itemKeyVersion: 1,
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'the | separator must stay unambiguous',
      );
      expect(
        () => AesGcmVaultCryptoService.itemAssociatedDataV4(
          recordId: 'a',
          keyId: 'k',
          itemKeyVersion: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('legacy payloads still open', () {
    test('a v3 payload decrypts under the DEK', () async {
      const plaintext = '{"id":"github"}';
      final payload = await service.encryptV3ForTesting(
        plaintext: plaintext,
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );

      expect(envelopeOf(payload)['v'], AesGcmVaultCryptoService.payloadVersionV3);
      expect(
        await service.decrypt(
          ciphertext: payload,
          secretKey: session,
          expectedKeyId: session.keyId,
          recordId: 'github',
        ),
        plaintext,
      );
    });

    test('a v2 payload with no associated data still decrypts', () async {
      const plaintext = '{"id":"github"}';
      final payload = await service.encryptLegacyForTesting(
        plaintext: plaintext,
        secretKey: session,
        keyId: session.keyId,
      );

      expect(
        await service.decrypt(
          ciphertext: payload,
          secretKey: session,
          expectedKeyId: session.keyId,
          recordId: null,
        ),
        plaintext,
      );
    });

    test('inspect reports no item key version for a v3 payload', () async {
      final payload = await service.encryptV3ForTesting(
        plaintext: '{}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );

      final header = service.inspect(payload);

      expect(header.version, AesGcmVaultCryptoService.payloadVersionV3);
      expect(header.itemKeyVersion, isNull);
    });
  });

  group('salt handling', () {
    test('encrypt draws a different salt every time', () async {
      // A fixed Random is injected so this is deterministic, but even
      // then the ciphertext and salt must differ per call, because the
      // salt is drawn inside encrypt and not derived from the item.
      final seeded = AesGcmVaultCryptoService(random: Random(7));
      final salts = <String>{};
      for (var i = 0; i < 5; i++) {
        final payload = await seeded.encrypt(
          plaintext: 'same plaintext',
          secretKey: session,
          keyId: session.keyId,
          recordId: 'github',
        );
        salts.add(envelopeOf(payload)['salt'] as String);
      }
      expect(salts, hasLength(5));
    });

    test('a payload without a salt is refused rather than guessed', () async {
      final payload = await service.encrypt(
        plaintext: '{}',
        secretKey: session,
        keyId: session.keyId,
        recordId: 'github',
      );
      final envelope = envelopeOf(payload)..remove('salt');

      await expectLater(
        service.decrypt(
          ciphertext: jsonEncode(envelope),
          secretKey: session,
          expectedKeyId: session.keyId,
          recordId: 'github',
        ),
        _rejectedWith(VaultPayloadRejection.malformed),
      );
    });
  });
}

Matcher _rejectedWith(VaultPayloadRejection reason) => throwsA(
  isA<VaultPayloadRejectedError>().having((e) => e.reason, 'reason', reason),
);