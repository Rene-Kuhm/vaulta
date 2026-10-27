import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/master_password_record.dart';
import 'package:gestor_contrasenas/core/sync/vault_change_signal.dart';
import 'package:gestor_contrasenas/core/sync/vault_key_sync_repository.dart';
import 'package:gestor_contrasenas/core/sync/vault_key_sync_service.dart';

/// In-memory [VaultKeySyncRepository] so the reconcile logic is exercised
/// without a live Supabase project.
class _FakeRepository implements VaultKeySyncRepository {
  String? remote;
  final List<String> puts = [];

  @override
  Future<String?> readRemoteKey() async => remote;

  @override
  Future<void> putRemoteKey({
    required String keyId,
    required String recordJson,
  }) async {
    puts.add(recordJson);
    remote = recordJson;
  }
}

MasterPasswordRecord _record(String keyId) {
  return MasterPasswordRecord(
    version: MasterPasswordRecord.currentVersion,
    verifierIterations: 3,
    verifierSalt: 'c2FsdA==',
    verifier: 'dmVyaWZpZXI=',
    encryptionIterations: 3,
    encryptionSalt: 'c2FsdA==',
    keyId: keyId,
    createdAt: DateTime.utc(2026, 1, 1),
    kdf: const {
      'name': 'argon2id',
      'salt_b64': 'c2FsdA==',
      'memory_kib': 65536,
      'iterations': 3,
      'parallelism': 1,
      'dk_len': 64,
      'split': 'hkdf-sha256-v3',
    },
    dekWrap: const {
      'alg': 'AES-256-GCM',
      'nonce_b64': 'bm9uY2U=',
      'ciphertext_b64': 'Y2lwaGVy',
      'tag_b64': 'dGFn',
    },
    pwNorm: MasterPasswordRecord.nfcMarker,
  );
}

void main() {
  test('pushes the local record when this device has one', () async {
    final repository = _FakeRepository();
    final adopted = <String>[];
    final service = VaultKeySyncService(
      repository: repository,
      readLocalRecordJson: () async => _record('local-key').encode(),
      adoptRemoteRecord: (r) async => adopted.add(r),
    );

    await service.syncOnce();

    expect(repository.puts, hasLength(1));
    expect(adopted, isEmpty, reason: 'a local record must never be overwritten');
  });

  test('adopts the remote record when this device has none', () async {
    final repository = _FakeRepository()
      ..remote = _record('remote-key').encode();
    final adopted = <String>[];
    final service = VaultKeySyncService(
      repository: repository,
      readLocalRecordJson: () async => null,
      adoptRemoteRecord: (r) async => adopted.add(r),
    );

    await service.syncOnce();

    expect(adopted, hasLength(1));
    expect(repository.puts, isEmpty, reason: 'nothing local to push');
  });

  test('does nothing when neither side has a vault key', () async {
    final repository = _FakeRepository();
    final adopted = <String>[];
    final service = VaultKeySyncService(
      repository: repository,
      readLocalRecordJson: () async => null,
      adoptRemoteRecord: (r) async => adopted.add(r),
    );

    await service.syncOnce();

    expect(adopted, isEmpty);
    expect(repository.puts, isEmpty);
  });

  test('does not adopt when the local record is malformed', () async {
    final repository = _FakeRepository();
    final adopted = <String>[];
    final service = VaultKeySyncService(
      repository: repository,
      // A local record that cannot yield a key id must not crash the cycle.
      readLocalRecordJson: () async => '{"not":"a record"}',
      adoptRemoteRecord: (r) async => adopted.add(r),
    );

    await service.syncOnce();

    expect(repository.puts, isEmpty, reason: 'no key id, so nothing pushed');
    expect(adopted, isEmpty);
  });

  test('publishes a change event when it adopts a remote record', () async {
    final repository = _FakeRepository()
      ..remote = _record('remote-key').encode();
    final adopted = <String>[];
    final signal = VaultChangeSignal();
    final published = <VaultChange>[];
    signal.addListener(() => published.add(signal.lastChange!));
    final service = VaultKeySyncService(
      repository: repository,
      readLocalRecordJson: () async => null,
      adoptRemoteRecord: (r) async => adopted.add(r),
      vaultChanges: signal,
    );

    await service.syncOnce();

    expect(adopted, hasLength(1));
    expect(published, hasLength(1));
    expect(published.single.origin, VaultChangeOrigin.vaultKeyAdoption);
    // No key material crosses the signal: the event only says "the vault this
    // device reads changed".
    expect(published.single.toString(), isNot(contains('remote-key')));
    expect(published.single.toString(), isNot(contains('dmVyaWZpZXI=')));
  });

  test('stays silent when it only pushes the local record', () async {
    final repository = _FakeRepository();
    final signal = VaultChangeSignal();
    var notified = 0;
    signal.addListener(() => notified += 1);
    final service = VaultKeySyncService(
      repository: repository,
      readLocalRecordJson: () async => _record('local-key').encode(),
      adoptRemoteRecord: (r) async {},
      vaultChanges: signal,
    );

    await service.syncOnce();

    expect(repository.puts, hasLength(1));
    // A push does not change the local vault, so the UI has nothing to re-read.
    expect(notified, 0);
  });
}
