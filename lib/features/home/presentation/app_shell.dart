// ignore_for_file: prefer_const_constructors

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/app_locale_controller.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/secure_storage_service.dart';
import '../../../core/security/vault_repository.dart';
import '../../../core/security/vault_security_controller.dart';
import '../../../core/sync/device_session_revocation_service.dart';
import '../../../core/sync/sync_conflict_resolver.dart';
import '../../../core/update/update_service.dart';
import '../../../features/access/presentation/access_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../vault/presentation/vault_dashboard_screen.dart';

/// Top-level unlocked shell: a [ScaffoldMessenger] hosting a
/// 3-tab [IndexedStack] (Vault, Access, Settings) and the rounded
/// bottom navigation bar.
///
/// Silently checks for app updates on mount and shows a snackbar
/// when a new build is available and has not been prompted.
class AppShell extends StatefulWidget {
  /// Builds the unlocked shell. The three required services are
  /// forwarded to every child tab; the optional ones (conflict
  /// resolver, revocation service, secure storage) are only rendered
  /// by the children that actually need them.
  const AppShell({
    super.key,
    required this.repository,
    required this.securityController,
    required this.localeController,
    this.conflictResolver,
    this.revocationService,
    this.secureStorage,
  });

  /// Vault repository forwarded to the [VaultDashboardScreen] and
  /// the [AccessScreen].
  final VaultRepository repository;

  /// Security controller forwarded to every child tab. Children
  /// listen to it to react to lock/unlock transitions.
  final VaultSecurityController securityController;

  /// Locale controller forwarded to the [SettingsScreen] for the
  /// in-app language switcher.
  final AppLocaleController localeController;

  /// Optional sync conflict resolver forwarded to the dashboard
  /// (banner) and the settings screen (full list).
  final SyncConflictResolver? conflictResolver;

  /// Optional device session revocation service forwarded to the
  /// settings screen.
  final DeviceSessionRevocationService? revocationService;

  /// Optional secure storage used by the in-app [UpdateService].
  final SecureStorageService? secureStorage;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  late final UpdateService _updateService = UpdateService(
    owner: 'Rene-Kuhm',
    repo: 'vaulta',
    storage: widget.secureStorage,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_silentCheckForUpdate());
  }

  Future<void> _silentCheckForUpdate() async {
    try {
      final info = await _updateService.checkForUpdate();
      if (!info.available) return;
      final promptedBuild = await _updateService.lastSeenBuildFingerprint();
      if (info.buildFingerprint.isNotEmpty &&
          promptedBuild == info.buildFingerprint) {
        return;
      }
      if (!mounted) return;
      final l10n = context.l10n;
      final messenger = _scaffoldMessengerKey.currentState;
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.updateAvailableBanner(info.tagName)),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: l10n.updateActionUpdate,
            onPressed: () => _downloadAndInstall(info),
          ),
        ),
      );
      await _updateService.markBuildPrompted(info);
    } catch (error, stack) {
      debugPrint('[Vaulta/Update] silent check failed: $error\n$stack');
    }
  }

  Future<void> _downloadAndInstall(UpdateInfo info) async {
    if (!mounted) return;
    final l10n = context.l10n;
    final messenger = _scaffoldMessengerKey.currentState;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(l10n.updateDownloading),
        duration: const Duration(seconds: 2),
      ),
    );
    try {
      final path = await _updateService.downloadApk(info);
      if (!mounted) return;
      final ok = await _updateService.openInstallPrompt(path);
      if (!mounted) return;
      if (ok) {
        await _updateService.markBuildPrompted(info);
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            ok ? l10n.updateInstallPrompt : l10n.updateInstallFailed,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.updateGenericError(error.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final screens = <Widget>[
      VaultDashboardScreen(
        repository: widget.repository,
        conflictResolver: widget.conflictResolver,
        securityController: widget.securityController,
      ),
      AccessScreen(
        securityController: widget.securityController,
        repository: widget.repository,
      ),
      SettingsScreen(
        securityController: widget.securityController,
        localeController: widget.localeController,
        conflictResolver: widget.conflictResolver,
        revocationService: widget.revocationService,
        secureStorage: widget.secureStorage,
        repository: widget.repository,
      ),
    ];

    return ScaffoldMessenger(
      key: _scaffoldMessengerKey,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        extendBody: true,
        body: AnimatedSwitcher(
          duration: AppMotion.medium,
          switchInCurve: AppMotion.enter,
          switchOutCurve: AppMotion.exit,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: KeyedSubtree(
            key: ValueKey('shell.tab.$_currentIndex'),
            child: IndexedStack(index: _currentIndex, children: screens),
          ),
        ),
        bottomNavigationBar: _AppBottomBar(
          currentIndex: _currentIndex,
          isDark: isDark,
          onSelected: (i) => setState(() => _currentIndex = i),
          destinations: [
            _AppNavDest(
              icon: Icons.lock_outline_rounded,
              selectedIcon: Icons.lock_rounded,
              label: l10n.navVault,
            ),
            _AppNavDest(
              icon: Icons.bolt_outlined,
              selectedIcon: Icons.bolt_rounded,
              label: l10n.navAccess,
            ),
            _AppNavDest(
              icon: Icons.tune_outlined,
              selectedIcon: Icons.tune_rounded,
              label: l10n.navSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _AppBottomBar extends StatelessWidget {
  const _AppBottomBar({
    required this.currentIndex,
    required this.isDark,
    required this.onSelected,
    required this.destinations,
  });

  final int currentIndex;
  final bool isDark;
  final ValueChanged<int> onSelected;
  final List<_AppNavDest> destinations;

  @override
  Widget build(BuildContext context) {
    final fill = isDark
        ? AppColors.surfaceDark.withValues(alpha: 0.85)
        : AppColors.surfaceLight.withValues(alpha: 0.92);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
            border: Border.all(
              color: isDark ? AppColors.borderDark : AppColors.borderLight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: NavigationBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            height: 64,
            selectedIndex: currentIndex,
            onDestinationSelected: onSelected,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final dest in destinations)
                NavigationDestination(
                  icon: Icon(dest.icon),
                  selectedIcon: Icon(dest.selectedIcon),
                  label: dest.label,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppNavDest {
  const _AppNavDest({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Reusable "feature coming soon" page for sections that are scoped
/// to the MVP but not yet implemented. Bilingual, on-brand, and
/// consistent across the app so users get the same placeholder
/// treatment everywhere.
class FeaturePlaceholderScreen extends StatelessWidget {
  /// Builds a "feature coming soon" page. [bullets] and [eyebrow]
  /// are optional; the rest of the visual identity is driven by
  /// [icon], [title], and [subtitle].
  const FeaturePlaceholderScreen({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.bullets = const <String>[],
    this.eyebrow,
  });

  /// Hero icon for the placeholder.
  final IconData icon;

  /// Screen title (Spanish UI copy).
  final String title;

  /// Subtitle under the title, typically a one-sentence summary of
  /// why the feature is not yet available.
  final String subtitle;

  /// Optional list of bullet points, rendered as a panel below the
  /// header. Defaults to an empty list.
  final List<String> bullets;

  /// Optional small uppercase eyebrow shown above [title].
  final String? eyebrow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
          padding: AppSpacing.screenPadding,
          children: [
            const SizedBox(height: AppSpacing.lg),
            Center(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: AppColors.crimson.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
                  border: Border.all(
                    color: AppColors.crimson.withValues(alpha: 0.45),
                  ),
                ),
                child: Icon(icon, size: 44, color: AppColors.crimsonBright),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppSectionHeader(
              eyebrow: eyebrow,
              title: title,
              subtitle: subtitle,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (bullets.isNotEmpty)
              AppPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < bullets.length; i++) ...[
                      if (i != 0) const Divider(height: AppSpacing.lg),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.crimson.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(
                                AppSpacing.radiusSm,
                              ),
                            ),
                            child: Icon(
                              Icons.check_rounded,
                              size: 16,
                              color: AppColors.crimsonBright,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              bullets[i],
                              style: theme.textTheme.bodyLarge,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
