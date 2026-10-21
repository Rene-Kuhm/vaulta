import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/vault_security_controller.dart';
import '../../security/presentation/unlock_throttle_text.dart';
import '../application/vault_backup_coordinator.dart';
import '../data/vault_backup_file_gateway.dart';
import '../domain/vault_clear_text_export.dart';

/// Two-step dialog that exports the vault as an **unencrypted** CSV or
/// JSON file, for migrating to another password manager.
///
/// (1) Re-enter the master password through the throttled
/// re-authentication path, exactly like the encrypted export.
/// (2) Read the warning that the file will be readable by anyone, pick
/// a format, tick the acknowledgement, and only then save.
///
/// The export button stays disabled until the acknowledgement is
/// ticked, and the coordinator refuses to render clear text without it,
/// so there is no silent path to an unencrypted file. The encrypted
/// `.vaulta` export is untouched and stays the default action.
///
/// Pops with `true` once the file was saved, `null` otherwise.
class VaultClearTextExportDialog extends StatefulWidget {
  /// Builds the dialog.
  const VaultClearTextExportDialog({
    super.key,
    required this.coordinator,
    required this.securityController,
    required this.fileGateway,
    required this.appVersionLoader,
    this.clock,
  });

  /// Coordinator that re-authenticates and renders the clear text.
  final VaultBackupCoordinator coordinator;

  /// Controller used for throttle feedback and to pause the background
  /// auto-lock while the system save dialog is open.
  final VaultSecurityController securityController;

  /// Writes the clear-text bytes to a user-chosen location.
  final VaultBackupFileGateway fileGateway;

  /// Resolves the app version recorded in the JSON metadata.
  final Future<String> Function() appVersionLoader;

  /// Clock for the suggested file name; defaults to [DateTime.now].
  final DateTime Function()? clock;

  @override
  State<VaultClearTextExportDialog> createState() =>
      _VaultClearTextExportDialogState();
}

class _VaultClearTextExportDialogState
    extends State<VaultClearTextExportDialog> {
  final _masterController = TextEditingController();
  VaultBackupExportGrant? _grant;
  int? _itemCount;
  Uint8List? _bytes;
  VaultClearTextFormat _format = VaultClearTextFormat.csv;
  bool _acknowledged = false;
  String? _feedback;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    // Drop the clear-text bytes and the grant with the dialog (the
    // SecurityGate pops it on lock).
    _bytes = null;
    _grant = null;
    _masterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final reauthStep = _grant == null && _bytes == null;

    final children = <Widget>[
      if (reauthStep) ...[
        Text(l10n.backupClearTextReauthBody),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          key: const Key('backup.exportClearText.masterPassword'),
          controller: _masterController,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          onSubmitted: (_) => _authorize(),
          decoration: InputDecoration(
            labelText: l10n.backupMasterPasswordLabel,
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
            ),
          ),
        ),
      ] else ...[
        if (_itemCount case final count?)
          Text(
            l10n.backupClearTextItemCount(count),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        AppBanner(
          key: const Key('backup.exportClearText.warning'),
          message: l10n.backupClearTextWarning,
          tone: AppBannerTone.danger,
          icon: Icons.lock_open_rounded,
        ),
        // Once the file is rendered the format cannot change, so the
        // choice and its acknowledgement are only shown before that.
        if (_bytes == null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.backupClearTextFormatLabel,
            style: theme.textTheme.labelLarge,
          ),
          RadioGroup<VaultClearTextFormat>(
            groupValue: _format,
            onChanged: _selectFormat,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<VaultClearTextFormat>(
                  key: const Key('backup.exportClearText.format.csv'),
                  value: VaultClearTextFormat.csv,
                  title: Text(l10n.backupClearTextFormatCsv),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                RadioListTile<VaultClearTextFormat>(
                  key: const Key('backup.exportClearText.format.json'),
                  value: VaultClearTextFormat.json,
                  title: Text(l10n.backupClearTextFormatJson),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
          ),
          CheckboxListTile(
            key: const Key('backup.exportClearText.acknowledge'),
            value: _acknowledged,
            onChanged: _busy
                ? null
                : (value) => setState(() => _acknowledged = value ?? false),
            title: Text(l10n.backupClearTextConfirm),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ],
      ],
      if (_feedback case final feedback?) ...[
        const SizedBox(height: AppSpacing.sm),
        AppBanner(
          key: const Key('backup.exportClearText.feedback'),
          message: feedback,
          tone: AppBannerTone.danger,
          icon: Icons.error_outline_rounded,
        ),
      ],
    ];

    final String primaryLabel;
    final VoidCallback? primaryAction;
    if (reauthStep) {
      primaryLabel = l10n.backupContinue;
      primaryAction = _busy ? null : _authorize;
    } else if (_bytes != null) {
      primaryLabel = l10n.backupSaveAgain;
      primaryAction = _busy ? null : _save;
    } else {
      primaryLabel = l10n.backupClearTextCreateAction;
      // No acknowledgement, no export: the button cannot be pressed.
      primaryAction = _busy || !_acknowledged ? null : _export;
    }

    return AlertDialog(
      title: Text(l10n.backupClearTextTitle),
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
          key: const Key('backup.exportClearText.primary'),
          onPressed: primaryAction,
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

  void _selectFormat(VaultClearTextFormat? format) {
    if (format == null) return;
    setState(() => _format = format);
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

  Future<void> _export() async {
    final grant = _grant;
    if (grant == null || !_acknowledged) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final appVersion = await widget.appVersionLoader();
      final bytes = await widget.coordinator.createClearTextExport(
        grant: grant,
        format: _format,
        acknowledgedUnencrypted: _acknowledged,
        appVersion: appVersion,
      );
      _bytes = bytes;
      _grant = null;
    } on VaultBackupNotAuthorizedException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _grant = null;
        _feedback = context.l10n.backupReauthExpired;
      });
      return;
    } on VaultClearTextExportNotConfirmedException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _acknowledged = false;
        _feedback = context.l10n.backupClearTextExportFailed;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _feedback = context.l10n.backupClearTextExportFailed;
      });
      return;
    }
    await _save();
  }

  Future<void> _save() async {
    final bytes = _bytes;
    if (bytes == null) return;
    if (!widget.securityController.isUnlocked) {
      // Never hand clear text to a save dialog once the vault locked.
      setState(() {
        _bytes = null;
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
    // The save dialog takes the foreground; keep the vault unlocked for
    // the duration, as the encrypted export and the import picker do.
    widget.securityController.beginLongRunningFlow();
    bool saved;
    try {
      saved = await widget.fileGateway.save(
        fileName: vaultClearTextFileName(now, _format),
        bytes: bytes,
        fileExtension: _format.fileExtension,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _feedback = context.l10n.backupClearTextExportFailed;
        });
      }
      return;
    } finally {
      widget.securityController.endLongRunningFlow();
    }
    if (!mounted) return;
    if (saved) {
      _bytes = null;
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _feedback = context.l10n.backupSaveCancelled;
    });
  }
}
