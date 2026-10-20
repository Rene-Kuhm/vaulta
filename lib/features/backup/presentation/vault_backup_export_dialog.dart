import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/master_password_service.dart';
import '../../../core/security/vault_security_controller.dart';
import '../../security/presentation/unlock_throttle_text.dart';
import '../application/vault_backup_coordinator.dart';
import '../data/vault_backup_file_gateway.dart';

/// Two-step dialog that exports the vault as an encrypted `.vaulta`
/// file: (1) re-enter the master password through the throttled
/// re-authentication path, (2) choose and confirm a backup password,
/// then save through the platform save dialog.
///
/// Pops with `true` once the file was saved, `null` otherwise.
class VaultBackupExportDialog extends StatefulWidget {
  /// Builds the dialog.
  const VaultBackupExportDialog({
    super.key,
    required this.coordinator,
    required this.securityController,
    required this.fileGateway,
    required this.appVersionLoader,
    this.clock,
  });

  /// Coordinator that re-authenticates and seals the backup.
  final VaultBackupCoordinator coordinator;

  /// Controller used for throttle feedback and to pause the
  /// background auto-lock while the system save dialog is open.
  final VaultSecurityController securityController;

  /// Writes the sealed envelope to a user-chosen location.
  final VaultBackupFileGateway fileGateway;

  /// Resolves the app version written into the envelope header.
  final Future<String> Function() appVersionLoader;

  /// Clock for the suggested file name; defaults to [DateTime.now].
  final DateTime Function()? clock;

  @override
  State<VaultBackupExportDialog> createState() =>
      _VaultBackupExportDialogState();
}

class _VaultBackupExportDialogState extends State<VaultBackupExportDialog> {
  final _masterController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  VaultBackupExportGrant? _grant;
  int? _itemCount;
  Uint8List? _sealed;
  String? _feedback;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    // Drop the sealed envelope and the grant with the dialog (the
    // SecurityGate pops it on lock).
    _sealed = null;
    _grant = null;
    _masterController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final reauthStep = _grant == null && _sealed == null;

    final children = <Widget>[
      if (reauthStep) ...[
        Text(l10n.backupReauthBody),
        const SizedBox(height: AppSpacing.sm),
        _passwordField(
          key: const Key('backup.export.masterPassword'),
          controller: _masterController,
          label: l10n.backupMasterPasswordLabel,
          onSubmitted: (_) => _authorize(),
        ),
      ] else ...[
        if (_itemCount case final count?)
          Text(
            l10n.backupItemCount(count),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        AppBanner(
          message: l10n.backupPasswordWarning,
          tone: AppBannerTone.warning,
          icon: Icons.key_off_rounded,
        ),
        if (_sealed == null) ...[
          const SizedBox(height: AppSpacing.sm),
          _passwordField(
            key: const Key('backup.export.password'),
            controller: _passwordController,
            label: l10n.backupPasswordLabel,
          ),
          const SizedBox(height: AppSpacing.sm),
          _passwordField(
            key: const Key('backup.export.confirm'),
            controller: _confirmController,
            label: l10n.backupPasswordConfirmLabel,
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.backupPasswordHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
      if (_feedback case final feedback?) ...[
        const SizedBox(height: AppSpacing.sm),
        AppBanner(
          key: const Key('backup.export.feedback'),
          message: feedback,
          tone: AppBannerTone.danger,
          icon: Icons.error_outline_rounded,
        ),
      ],
    ];

    final String primaryLabel;
    final VoidCallback primaryAction;
    if (reauthStep) {
      primaryLabel = l10n.backupContinue;
      primaryAction = _authorize;
    } else if (_sealed != null) {
      primaryLabel = l10n.backupSaveAgain;
      primaryAction = _save;
    } else {
      primaryLabel = l10n.backupCreateAction;
      primaryAction = _create;
    }

    return AlertDialog(
      title: Text(l10n.backupExportTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('backup.export.primary'),
          onPressed: _busy ? null : primaryAction,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(primaryLabel),
        ),
      ],
    );
  }

  Widget _passwordField({
    required Key key,
    required TextEditingController controller,
    required String label,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      key: key,
      controller: controller,
      obscureText: _obscure,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
            _obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
          ),
        ),
      ),
    );
  }

  Future<void> _authorize() async {
    setState(() {
      _busy = true;
      _feedback = null;
    });
    final grant = await widget.coordinator.authorizeExport(
      _masterController.text,
    );
    int? count;
    if (grant != null) {
      count = await widget.coordinator.countItems();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (grant == null) {
        _feedback =
            unlockThrottleMessage(context.l10n, widget.securityController) ??
            context.l10n.backupMasterPasswordMismatch;
        return;
      }
      _masterController.clear();
      _grant = grant;
      _itemCount = count;
    });
  }

  String _passwordIssueText(VaultBackupPasswordIssue issue) {
    final l10n = context.l10n;
    return switch (issue) {
      VaultBackupPasswordIssue.tooShort => l10n.backupPasswordTooShort(
        MasterPasswordService.minimumLength,
      ),
      VaultBackupPasswordIssue.weak => l10n.backupPasswordWeak,
      VaultBackupPasswordIssue.mismatch => l10n.backupPasswordMismatch,
    };
  }

  Future<void> _create() async {
    final grant = _grant;
    if (grant == null) return;
    final issue = widget.coordinator.validateBackupPassword(
      _passwordController.text,
      _confirmController.text,
    );
    if (issue != null) {
      setState(() => _feedback = _passwordIssueText(issue));
      return;
    }
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final appVersion = await widget.appVersionLoader();
      final sealed = await widget.coordinator.createBackup(
        grant: grant,
        backupPassword: _passwordController.text,
        confirmation: _confirmController.text,
        appVersion: appVersion,
      );
      _passwordController.clear();
      _confirmController.clear();
      _sealed = sealed;
      _grant = null;
    } on VaultBackupNotAuthorizedException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _grant = null;
        _passwordController.clear();
        _confirmController.clear();
        _feedback = context.l10n.backupReauthExpired;
      });
      return;
    } on VaultBackupPasswordException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _feedback = _passwordIssueText(error.issue);
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _feedback = context.l10n.backupExportFailed;
      });
      return;
    }
    await _save();
  }

  Future<void> _save() async {
    final sealed = _sealed;
    if (sealed == null) return;
    if (!widget.securityController.isUnlocked) {
      // Never hand the backup to a save dialog once the vault locked.
      setState(() {
        _sealed = null;
        _grant = null;
        _feedback = context.l10n.backupReauthExpired;
      });
      return;
    }
    setState(() {
      _busy = true;
      _feedback = null;
    });
    final now = (widget.clock ?? DateTime.now)();
    // The save dialog takes the foreground; keep the vault unlocked
    // for the duration, as the import picker does.
    widget.securityController.beginLongRunningFlow();
    bool saved;
    try {
      saved = await widget.fileGateway.save(
        fileName: vaultBackupFileName(now),
        bytes: sealed,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _feedback = context.l10n.backupExportFailed;
        });
      }
      return;
    } finally {
      widget.securityController.endLongRunningFlow();
    }
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _feedback = context.l10n.backupSaveCancelled;
    });
  }
}
