import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/design_system/vault_entry_tile.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/sensitive_clipboard_service.dart';
import '../domain/vault_item.dart';

/// Read-only detail view for a single [VaultItem].
///
/// Allows the user to reveal the secret, copy it to the clipboard
/// (auto-cleared after 30s), and either edit or delete the entry
/// through the optional [onEdit] / [onDelete] callbacks.
/// Read-only detail view for a single [VaultItem].
///
/// Allows the user to reveal the secret, copy it to the clipboard
/// (auto-cleared after 30s), and either edit or delete the entry
/// through the optional [onEdit] / [onDelete] callbacks.
class VaultEntryDetailScreen extends StatefulWidget {
  /// Builds the detail screen. [item] is required; [onEdit] and
  /// [onDelete] are optional so the screen is also usable as a
  /// preview widget (for example, in onboarding screenshots).
  const VaultEntryDetailScreen({
    super.key,
    required this.item,
    this.onEdit,
    this.onDelete,
    this.clipboardService,
  });

  /// The entry being shown. The screen does not mutate it directly;
  /// edits flow through the [onEdit] callback.
  final VaultItem item;

  /// Invoked when the user taps the edit action. The returned
  /// `true` value signals the dashboard that the entry changed and
  /// the list should be refreshed.
  final Future<bool> Function()? onEdit;

  /// Invoked when the user confirms the delete action.
  final Future<void> Function()? onDelete;

  /// Writes copied secrets to the clipboard flagged as sensitive.
  /// Defaults to [SensitiveClipboardService.shared], the instance the
  /// security controller also clears on lock; tests can inject their
  /// own.
  final SensitiveClipboardService? clipboardService;

  @override
  State<VaultEntryDetailScreen> createState() => _VaultEntryDetailScreenState();
}

class _VaultEntryDetailScreenState extends State<VaultEntryDetailScreen> {
  bool _obscureSecret = true;
  late final SensitiveClipboardService _clipboard =
      widget.clipboardService ?? SensitiveClipboardService.shared;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final item = widget.item;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(l10n.entryDetailTitle),
        actions: [
          IconButton(
            onPressed: widget.onEdit == null ? null : _runEdit,
            icon: const Icon(Icons.edit_rounded),
            tooltip: l10n.entryEditTooltip,
          ),
          IconButton(
            onPressed: widget.onDelete == null ? null : _confirmDelete,
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: l10n.entryDeleteTooltip,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          children: [
            AppPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: item.accentColor.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(
                            AppSpacing.radiusMd,
                          ),
                        ),
                        child: Icon(
                          item.icon,
                          color: item.accentColor,
                          size: 30,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            AppPill(
                              label: item.category.label,
                              tint: _categoryTint(item.category),
                              compact: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _MetaRow(
                    label: l10n.entryUsernameLabel,
                    value: item.username,
                  ),
                  if (item.website != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _MetaRow(
                      label: l10n.entryWebsiteLabel,
                      value: item.website!,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _MetaRow(
                    label: l10n.entryStrengthLabel,
                    value: '${item.strengthScore}%',
                    trailing: StrengthBadge(score: item.strengthScore),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _MetaRow(
                    label: l10n.entryUpdatedLabel,
                    value: item.lastUpdatedLabel,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.entrySecretTitle,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          setState(() => _obscureSecret = !_obscureSecret);
                        },
                        icon: Icon(
                          _obscureSecret
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                        label: Text(
                          _obscureSecret
                              ? l10n.entryShowSecret
                              : l10n.entryHideSecret,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundDark,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                      border: Border.all(color: AppColors.borderDark),
                    ),
                    child: SelectableText(
                      _obscureSecret ? _mask(item.secret) : item.secret,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: AppColors.paperDark,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  OutlinedButton.icon(
                    onPressed: () => _copySecret(item.secret),
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(context.l10n.copySecret),
                  ),
                ],
              ),
            ),
            if (item.notes != null) ...[
              const SizedBox(height: AppSpacing.lg),
              AppPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.entryNotesTitle,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      item.notes!,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  AppPillTint _categoryTint(VaultCategory c) {
    return switch (c) {
      VaultCategory.work => AppPillTint.crimson,
      VaultCategory.finance => AppPillTint.success,
      VaultCategory.personal => AppPillTint.warning,
      VaultCategory.infrastructure => AppPillTint.danger,
    };
  }

  String _mask(String secret) {
    if (secret.length <= 4) {
      return List.filled(secret.length, '*').join();
    }
    final hidden = List.filled(secret.length - 4, '*').join();
    return '$hidden${secret.substring(secret.length - 4)}';
  }

  Future<void> _runEdit() async {
    final changed = await widget.onEdit?.call() ?? false;
    if (changed && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _copySecret(String secret) async {
    // The service owns the 30 s "clear if unchanged" timer, so it keeps
    // running after this screen closes and also works in background.
    await _clipboard.copySensitive(secret, onAutoCleared: _showCleared);

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.secretCopiedLocally)));
  }

  void _showCleared() {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.clipboardCleared)));
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.entryDeleteDialogTitle),
          content: Text(context.l10n.entryDeleteDialogBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.l10n.entryDeleteConfirm),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    await widget.onDelete?.call();
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.label,
    required this.value,
    this.trailing,
  });

  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}
