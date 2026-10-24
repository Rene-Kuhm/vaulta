import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/vault_security_controller.dart';
import '../../vault/application/vault_backup_merger.dart';
import '../application/vault_backup_coordinator.dart';
import '../data/vault_backup_file_gateway.dart';
import 'vault_backup_export_dialog.dart';
import 'vault_backup_restore_screen.dart';
import 'vault_clear_text_export_dialog.dart';

/// Settings panel with the backup actions: export the vault to an
/// encrypted `.vaulta` file (the default, ADR-006), export an
/// unencrypted CSV/JSON file for migrating to another password manager,
/// and restore an encrypted backup.
class BackupSection extends StatelessWidget {
  /// Builds the section. [fileGateway] defaults to the `file_picker`
  /// implementation and [appVersionLoader] to `package_info_plus`.
  const BackupSection({
    super.key,
    required this.coordinator,
    required this.securityController,
    this.fileGateway = const FilePickerVaultBackupFileGateway(),
    this.appVersionLoader = loadAppVersion,
  });

  /// Coordinator shared by the export and restore flows.
  final VaultBackupCoordinator coordinator;

  /// Controller for throttle feedback and the auto-lock pause.
  final VaultSecurityController securityController;

  /// Platform file I/O for the sealed envelope.
  final VaultBackupFileGateway fileGateway;

  /// Resolves the app version written into the backup header.
  final Future<String> Function() appVersionLoader;

  /// Default [appVersionLoader]: `version+build` from the platform, or
  /// `unknown` when it cannot be read.
  static Future<String> loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.backupSectionTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.backupSectionSubtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              FilledButton.icon(
                key: const Key('backup.section.export'),
                onPressed: () => _export(context),
                icon: const Icon(Icons.file_download_rounded),
                label: Text(l10n.backupExportAction),
              ),
              OutlinedButton.icon(
                key: const Key('backup.section.exportClearText'),
                onPressed: () => _exportClearText(context),
                icon: const Icon(Icons.table_view_rounded),
                label: Text(l10n.backupExportClearTextAction),
              ),
              OutlinedButton.icon(
                key: const Key('backup.section.restore'),
                onPressed: () => _restore(context),
                icon: const Icon(Icons.settings_backup_restore_rounded),
                label: Text(l10n.backupRestoreAction),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final successText = context.l10n.backupExportSuccess;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => VaultBackupExportDialog(
        coordinator: coordinator,
        securityController: securityController,
        fileGateway: fileGateway,
        appVersionLoader: appVersionLoader,
      ),
    );
    if (saved == true) {
      messenger?.showSnackBar(SnackBar(content: Text(successText)));
    }
  }

  Future<void> _exportClearText(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final successText = context.l10n.backupClearTextSuccess;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => VaultClearTextExportDialog(
        coordinator: coordinator,
        securityController: securityController,
        fileGateway: fileGateway,
        appVersionLoader: appVersionLoader,
      ),
    );
    if (saved == true) {
      messenger?.showSnackBar(SnackBar(content: Text(successText)));
    }
  }

  Future<void> _restore(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    final result = await Navigator.of(context).push<VaultBackupMergeResult>(
      MaterialPageRoute(
        builder: (_) => VaultBackupRestoreScreen(
          coordinator: coordinator,
          securityController: securityController,
          fileGateway: fileGateway,
        ),
      ),
    );
    if (result != null) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.backupRestoreSuccess(result.imported))),
      );
    }
  }
}
