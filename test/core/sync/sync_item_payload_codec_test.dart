// Wire contract of the `ciphertext` column: the record binding a
// receiver must verify before it hands a payload to the vault, and the
// payload version from which a row also needs the item key salt on its
// own columns. See docs/architecture/ADR-002-sync.md.
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/aes_gcm_vault_crypto_service.dart';
import 'package:gestor_contrasenas/core/sync/sync_item_payload_codec.dart';

void main() {
  group('SyncItemPayloadCodec', () {
    test('the item key version gate is the at-rest v4 payload version', () {
      // If the crypto service bumps item payload v5 without this gate,
      // a v5 row would be read as if it needed no salt, and the receiver
      // would derive the wrong item key instead of refusing.
      expect(
        SyncItemPayloadCodec.itemKeyPayloadVersion,
        AesGcmVaultCryptoService.payloadVersionV4,
      );
      expect(
        SyncItemPayloadCodec.itemKeyPayloadVersion,
        greaterThan(SyncItemPayloadCodec.boundPayloadVersion),
        reason: 'an item-keyed payload is also record-bound',
      );
    });

    test('encodes the record id next to the base64 ciphertext', () {
      final wire = SyncItemPayloadCodec.encode(
        recordId: 'entry-1',
        ciphertextB64: 'Y2lwaGVy',
      );

      final decoded = SyncItemPayloadCodec.decode(wire);

      expect(decoded, isNotNull);
      expect(decoded!.recordId, 'entry-1');
      expect(decoded.ciphertextB64, 'Y2lwaGVy');
    });

    test('round-trips a record id that is not url safe', () {
      final wire = SyncItemPayloadCodec.encode(
        recordId: 'a b/c+d=e?f',
        ciphertextB64: 'Y2lwaGVy',
      );

      expect(SyncItemPayloadCodec.decode(wire)!.recordId, 'a b/c+d=e?f');
    });

    test('refuses wire values it cannot split unambiguously', () {
      for (final wire in <String?>[
        null,
        '',
        'no-separator',
        '.Y2lwaGVy',
        'ZW50cnktMQ.',
        'not base64!.Y2lwaGVy',
      ]) {
        expect(SyncItemPayloadCodec.decode(wire), isNull, reason: 'wire=$wire');
      }
    });
  });
}
