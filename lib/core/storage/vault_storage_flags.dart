/// Compile-time switches for the vault storage (ADR-007).
///
/// These are `bool.fromEnvironment` rather than plain constants so a build can
/// opt in without a code change:
///
/// ```
/// flutter run --dart-define=VAULTA_SQLITE_STORAGE=true
/// ```
///
/// Both default to `false`, which is the whole safety story of this step: the
/// SQLite path is wired and tested but **off** in every normal build, so a
/// migration never runs over somebody's real vault because of a merge.
library;

/// Routes the vault through the encrypted SQLite database instead of the single
/// encrypted blob.
///
/// Off by default. Flipping it in a release is the one decision ADR-007 reserves
/// for the owner, and it requires the verification plan in that ADR: an encrypted
/// `.vaulta` backup taken first, then a real device run.
const bool vaultSqliteStorageEnabled = bool.fromEnvironment(
  'VAULTA_SQLITE_STORAGE',
);
