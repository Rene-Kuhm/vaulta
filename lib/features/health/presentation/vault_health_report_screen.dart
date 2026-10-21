import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/design_system/vault_entry_tile.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/vault_repository.dart';
import '../../vault/domain/vault_item.dart';
import '../../vault/presentation/vault_entry_detail_screen.dart';
import '../application/vault_health_report_builder.dart';
import '../domain/vault_health_report.dart';
import 'vault_health_copy.dart';

/// Bitwarden-style vault health report: what the dashboard's score
/// hides, broken into the entries a user can act on.
///
/// Reads everything through the injected [VaultRepository], so the
/// screen needs no platform channels and is widget-testable with a
/// fake repository. Numbers come from `fetchSummary`; the weak and
/// shared-secret lists come from `fetchItems`. Tapping an entry opens
/// [VaultEntryDetailScreen] in read-only mode: fixing an entry stays
/// a job for the vault tab.
class VaultHealthReportScreen extends StatefulWidget {
  /// Builds the report screen. [repository] is the only dependency.
  const VaultHealthReportScreen({super.key, required this.repository});

  /// Vault repository used to read the summary and the entries.
  final VaultRepository repository;

  @override
  State<VaultHealthReportScreen> createState() =>
      _VaultHealthReportScreenState();
}

class _VaultHealthReportScreenState extends State<VaultHealthReportScreen> {
  late Future<VaultHealthReport> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<VaultHealthReport> _load() async {
    final summary = await widget.repository.fetchSummary();
    final items = await widget.repository.fetchItems();
    return buildVaultHealthReport(summary: summary, items: items);
  }

  void _refresh() {
    setState(() {
      _future = _load();
    });
  }

  void _openEntry(VaultItem item) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => VaultEntryDetailScreen(item: item),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(VaultHealthCopy.title),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
            // Reuses the existing "Refresh" key; this change may not add
            // keys to lib/l10n.
            tooltip: l10n.settingsConflictsRefresh,
          ),
        ],
      ),
      body: AppHeroBackground(
        intensity: 0.65,
        child: SafeArea(bottom: false, child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = context.l10n;

    return FutureBuilder<VaultHealthReport>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          );
        }

        if (snapshot.hasError) {
          return _HealthError(
            title: l10n.dashboardDecryptError,
            advice: l10n.dashboardDecryptErrorAdvice,
            retryLabel: l10n.retry,
            onRetry: _refresh,
          );
        }

        final report = snapshot.data!;
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xxxl,
            ),
            children: [
              _NumbersPanel(report: report),
              const SizedBox(height: AppSpacing.lg),
              if (report.isHealthy)
                _HealthyPanel(totalItems: report.totalItems)
              else ...[
                if (report.weakEntries.isNotEmpty) ...[
                  _WeakEntriesPanel(
                    entries: report.weakEntries,
                    onOpenEntry: _openEntry,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
                if (report.sharedSecretGroups.isNotEmpty)
                  _SharedSecretsPanel(
                    groups: report.sharedSecretGroups,
                    onOpenEntry: _openEntry,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _NumbersPanel extends StatelessWidget {
  const _NumbersPanel({required this.report});

  final VaultHealthReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppSectionHeader(
            eyebrow: VaultHealthCopy.eyebrow,
            title: VaultHealthCopy.numbersTitle,
            subtitle: VaultHealthCopy.numbersSubtitle,
          ),
          const SizedBox(height: AppSpacing.md),
          _HealthMetricRow(
            icon: Icons.lock_open_rounded,
            tint: AppColors.crimsonBright,
            label: l10n.vaultEntries,
            value: '${report.totalItems}',
            explanation: VaultHealthCopy.totalItemsExplanation,
          ),
          const Divider(height: AppSpacing.lg),
          _HealthMetricRow(
            icon: Icons.warning_amber_rounded,
            tint: AppColors.warning,
            label: l10n.weakPasswords,
            value: '${report.weakItems}',
            explanation: VaultHealthCopy.weakItemsExplanation,
          ),
          const Divider(height: AppSpacing.lg),
          _HealthMetricRow(
            icon: Icons.copy_all_rounded,
            tint: AppColors.danger,
            label: l10n.reusedItems,
            value: '${report.reusedItems}',
            explanation: VaultHealthCopy.reusedItemsExplanation,
          ),
          const Divider(height: AppSpacing.lg),
          _HealthMetricRow(
            icon: Icons.speed_rounded,
            tint: AppColors.success,
            label: l10n.securityScore,
            value: '${report.securityScore}',
            explanation: VaultHealthCopy.securityScoreExplanation,
          ),
        ],
      ),
    );
  }
}

class _HealthMetricRow extends StatelessWidget {
  const _HealthMetricRow({
    required this.icon,
    required this.tint,
    required this.label,
    required this.value,
    required this.explanation,
  });

  final IconData icon;
  final Color tint;
  final String label;
  final String value;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          child: Icon(icon, color: tint, size: 20),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                explanation,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          value,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _WeakEntriesPanel extends StatelessWidget {
  const _WeakEntriesPanel({required this.entries, required this.onOpenEntry});

  final List<VaultItem> entries;
  final ValueChanged<VaultItem> onOpenEntry;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppSectionHeader(
            title: VaultHealthCopy.weakSectionTitle,
            subtitle: VaultHealthCopy.weakSectionSubtitle,
          ),
          const SizedBox(height: AppSpacing.md),
          for (var index = 0; index < entries.length; index++) ...[
            VaultEntryTile(
              item: entries[index],
              onTap: () => onOpenEntry(entries[index]),
            ),
            if (index != entries.length - 1)
              const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _SharedSecretsPanel extends StatelessWidget {
  const _SharedSecretsPanel({required this.groups, required this.onOpenEntry});

  final List<SharedSecretGroup> groups;
  final ValueChanged<VaultItem> onOpenEntry;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppSectionHeader(
            title: VaultHealthCopy.sharedSectionTitle,
            subtitle: VaultHealthCopy.sharedSectionSubtitle,
          ),
          const SizedBox(height: AppSpacing.md),
          for (
            var groupIndex = 0;
            groupIndex < groups.length;
            groupIndex++
          ) ...[
            _SharedSecretBadge(
              label: VaultHealthCopy.sharedGroupLabel(
                groups[groupIndex].entryCount,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (
              var itemIndex = 0;
              itemIndex < groups[groupIndex].items.length;
              itemIndex++
            ) ...[
              VaultEntryTile(
                item: groups[groupIndex].items[itemIndex],
                onTap: () => onOpenEntry(groups[groupIndex].items[itemIndex]),
              ),
              if (itemIndex != groups[groupIndex].items.length - 1)
                const SizedBox(height: AppSpacing.sm),
            ],
            if (groupIndex != groups.length - 1)
              const SizedBox(height: AppSpacing.lg),
          ],
        ],
      ),
    );
  }
}

/// Pill naming one shared-secret group.
///
/// Deliberately not `AppPill`: that widget lays its label out at its
/// natural width, so a long label (or a large accessibility text
/// scale) overflows the row. The label here is flexible and
/// ellipsizes instead. The tokens match `AppPill`'s crimson tint.
class _SharedSecretBadge extends StatelessWidget {
  const _SharedSecretBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final foreground = isDark ? AppColors.crimsonBright : AppColors.crimson;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.crimson.withValues(alpha: isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
        border: Border.all(
          color: AppColors.crimson.withValues(alpha: isDark ? 0.35 : 0.28),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_rounded, size: 14, color: foreground),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthyPanel extends StatelessWidget {
  const _HealthyPanel({required this.totalItems});

  final int totalItems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
            child: const Icon(
              Icons.verified_user_rounded,
              color: AppColors.success,
              size: 28,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            VaultHealthCopy.healthyTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            totalItems == 0
                ? VaultHealthCopy.emptyVaultBody
                : VaultHealthCopy.healthyBody,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthError extends StatelessWidget {
  const _HealthError({
    required this.title,
    required this.advice,
    required this.retryLabel,
    required this.onRetry,
  });

  final String title;
  final String advice;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
              ),
              child: const Icon(
                Icons.lock_reset_rounded,
                size: 40,
                color: AppColors.danger,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              advice,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
