import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/design_system/vault_entry_tile.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/sensitive_clipboard_service.dart';
import '../../totp/presentation/totp_code_panel.dart';
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
    this.onToggleFavorite,
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

  /// Invoked when the user marks or unmarks this entry as a favorite.
  /// The argument is the requested new value of
  /// [VaultItem.isFavorite]; the dashboard persists it through the
  /// repository. When `null`, the favorite action is disabled (the
  /// preview case).
  final Future<void> Function(bool isFavorite)? onToggleFavorite;

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

  /// The entry as this screen currently shows it. Seeded from
  /// [VaultEntryDetailScreen.item] and updated in place when the user
  /// marks or unmarks it as a favorite, so the new state is visible
  /// without waiting for the dashboard to reload.
  late VaultItem _item = widget.item;

  late final SensitiveClipboardService _clipboard =
      widget.clipboardService ?? SensitiveClipboardService.shared;

  /// Indexes (in [VaultItem.passwordHistoryNewestFirst] order) of the
  /// previous passwords the user chose to reveal. Empty by default so
  /// old secrets stay masked until asked for.
  final Set<int> _revealedHistory = <int>{};

  @override
  void didUpdateWidget(covariant VaultEntryDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The dashboard re-reads the vault after an edit, so a rebuilt
    // screen receives the stored item and must not keep showing the
    // previous one.
    if (oldWidget.item != widget.item) {
      _item = widget.item;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final item = _item;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(l10n.entryDetailTitle),
        actions: [
          IconButton(
            onPressed: widget.onToggleFavorite == null ? null : _toggleFavorite,
            icon: Icon(
              item.isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              color: item.isFavorite ? AppColors.warning : null,
            ),
            tooltip: item.isFavorite
                ? l10n.entryUnmarkFavoriteTooltip
                : l10n.entryMarkFavoriteTooltip,
          ),
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
                            Wrap(
                              spacing: AppSpacing.xs,
                              runSpacing: AppSpacing.xxs,
                              children: [
                                AppPill(
                                  label: item.category.label,
                                  tint: _categoryTint(item.category),
                                  compact: true,
                                ),
                                if (item.isFavorite)
                                  AppPill(
                                    label: l10n.entryFavoriteLabel,
                                    tint: AppPillTint.warning,
                                    compact: true,
                                  ),
                              ],
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
                    // Plain Text on purpose: a selectable secret would get
                    // the platform toolbar (plain Copy without the
                    // sensitive flag or auto-clear, Share, Translate and
                    // other PROCESS_TEXT actions) and Ctrl+C on desktop.
                    // The Copy button below is the only copy path.
                    child: Text(
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
            if (item.passwordHistory.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _passwordHistoryPanel(context),
            ],
            if (item.otpAuthUri != null) ...[
              const SizedBox(height: AppSpacing.lg),
              TotpCodePanel(
                uri: item.otpAuthUri!,
                clipboardService: _clipboard,
              ),
            ],
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

  /// Collapsible list of the passwords this entry used to have, newest
  /// first. Only rendered when there is at least one entry, so an item
  /// whose password was never rotated looks exactly like before.
  Widget _passwordHistoryPanel(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final entries = _item.passwordHistoryNewestFirst;

    return AppPanel(
      child: ExpansionTile(
        title: Text(
          l10n.entryPasswordHistoryTitle,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          l10n.entryPasswordHistoryHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // Keep the panel chrome as the only border.
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: AppSpacing.xs),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, entry) in entries.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Plain Text on purpose, like the current secret:
                        // a selectable previous password would expose the
                        // platform's plain Copy/Share toolbar. The copy
                        // button below is the only copy path, and it goes
                        // through the sensitive clipboard service.
                        Text(
                          _revealedHistory.contains(index)
                              ? entry.secret
                              : _mask(entry.secret),
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: AppColors.paperDark,
                            letterSpacing: 0.6,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatReplacedAt(context, entry.replacedAt),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _toggleHistoryReveal(index),
                    tooltip: _revealedHistory.contains(index)
                        ? l10n.entryPasswordHistoryHideTooltip
                        : l10n.entryPasswordHistoryRevealTooltip,
                    icon: Icon(
                      _revealedHistory.contains(index)
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _copySecret(entry.secret),
                    tooltip: l10n.entryPasswordHistoryCopyTooltip,
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _toggleHistoryReveal(int index) {
    setState(() {
      if (!_revealedHistory.add(index)) {
        _revealedHistory.remove(index);
      }
    });
  }

  /// Localized date and time at which a previous password was replaced.
  String _formatReplacedAt(BuildContext context, DateTime replacedAt) {
    return DateFormat.yMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hm().format(replacedAt.toLocal());
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

  /// Flips [VaultItem.isFavorite] through the dashboard callback and
  /// applies it locally so the star, the pill, and the tooltip all
  /// reflect the saved value right away.
  Future<void> _toggleFavorite() async {
    final next = !_item.isFavorite;
    await widget.onToggleFavorite?.call(next);
    if (!mounted) {
      return;
    }
    setState(() => _item = _item.copyWith(isFavorite: next));
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
