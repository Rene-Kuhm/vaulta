// ignore_for_file: prefer_const_constructors, unawaited_futures

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/design_system/metric_card.dart';
import '../../../app/design_system/vault_entry_tile.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/vault_repository.dart';
import '../../../core/sync/sync_conflict_resolver.dart';
import '../../../core/sync/vault_change_signal.dart';
import '../../health/presentation/vault_health_copy.dart';
import '../../health/presentation/vault_health_report_screen.dart';
import '../../sync/presentation/sync_conflicts_sheet.dart';
import '../application/vault_import_models.dart';
import '../domain/vault_item.dart';
import '../../../core/security/vault_security_controller.dart';
import '../domain/vault_summary.dart';
import 'vault_entry_detail_screen.dart';
import 'vault_entry_editor_screen.dart';
import 'vault_import_screen.dart';

/// Everything the dashboard renders, loaded in one repository round trip.
typedef _DashboardData = ({VaultSummary summary, List<VaultItem> items});

/// Top-level "Vault" tab: shows the [VaultSummary] hero, the metric
/// grid, quick actions, and the searchable/filterable entry list.
///
/// Owns the entry-creation, import, and detail flows via
/// [Navigator.push]. Also surfaces the sync conflict count banner
/// when [conflictResolver] is provided.
/// Top-level "Vault" tab: shows the [VaultSummary] hero, the metric
/// grid, quick actions, and the searchable/filterable entry list.
///
/// Owns the entry-creation, import, and detail flows via
/// [Navigator.push]. Also surfaces the sync conflict count banner
/// when [conflictResolver] is provided.
class VaultDashboardScreen extends StatefulWidget {
  /// Builds the dashboard. [repository] is the only required
  /// dependency. [conflictResolver] enables the conflict banner
  /// and [securityController] allows the dashboard to pause the
  /// auto-lock during long flows (import, biometric prompt).
  const VaultDashboardScreen({
    super.key,
    required this.repository,
    this.conflictResolver,
    this.securityController,
    this.vaultChanges,
  });

  /// Vault repository used to load the summary, entries, and
  /// persist new/edited entries.
  final VaultRepository repository;

  /// Optional resolver for sync conflicts. When provided, the
  /// dashboard shows a banner with the pending conflict count.
  final SyncConflictResolver? conflictResolver;

  /// Optional controller used to pause auto-lock while a long
  /// flow (import, biometric prompt) is in progress.
  final VaultSecurityController? securityController;

  /// Optional signal the sync layer publishes when it changed the vault
  /// without the user acting here (a pull applied remote snapshots, or a
  /// remote vault-key was adopted). The dashboard re-reads the repository on
  /// every event, which is what makes a pulled entry appear without a
  /// pull-to-refresh or a restart.
  ///
  /// The event carries no vault content (see [VaultChangeSignal]), so the
  /// reload is an unconditional repository read and never a per-item patch.
  /// When this is `null` the dashboard keeps working exactly as before —
  /// explicit refresh only. It never polls: there is no timer anywhere in
  /// this path.
  final VaultChangeSignal? vaultChanges;

  @override
  State<VaultDashboardScreen> createState() => _VaultDashboardScreenState();
}

class _VaultDashboardScreenState extends State<VaultDashboardScreen> {
  late Future<_DashboardData> _future;
  // Last successfully loaded vault. Kept so a background reload (triggered by
  // a sync change) does not flash a spinner over data the user is reading.
  _DashboardData? _lastData;
  late final TextEditingController _searchController;
  String _searchQuery = '';
  _VaultFilter _activeFilter = _VaultFilter.all;
  int _pendingConflicts = 0;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _future = _load();
    _loadConflictCount();
    widget.vaultChanges?.addListener(_onVaultChanged);
  }

  @override
  void didUpdateWidget(covariant VaultDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vaultChanges != widget.vaultChanges) {
      oldWidget.vaultChanges?.removeListener(_onVaultChanged);
      widget.vaultChanges?.addListener(_onVaultChanged);
    }
  }

  /// Re-reads the repository because the vault changed behind the UI. The
  /// signal only says "something changed", so the whole dashboard state is
  /// re-derived from the repository — no per-item patching, no secrets in
  /// flight.
  ///
  /// Re-reading a locked vault would only produce a decrypt error, so the
  /// event is dropped in that case; the unlock path loads the dashboard
  /// from scratch anyway.
  void _onVaultChanged() {
    if (!mounted) return;
    final controller = widget.securityController;
    if (controller != null && !controller.isUnlocked) return;
    _refresh();
  }

  Future<void> _loadConflictCount() async {
    final resolver = widget.conflictResolver;
    if (resolver == null) return;
    try {
      final conflicts = await resolver.readPendingConflicts();
      if (mounted) {
        setState(() => _pendingConflicts = conflicts.length);
      }
    } catch (error, stack) {
      debugPrint('[Vaulta/Sync] conflict count failed: $error\n$stack');
      if (mounted) {
        setState(() => _pendingConflicts = 0);
      }
    }
  }

  @override
  void dispose() {
    widget.vaultChanges?.removeListener(_onVaultChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return FutureBuilder<_DashboardData>(
      future: _future,
      initialData: _lastData,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            body: const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          );
        }

        if (snapshot.hasError) {
          return _DashboardError(
            onRetry: _refresh,
            title: l10n.dashboardDecryptError,
            advice: l10n.dashboardDecryptErrorAdvice,
            retryLabel: l10n.retry,
          );
        }

        final data = snapshot.data!;
        final filteredItems = _applyFilters(data.items);

        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _createEntry,
            icon: const Icon(Icons.add_rounded),
            label: Text(l10n.newEntry),
          ),
          body: AppHeroBackground(
            intensity: 0.65,
            child: SafeArea(
              bottom: false,
              child: RefreshIndicator(
                onRefresh: () async => _refresh(),
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.xxxl + AppSpacing.lg,
                      ),
                      sliver: SliverList.list(
                        children: [
                          _DashboardHeader(summary: data.summary),
                          const SizedBox(height: AppSpacing.lg),
                          if (_pendingConflicts > 0 &&
                              widget.conflictResolver != null)
                            _ConflictBanner(
                              count: _pendingConflicts,
                              onTap: () async {
                                await showSyncConflictsSheet(
                                  context: context,
                                  resolver: widget.conflictResolver!,
                                );
                                _loadConflictCount();
                              },
                            ),
                          if (_pendingConflicts > 0 &&
                              widget.conflictResolver != null)
                            const SizedBox(height: AppSpacing.md),
                          _MetricsGrid(summary: data.summary),
                          const SizedBox(height: AppSpacing.lg),
                          _QuickActions(
                            summary: data.summary,
                            onCreateEntry: _createEntry,
                            onImportEntries: () =>
                                _importEntries(existingItems: data.items),
                            onOpenHealthReport: _openHealthReport,
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          _VaultSection(
                            items: filteredItems,
                            totalItems: data.items.length,
                            searchController: _searchController,
                            activeFilter: _activeFilter,
                            onSearchChanged: (value) {
                              setState(() => _searchQuery = value);
                            },
                            onFilterChanged: (value) {
                              setState(() => _activeFilter = value);
                            },
                            onClearFilters: _clearFilters,
                            onOpenEntry: _openEntry,
                            onCreateEntry: _createEntry,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<_DashboardData> _load() async {
    final summary = await widget.repository.fetchSummary();
    final items = await widget.repository.fetchItems();
    final data = (summary: summary, items: items);
    _lastData = data;
    return data;
  }

  void _refresh() {
    setState(() {
      _future = _load();
    });
    _loadConflictCount();
  }

  List<VaultItem> _applyFilters(List<VaultItem> items) {
    final query = _searchQuery.trim().toLowerCase();

    return items
        .where((item) {
          final matchesQuery =
              query.isEmpty ||
              item.title.toLowerCase().contains(query) ||
              item.username.toLowerCase().contains(query) ||
              (item.website?.toLowerCase().contains(query) ?? false);

          final matchesFilter = switch (_activeFilter) {
            _VaultFilter.all => true,
            _VaultFilter.weak => item.strengthScore < 60,
            _VaultFilter.favorites => item.isFavorite,
            _VaultFilter.withNotes =>
              item.notes != null && item.notes!.trim().isNotEmpty,
          };

          return matchesQuery && matchesFilter;
        })
        .toList(growable: false);
  }

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _searchQuery = '';
      _activeFilter = _VaultFilter.all;
    });
  }

  Future<void> _createEntry() async {
    final draft = await Navigator.of(context).push<VaultItem>(
      MaterialPageRoute(builder: (_) => const VaultEntryEditorScreen()),
    );

    if (draft == null) {
      return;
    }

    await widget.repository.saveItem(draft);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.entryCreatedMessage)));
    _refresh();
  }

  Future<void> _importEntries({required List<VaultItem> existingItems}) async {
    final result = await Navigator.of(context).push<VaultImportResult>(
      MaterialPageRoute(
        builder: (_) => VaultImportScreen(
          repository: widget.repository,
          existingItems: existingItems,
          securityController: widget.securityController,
        ),
      ),
    );

    if (result == null || !mounted) {
      return;
    }
    final duplicateText = result.skippedDuplicates > 0
        ? ' ${result.skippedDuplicates} duplicadas omitidas.'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Importacion completa: ${result.imported} entradas.$duplicateText',
        ),
      ),
    );
    _refresh();
  }

  Future<void> _openEntry(VaultItem item) async {
    // The detail screen owns the entry while it is open (a favorite
    // toggle changes it), so both callbacks below work from the value
    // the detail screen hands back instead of the one captured here.
    // Otherwise editing right after marking a favorite would reopen the
    // stale entry and save the favorite away again.
    var current = item;
    // A favorite toggle persists through this callback, so the return
    // value of the pushed route is not enough to know whether the vault
    // changed: the dashboard re-reads the repository when either one
    // reports a change.
    var favoriteChanged = false;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => VaultEntryDetailScreen(
          item: item,
          onEdit: (VaultItem editBase) async {
            current = editBase;
            final updated = await Navigator.of(context).push<VaultItem>(
              MaterialPageRoute(
                builder: (_) =>
                    VaultEntryEditorScreen(initialItem: editBase),
              ),
            );
            if (updated == null) {
              return false;
            }
            await widget.repository.saveItem(updated);
            current = updated;
            return true;
          },
          onDelete: () => widget.repository.deleteItem(current.id),
          onToggleFavorite: (isFavorite) async {
            current = current.copyWith(isFavorite: isFavorite);
            await widget.repository.saveItem(current);
            favoriteChanged = true;
          },
        ),
      ),
    );

    if (!mounted) {
      return;
    }
    if (changed == true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.vaultUpdatedMessage)));
    }
    if (changed == true || favoriteChanged) {
      _refresh();
    }
  }

  Future<void> _openHealthReport() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VaultHealthReportScreen(repository: widget.repository),
      ),
    );
  }
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({
    required this.onRetry,
    required this.title,
    required this.advice,
    required this.retryLabel,
  });

  final VoidCallback onRetry;
  final String title;
  final String advice;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
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
                  child: Icon(
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
        ),
      ),
    );
  }
}

class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AppBanner(
      message: l10n.syncConflictsBannerLabel(count),
      icon: Icons.sync_problem_rounded,
      tone: AppBannerTone.warning,
      action: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          minimumSize: const Size(0, 36),
        ),
        child: Text(l10n.syncConflictsBannerAction),
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({required this.summary});

  final VaultSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const VaultaLogomark(size: 40),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    l10n.appTitle.toUpperCase(),
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3.0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                l10n.dashboardSubtitle,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        _ScoreRing(score: summary.securityScore),
      ],
    );
  }
}

class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score});
  final int score;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final color = score >= 80
        ? AppColors.success
        : (score >= 60 ? AppColors.warning : AppColors.danger);
    return SizedBox(
      width: 88,
      height: 88,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: score / 100,
              strokeWidth: 6,
              backgroundColor: AppColors.surfaceDarkHigh.withValues(alpha: 0.4),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$score',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
              Text(
                l10n.securityScore.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 0.6,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.summary});
  final VaultSummary summary;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: AppSpacing.md,
      crossAxisSpacing: AppSpacing.md,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.3,
      children: [
        MetricCard(
          label: context.l10n.vaultEntries,
          value: '${summary.totalItems}',
          icon: Icons.lock_open_rounded,
          tint: AppColors.crimsonBright,
        ),
        MetricCard(
          label: context.l10n.weakPasswords,
          value: '${summary.weakItems}',
          icon: Icons.warning_amber_rounded,
          tint: AppColors.warning,
        ),
        MetricCard(
          label: context.l10n.reusedItems,
          value: '${summary.reusedItems}',
          icon: Icons.copy_all_rounded,
          tint: AppColors.danger,
        ),
        MetricCard(
          label: context.l10n.trustedDevices,
          value: '${summary.connectedDevices}',
          icon: Icons.devices_rounded,
          tint: AppColors.success,
        ),
      ],
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.summary,
    required this.onCreateEntry,
    required this.onImportEntries,
    required this.onOpenHealthReport,
  });
  final VaultSummary summary;
  final Future<void> Function() onCreateEntry;
  final Future<void> Function() onImportEntries;
  final Future<void> Function() onOpenHealthReport;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionHeader(
            eyebrow: l10n.dashboardQuickActionsEyebrow,
            title: l10n.priorityActions,
            subtitle: l10n.dashboardQuickActionsSummary,
          ),
          const SizedBox(height: AppSpacing.md),
          _QuickActionRow(
            icon: Icons.health_and_safety_rounded,
            tint: AppColors.success,
            title: VaultHealthCopy.title,
            subtitle: VaultHealthCopy.entryPointSubtitle,
            onTap: onOpenHealthReport,
          ),
          const Divider(height: AppSpacing.lg),
          _QuickActionRow(
            icon: Icons.add_moderator_rounded,
            tint: AppColors.crimsonBright,
            title: l10n.createEncryptedEntry,
            subtitle: l10n.createEncryptedEntrySubtitle,
            onTap: onCreateEntry,
          ),
          const Divider(height: AppSpacing.lg),
          _QuickActionRow(
            icon: Icons.upload_file_rounded,
            tint: AppColors.success,
            title: 'Importar desde CSV o JSON',
            subtitle:
                'Adapta exportaciones de Notion, Chrome, Bitwarden, 1Password, LastPass, KeePass, Excel y Sheets.',
            onTap: onImportEntries,
          ),
          const Divider(height: AppSpacing.lg),
          _QuickActionRow(
            icon: Icons.manage_search_rounded,
            tint: AppColors.warning,
            title: l10n.planNextHardeningStep,
            subtitle: summary.syncEnabled
                ? l10n.dashboardRoadmapSyncEnabled
                : l10n.dashboardRoadmapSyncDisabled,
            onTap: null,
          ),
        ],
      ),
    );
  }
}

class _QuickActionRow extends StatelessWidget {
  const _QuickActionRow({
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: Icon(icon, color: tint, size: 22),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _VaultSection extends StatelessWidget {
  const _VaultSection({
    required this.items,
    required this.totalItems,
    required this.searchController,
    required this.activeFilter,
    required this.onSearchChanged,
    required this.onFilterChanged,
    required this.onClearFilters,
    required this.onCreateEntry,
    required this.onOpenEntry,
  });

  final List<VaultItem> items;
  final int totalItems;
  final TextEditingController searchController;
  final _VaultFilter activeFilter;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<_VaultFilter> onFilterChanged;
  final VoidCallback onClearFilters;
  final Future<void> Function() onCreateEntry;
  final Future<void> Function(VaultItem item) onOpenEntry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.vaultEntriesSectionTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                totalItems == items.length
                    ? l10n.itemsTotal(items.length)
                    : l10n.itemsShownOfTotal(items.length, totalItems),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            onChanged: onSearchChanged,
            decoration: InputDecoration(
              labelText: l10n.searchVault,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: onClearFilters,
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<_VaultFilter>(
            key: ValueKey(activeFilter),
            initialValue: activeFilter,
            decoration: InputDecoration(labelText: l10n.filter),
            items: _VaultFilter.values
                .map(
                  (filter) => DropdownMenuItem<_VaultFilter>(
                    value: filter,
                    child: Text(filter.label(context)),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value != null) {
                onFilterChanged(value);
              }
            },
          ),
          const SizedBox(height: AppSpacing.md),
          if (items.isEmpty && totalItems == 0)
            _EmptyVaultState(onCreateEntry: onCreateEntry)
          else if (items.isEmpty)
            _NoResultsState(onClearFilters: onClearFilters)
          else
            for (var index = 0; index < items.length; index++) ...[
              VaultEntryTile(
                item: items[index],
                onTap: () => onOpenEntry(items[index]),
              ),
              if (index != items.length - 1)
                const SizedBox(height: AppSpacing.sm),
            ],
        ],
      ),
    );
  }
}

class _NoResultsState extends StatelessWidget {
  const _NoResultsState({required this.onClearFilters});
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.filter_alt_off_rounded, size: 32),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.noResultsTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.noResultsSubtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: onClearFilters,
            icon: const Icon(Icons.restart_alt_rounded),
            label: Text(l10n.resetFilters),
          ),
        ],
      ),
    );
  }
}

class _EmptyVaultState extends StatelessWidget {
  const _EmptyVaultState({required this.onCreateEntry});
  final Future<void> Function() onCreateEntry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.crimson.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: AppColors.crimson.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.crimson,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
            child: const Icon(
              Icons.vpn_key_rounded,
              color: AppColors.paperDark,
              size: 28,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.emptyVaultTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.emptyVaultSubtitle,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: onCreateEntry,
            icon: const Icon(Icons.add_rounded),
            label: Text(l10n.createFirstEntry),
          ),
        ],
      ),
    );
  }
}

enum _VaultFilter { all, weak, favorites, withNotes }

extension on _VaultFilter {
  String label(BuildContext context) {
    final l10n = context.l10n;
    return switch (this) {
      _VaultFilter.all => l10n.filterAllEntries,
      _VaultFilter.weak => l10n.filterWeakOnly,
      _VaultFilter.favorites => l10n.filterFavorites,
      _VaultFilter.withNotes => l10n.filterWithNotes,
    };
  }
}
