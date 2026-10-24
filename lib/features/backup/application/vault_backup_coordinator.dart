import 'dart:convert';
import 'dart:typed_data';

import '../../../core/security/master_password_service.dart';
import '../../../core/security/vault_backup_service.dart';
import '../../../core/security/vault_repository.dart';
import '../../../core/security/vault_security_controller.dart';
import '../../../core/security/vault_session.dart';
import '../../vault/application/vault_backup_merger.dart';
import '../domain/vault_clear_text_export.dart';

/// Why a backup password was refused at export time.
enum VaultBackupPasswordIssue {
  /// Shorter than [MasterPasswordService.minimumLength].
  tooShort,

  /// Long enough but missing a character class (same policy as the
  /// master password).
  weak,

  /// The confirmation does not match.
  mismatch,
}

/// Thrown by [VaultBackupCoordinator.createBackup] when the backup
/// password does not meet the policy.
class VaultBackupPasswordException implements Exception {
  /// Builds an exception for [issue].
  const VaultBackupPasswordException(this.issue);

  /// What is wrong with the password.
  final VaultBackupPasswordIssue issue;

  @override
  String toString() => 'VaultBackupPasswordException(${issue.name})';
}

/// Thrown when an export is attempted without a valid
/// [VaultBackupExportGrant] (missing re-authentication, grant already
/// used, expired, or the vault was locked meanwhile).
class VaultBackupNotAuthorizedException implements Exception {
  /// Builds the exception.
  const VaultBackupNotAuthorizedException();

  @override
  String toString() => 'VaultBackupNotAuthorizedException';
}

/// Thrown by [VaultBackupCoordinator.createClearTextExport] when the
/// caller did not record the user's explicit acknowledgement that the
/// file will be written unencrypted. Structural guard so no code path
/// can serialize the vault in clear text by accident.
class VaultClearTextExportNotConfirmedException implements Exception {
  /// Builds the exception.
  const VaultClearTextExportNotConfirmedException();

  @override
  String toString() => 'VaultClearTextExportNotConfirmedException';
}

/// Single-use proof that the master password was re-entered through
/// the throttled path. Only [VaultBackupCoordinator.authorizeExport]
/// can create one; it is bound to the vault session that was active at
/// re-authentication and expires after
/// [VaultBackupCoordinator.grantLifetime].
class VaultBackupExportGrant {
  VaultBackupExportGrant._({required this.issuedAt, required Object session})
    : _session = session;

  /// When the re-authentication succeeded.
  final DateTime issuedAt;
  final Object _session;
  bool _consumed = false;
}

/// A decrypted backup plus the merge plan against the current vault,
/// shown to the user before anything is written.
class VaultBackupRestorePreview {
  /// Builds a preview.
  const VaultBackupRestorePreview({required this.contents, required this.plan});

  /// Decrypted backup content.
  final VaultBackupContents contents;

  /// What a restore would do with each item.
  final VaultBackupMergePlan plan;
}

/// Orchestrates encrypted backup export and restore (ADR-006).
///
/// Export is a two-step flow: [authorizeExport] re-verifies the master
/// password through [VaultSecurityController.reauthenticateWithPassword]
/// (shared unlock throttle) and returns a single-use grant;
/// [createBackup] then seals the vault under the backup password.
/// There is no other way to obtain the sealed bytes.
class VaultBackupCoordinator {
  /// Builds a coordinator. [backupService] defaults to production
  /// Argon2id parameters; [clock] defaults to [DateTime.now].
  VaultBackupCoordinator({
    required VaultSecurityController securityController,
    required VaultRepository repository,
    VaultBackupService? backupService,
    VaultBackupMerger merger = const VaultBackupMerger(),
    DateTime Function()? clock,
  }) : _securityController = securityController,
       _repository = repository,
       _backupService = backupService ?? VaultBackupService(),
       _merger = merger,
       _clock = clock ?? DateTime.now;

  /// How long a re-authentication stays valid for one export.
  static const grantLifetime = Duration(minutes: 5);

  final VaultSecurityController _securityController;
  final VaultRepository _repository;
  final VaultBackupService _backupService;
  final VaultBackupMerger _merger;
  final DateTime Function() _clock;
  final MasterPasswordService _passwordPolicy = MasterPasswordService();

  /// Re-verifies [masterPassword] through the throttled unlock path.
  /// Returns a grant on success, `null` on mismatch, lockout, storage
  /// failure or a locked vault.
  Future<VaultBackupExportGrant?> authorizeExport(String masterPassword) async {
    final session = _securityController.vaultSession;
    if (session == null) {
      return null;
    }
    final ok = await _securityController.reauthenticateWithPassword(
      masterPassword,
    );
    if (!ok || !identical(_securityController.vaultSession, session)) {
      return null;
    }
    return VaultBackupExportGrant._(issuedAt: _clock(), session: session);
  }

  /// Applies the master-password policy to a backup password and its
  /// [confirmation]. Returns `null` when acceptable.
  VaultBackupPasswordIssue? validateBackupPassword(
    String password,
    String confirmation,
  ) {
    if (_passwordPolicy.validate(password) != null) {
      return password.length < MasterPasswordService.minimumLength
          ? VaultBackupPasswordIssue.tooShort
          : VaultBackupPasswordIssue.weak;
    }
    if (password != confirmation) {
      return VaultBackupPasswordIssue.mismatch;
    }
    return null;
  }

  /// Number of items an export would contain.
  Future<int> countItems() async => (await _repository.fetchItems()).length;

  /// Seals every vault item into a `.vaulta` envelope. Consumes
  /// [grant]; throws [VaultBackupNotAuthorizedException] when the grant
  /// is used, expired or bound to a session that is no longer active,
  /// and [VaultBackupPasswordException] when the backup password fails
  /// the policy (the grant stays usable in that case).
  Future<Uint8List> createBackup({
    required VaultBackupExportGrant grant,
    required String backupPassword,
    required String confirmation,
    required String appVersion,
  }) async {
    _checkGrant(grant);
    final issue = validateBackupPassword(backupPassword, confirmation);
    if (issue != null) {
      throw VaultBackupPasswordException(issue);
    }
    grant._consumed = true;
    final items = await _repository.fetchItems();
    return _backupService.export(
      items: items,
      backupPassword: backupPassword,
      appVersion: appVersion,
    );
  }

  /// Renders the vault as a clear-text (unencrypted) file in [format],
  /// after consuming [grant]. [acknowledgedUnencrypted] must be `true`:
  /// the caller is promising that the user saw the warning that the file
  /// will be readable by anyone, and confirmed it. Without it this
  /// method throws [VaultClearTextExportNotConfirmedException] and the
  /// grant stays usable.
  ///
  /// Throws [VaultBackupNotAuthorizedException] for a used, expired or
  /// unlocked-session-less grant. The encrypted `.vaulta` export is
  /// untouched by this path.
  Future<Uint8List> createClearTextExport({
    required VaultBackupExportGrant grant,
    required VaultClearTextFormat format,
    required bool acknowledgedUnencrypted,
    required String appVersion,
  }) async {
    _checkGrant(grant);
    if (!acknowledgedUnencrypted) {
      throw const VaultClearTextExportNotConfirmedException();
    }
    grant._consumed = true;
    const exporter = VaultClearTextExporter();
    final items = await _repository.fetchItems();
    final content = switch (format) {
      VaultClearTextFormat.csv => exporter.csv(items),
      VaultClearTextFormat.json => exporter.json(
        items,
        exportedAt: _clock(),
        appVersion: appVersion,
      ),
    };
    return Uint8List.fromList(utf8.encode(content));
  }

  /// Reads the unauthenticated header of a picked file, for display
  /// before the password is entered. Throws [VaultBackupException].
  VaultBackupHeader readHeader(Uint8List bytes) =>
      _backupService.readHeader(bytes);

  /// Decrypts [bytes] with [backupPassword] and plans the merge against
  /// the current vault. Writes nothing. Throws [VaultBackupException].
  Future<VaultBackupRestorePreview> previewRestore({
    required Uint8List bytes,
    required String backupPassword,
  }) async {
    final contents = await _backupService.decrypt(
      bytes: bytes,
      backupPassword: backupPassword,
    );
    final plan = _merger.plan(
      backupItems: contents.items,
      existingItems: await _repository.fetchItems(),
    );
    return VaultBackupRestorePreview(contents: contents, plan: plan);
  }

  /// Writes the previewed items through the repository save path.
  /// Requires an unlocked vault.
  Future<VaultBackupMergeResult> applyRestore({
    required VaultBackupRestorePreview preview,
    required String conflictSuffix,
  }) {
    if (!_securityController.isUnlocked) {
      throw const VaultBackupNotAuthorizedException();
    }
    return _merger.apply(
      backupItems: preview.contents.items,
      repository: _repository,
      conflictSuffix: conflictSuffix,
    );
  }

  void _checkGrant(VaultBackupExportGrant grant) {
    final VaultSession? session = _securityController.vaultSession;
    final age = _clock().difference(grant.issuedAt);
    if (grant._consumed ||
        session == null ||
        !_securityController.isUnlocked ||
        !identical(grant._session, session) ||
        age.isNegative ||
        age > grantLifetime) {
      throw const VaultBackupNotAuthorizedException();
    }
  }
}

/// Default file name for a backup created at [now].
String vaultBackupFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  final local = now.toLocal();
  return 'vaulta-backup-${local.year}${two(local.month)}${two(local.day)}-'
      '${two(local.hour)}${two(local.minute)}.${VaultBackupService.fileExtension}';
}
