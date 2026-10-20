import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/vault_backup_service.dart';
import '../../../core/security/vault_security_controller.dart';
import '../../vault/application/vault_backup_merger.dart';
import '../application/vault_backup_coordinator.dart';
import '../data/vault_backup_file_gateway.dart';

/// Restores a `.vaulta` backup: pick the file, enter the backup
/// password, review what will be added, then merge through the normal
/// repository save path. Nothing is written before the user confirms.
///
/// Kept separate from the CSV/JSON import screen because opening a
/// backup needs a password and an asynchronous, authenticated
/// decryption step that the plaintext parsers do not have.
///
/// Pops with the [VaultBackupMergeResult] after a restore, `null`
/// otherwise.
class VaultBackupRestoreScreen extends StatefulWidget {
  /// Builds the screen.
  const VaultBackupRestoreScreen({
    super.key,
    required this.coordinator,
    required this.securityController,
    required this.fileGateway,
  });

  /// Coordinator that decrypts, plans and applies the merge.
  final VaultBackupCoordinator coordinator;

  /// Controller used to pause the background auto-lock while the
  /// system file picker is open.
  final VaultSecurityController securityController;

  /// Lets the user pick the backup file.
  final VaultBackupFileGateway fileGateway;

  @override
  State<VaultBackupRestoreScreen> createState() =>
      _VaultBackupRestoreScreenState();
}

class _VaultBackupRestoreScreenState extends State<VaultBackupRestoreScreen> {
  final _passwordController = TextEditingController();
  String? _fileName;
  Uint8List? _bytes;
  VaultBackupRestorePreview? _preview;
  String? _error;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    // Drop the decrypted preview with the screen (the SecurityGate pops
    // it on lock).
    _preview = null;
    _bytes = null;
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final preview = _preview;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: Text(l10n.backupRestoreTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            AppPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.backupRestoreIntro,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  OutlinedButton.icon(
                    key: const Key('backup.restore.pick'),
                    onPressed: _busy ? null : _pick,
                    icon: const Icon(Icons.upload_file_rounded),
                    label: Text(l10n.backupPickFile),
                  ),
                  if (_fileName case final name?) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(name, style: theme.textTheme.bodySmall),
                  ],
                  if (_bytes != null && preview == null) ...[
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      key: const Key('backup.restore.password'),
                      controller: _passwordController,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      onSubmitted: (_) => _open(),
                      decoration: InputDecoration(
                        labelText: l10n.backupPasswordLabel,
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
                    const SizedBox(height: AppSpacing.sm),
                    FilledButton.icon(
                      key: const Key('backup.restore.open'),
                      onPressed: _busy ? null : _open,
                      icon: const Icon(Icons.lock_open_rounded),
                      label: Text(l10n.backupUnlockAction),
                    ),
                  ],
                  if (_error case final error?) ...[
                    const SizedBox(height: AppSpacing.md),
                    AppBanner(
                      key: const Key('backup.restore.error'),
                      message: error,
                      tone: AppBannerTone.danger,
                      icon: Icons.error_outline_rounded,
                    ),
                  ],
                  if (_busy) ...[
                    const SizedBox(height: AppSpacing.md),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
            if (preview != null) ...[
              const SizedBox(height: AppSpacing.lg),
              _PreviewPanel(preview: preview),
            ],
          ],
        ),
      ),
      bottomNavigationBar: preview == null
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: FilledButton.icon(
                key: const Key('backup.restore.confirm'),
                onPressed: _busy || preview.plan.importCount == 0
                    ? null
                    : _restore,
                icon: const Icon(Icons.lock_rounded),
                label: Text(
                  preview.plan.importCount == 0
                      ? l10n.backupRestoreNothing
                      : l10n.backupRestoreConfirm(preview.plan.importCount),
                ),
              ),
            ),
    );
  }

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.securityController.beginLongRunningFlow();
    VaultBackupPickedFile? picked;
    VaultBackupException? invalid;
    var pickFailed = false;
    try {
      picked = await widget.fileGateway.pick();
      if (picked != null) {
        // Early, unauthenticated sanity check so an obviously wrong
        // file is reported before the user types a password.
        widget.coordinator.readHeader(picked.bytes);
      }
    } on VaultBackupException catch (failure) {
      invalid = failure;
      picked = null;
    } catch (_) {
      pickFailed = true;
      picked = null;
    } finally {
      widget.securityController.endLongRunningFlow();
    }
    if (!mounted) return;
    final error = invalid != null
        ? _openErrorText(invalid)
        : (pickFailed ? context.l10n.backupPickFailed : null);
    setState(() {
      _busy = false;
      _error = error;
      if (picked != null || error != null) {
        _fileName = picked?.name;
        _bytes = picked?.bytes;
        _preview = null;
        _passwordController.clear();
      }
    });
  }

  Future<void> _open() async {
    final bytes = _bytes;
    if (bytes == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await widget.coordinator.previewRestore(
        bytes: bytes,
        backupPassword: _passwordController.text,
      );
      if (!mounted) return;
      _passwordController.clear();
      setState(() {
        _busy = false;
        _preview = preview;
      });
    } on VaultBackupException catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _openErrorText(failure);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = context.l10n.backupOpenFailed;
      });
    }
  }

  Future<void> _restore() async {
    final preview = _preview;
    if (preview == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.coordinator.applyRestore(
        preview: preview,
        conflictSuffix: context.l10n.backupConflictSuffix,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on VaultBackupNotAuthorizedException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = context.l10n.backupRestoreLocked;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = context.l10n.backupRestoreFailed;
      });
    }
  }

  /// One generic message for wrong password, tampering and malformed
  /// files (no oracle about which check failed); only a newer format
  /// version gets its own actionable text.
  String _openErrorText(VaultBackupException failure) {
    return failure.failure == VaultBackupFailure.unsupportedVersion
        ? context.l10n.backupUnsupportedVersion
        : context.l10n.backupOpenFailed;
  }
}

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({required this.preview});

  final VaultBackupRestorePreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final plan = preview.plan;
    final createdAt = DateFormat.yMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hm().format(preview.contents.header.createdAt.toLocal());

    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionHeader(
            title: l10n.backupPreviewTitle,
            subtitle: l10n.backupPreviewCreatedAt(createdAt),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.backupPreviewSummary(
              plan.entries.length,
              plan.newCount,
              plan.conflictCount,
              plan.duplicateCount,
            ),
            key: const Key('backup.restore.summary'),
            style: theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
