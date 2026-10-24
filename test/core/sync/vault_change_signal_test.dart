import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/sync/vault_change_signal.dart';

/// Contract of [VaultChangeSignal] on its own: a monotonic, listener-driven
/// notification whose payload is nothing but "what" and "which revision".
///
/// The cross-layer half of the same contract — that a real pull publishes one
/// event and no vault content travels in it — is covered by
/// `test/core/sync/bidirectional_sync_service_test.dart` (`REQ-BS-CHANGE`) and
/// `test/core/sync/vault_key_sync_service_test.dart`.
void main() {
  test('starts silent: no revision and no event', () {
    final signal = VaultChangeSignal();

    expect(signal.revision, 0);
    expect(signal.lastChange, isNull);
  });

  test('each notification bumps the revision and alerts listeners once', () {
    final signal = VaultChangeSignal();
    final seen = <VaultChange>[];
    signal.addListener(() => seen.add(signal.lastChange!));

    signal.notifyVaultChanged(origin: VaultChangeOrigin.pull);
    signal.notifyVaultChanged(origin: VaultChangeOrigin.vaultKeyAdoption);

    expect(seen, hasLength(2));
    expect(signal.revision, 2);
    expect(seen.first.origin, VaultChangeOrigin.pull);
    expect(seen.first.revision, 1);
    expect(seen.last.origin, VaultChangeOrigin.vaultKeyAdoption);
    expect(seen.last.revision, 2);
  });

  test('a removed listener stops receiving notifications', () {
    final signal = VaultChangeSignal();
    var calls = 0;
    void listener() => calls += 1;

    signal.addListener(listener);
    signal.notifyVaultChanged(origin: VaultChangeOrigin.pull);
    signal.removeListener(listener);
    signal.notifyVaultChanged(origin: VaultChangeOrigin.pull);

    expect(calls, 1);
    expect(signal.revision, 2);
  });

  test('the event exposes only the origin and the revision', () {
    final signal = VaultChangeSignal();

    signal.notifyVaultChanged(origin: VaultChangeOrigin.vaultKeyAdoption);

    // Pinned on purpose: this is the whole payload. If vault content were ever
    // added to the event, this assertion and the invariant documented on
    // [VaultChange] would both fail review.
    expect(
      signal.lastChange.toString(),
      'VaultChange(origin: vaultKeyAdoption, revision: 1)',
    );
  });
}
