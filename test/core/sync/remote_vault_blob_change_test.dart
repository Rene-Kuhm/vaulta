// Row mapping for the item key salt: a v4 `vault_blobs` row carries
// the salt and item key version of its own per-item key in
// `item_key_salt` / `item_key_version`, and only from that version on.
// See docs/adr/0002-sync-versioning-cas-idempotency-tombstones.md.
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/sync/remote_vault_blob_change.dart';
import 'package:gestor_contrasenas/core/sync/sync_item_payload_codec.dart';

void main() {
  group('RemoteVaultBlobChange.fromSupabaseRows', () {
    Map<String, dynamic> blobRow({
      int keyVersion = 1,
      String? itemKeySalt,
      int? itemKeyVersion,
      String? deletedAt,
    }) {
      return {
        'record_id': '11111111-1111-4111-8111-111111111111',
        'version': 3,
        'key_version': keyVersion,
        'ciphertext': 'ZW50cnkuMQ.Y2lwaGVy',
        'nonce': 'bm9uY2U=',
        'gcm_tag': 'dGFn',
        'item_key_salt': ?itemKeySalt,
        'item_key_version': ?itemKeyVersion,
        'deleted_at': deletedAt,
        'updated_at': '2026-03-23T15:00:00Z',
      };
    }

    RemoteVaultBlobChange changeFrom(Map<String, dynamic> blob) {
      return RemoteVaultBlobChange.fromSupabaseRows(
        opRow: {'id': 7},
        blobRow: blob,
      );
    }

    test('reads the salt and item key version of a v4 row', () {
      final change = changeFrom(
        blobRow(
          keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
          itemKeySalt: 'c2FsdC1ieC1ieQ==',
          itemKeyVersion: 1,
        ),
      );

      expect(change.opCursor, 7);
      expect(change.version, 3);
      expect(change.itemKeySalt, 'c2FsdC1ieC1ieQ==');
      expect(change.itemKeyVersion, 1);
    });

    test('a pre-v4 row reports no salt even if a stale one is stored', () {
      // An old client's RPC cannot clear the columns it does not know
      // about, so a row rewritten down to v3 can keep a v4 salt. The
      // model must not report an item key for a payload that has none:
      // the gate belongs here so no consumer has to remember it.
      final change = changeFrom(
        blobRow(keyVersion: 3, itemKeySalt: 'c3RhbGU=', itemKeyVersion: 1),
      );

      expect(change.itemKeySalt, isNull);
      expect(change.itemKeyVersion, isNull);
    });

    test('a tombstone carries no salt', () {
      final change = changeFrom(
        blobRow(
          keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
          itemKeySalt: 'c2FsdC1ieC1ieQ==',
          itemKeyVersion: 1,
          deletedAt: '2026-03-23T15:00:00Z',
        ),
      );

      expect(change.isTombstone, isTrue);
      expect(change.ciphertext, isNull);
      expect(change.nonce, isNull);
      expect(change.gcmTag, isNull);
      expect(change.itemKeySalt, isNull);
      expect(change.itemKeyVersion, isNull);
    });

    test('a row without the new columns maps to nulls, not an error', () {
      final change = changeFrom(blobRow(keyVersion: 1));

      expect(change.itemKeySalt, isNull);
      expect(change.itemKeyVersion, isNull);
    });
  });

  group('RemoteVaultBlobSnapshot persistence', () {
    test('keeps the salt through a change -> snapshot -> json round trip', () {
      final change = RemoteVaultBlobChange(
        opCursor: 7,
        recordId: 'entry-1',
        version: 3,
        keyVersion: SyncItemPayloadCodec.itemKeyPayloadVersion,
        ciphertext: 'ZW50cnkuMQ.Y2lwaGVy',
        nonce: 'bm9uY2U=',
        gcmTag: 'dGFn',
        itemKeySalt: 'c2FsdC1ieC1ieQ==',
        itemKeyVersion: 2,
        updatedAt: DateTime.utc(2026, 3, 23, 15),
      );

      final snapshot = RemoteVaultBlobSnapshot.fromChange(change);
      final restored = RemoteVaultBlobSnapshot.fromJson(snapshot.toJson());

      expect(snapshot.itemKeySalt, 'c2FsdC1ieC1ieQ==');
      expect(snapshot.itemKeyVersion, 2);
      expect(restored.itemKeySalt, 'c2FsdC1ieC1ieQ==');
      expect(restored.itemKeyVersion, 2);
      expect(restored.recordId, 'entry-1');
      expect(restored.ciphertext, change.ciphertext);
      expect(restored.updatedAt, change.updatedAt);
    });

    test('a snapshot persisted before this change loads with null salt', () {
      final restored = RemoteVaultBlobSnapshot.fromJson({
        'recordId': 'entry-1',
        'version': 3,
        'keyVersion': 3,
        'ciphertext': 'ZW50cnkuMQ.Y2lwaGVy',
        'nonce': 'bm9uY2U=',
        'gcmTag': 'dGFn',
        'deletedAt': null,
        'updatedAt': '2026-03-23T15:00:00Z',
      });

      expect(restored.itemKeySalt, isNull);
      expect(restored.itemKeyVersion, isNull);
    });
  });
}
