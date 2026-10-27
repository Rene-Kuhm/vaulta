import 'package:flutter/foundation.dart';

/// Why the local vault changed without the user doing anything in the
/// current screen.
enum VaultChangeOrigin {
  /// A sync pull applied one or more remote snapshots to the local vault.
  pull,

  /// The vault-key sync adopted a remote master-password record, so this
  /// device now reads the synced vault.
  vaultKeyAdoption,
}

/// What the [VaultChangeSignal] publishes.
///
/// Invariant (deliberate, do not weaken): this event carries **no vault
/// content**. No item title, username, password, URL, notes or category
/// travels through the signal, so a listener cannot leak secrets by
/// logging the notification, and the signal stays safe to forward across
/// layers. Adding a content field is a design change, not a convenience.
@immutable
class VaultChange {
  /// Builds an event. Internal to [VaultChangeSignal]; tests may build one
  /// to compare against `lastChange`.
  const VaultChange({required this.origin, required this.revision});

  /// Which kind of external change happened.
  final VaultChangeOrigin origin;

  /// Monotonic counter of changes published by the owning signal. It lets a
  /// listener tell a fresh event from a stale one without reading any vault
  /// data.
  final int revision;

  @override
  String toString() => 'VaultChange(origin: ${origin.name}, revision: $revision)';
}

/// Event-driven signal that the vault's stored contents changed behind the
/// UI's back: a sync pull applied remote snapshots, or the vault-key sync
/// adopted a remote record.
///
/// Why this lives in the sync layer: the dashboard reads the vault through
/// [VaultRepository], whose interface has no observation hook
/// (`fetchSummary` / `fetchItems` are pull-only), and widening that
/// interface plus both storage implementations is a separate decision.
/// Rather than poll — which this design forbids: no timer, no periodic
/// re-read — the sync layer, which is the only component that knows a
/// remote change landed, publishes this signal, and the UI subscribes to
/// it. The dashboard re-reads the repository on each event; the read stays
/// a plain `VaultRepository` call, so neither the storage layer nor the
/// crypto/payload formats change.
///
/// The signal is app-scoped: the bootstrap creates one instance, hands it
/// to the sync lifecycle (producer) and to the widget tree (consumer). It
/// is never disposed, so `notifyVaultChanged` after a screen unmounts is
/// harmless — listeners remove themselves in `dispose`.
class VaultChangeSignal extends ChangeNotifier {
  /// Number of changes published so far. `0` means "nothing observed yet".
  int get revision => _revision;
  int _revision = 0;

  /// The most recent event, or `null` when nothing was published yet.
  VaultChange? get lastChange => _lastChange;
  VaultChange? _lastChange;

  /// Publishes "the vault changed". Call this only after the change is
  /// durable in the repository, so a listener that re-reads immediately
  /// sees the new data.
  void notifyVaultChanged({required VaultChangeOrigin origin}) {
    _revision += 1;
    _lastChange = VaultChange(origin: origin, revision: _revision);
    notifyListeners();
  }
}
