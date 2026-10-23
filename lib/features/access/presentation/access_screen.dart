import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/vault_repository.dart';
import '../../../core/security/vault_security_controller.dart';

/// Access & Autofill section.
///
/// The native Android autofill service is registered and answers fill
/// requests (ADR-008). This screen explains what it fills today — browser
/// logins, plus apps with a verified website on Android 12+ — and shows the
/// unlock posture that gates every request. It deliberately changes no
/// system settings on its own: picking Vaulta as the autofill provider is a
/// user action in Android's own settings.
class AccessScreen extends StatelessWidget {
  /// Creates the "Access & Autofill" tab. Both [securityController]
  /// and [repository] are required so this tab never silently
  /// no-ops when wired without them.
  const AccessScreen({
    super.key,
    required this.securityController,
    required this.repository,
  });

  /// Security controller used to render the unlocked/locked pill
  /// and to trigger an explicit lock from this screen.
  final VaultSecurityController securityController;

  /// Vault repository. Currently unused at the UI layer but kept on
  /// the constructor for parity with the other tabs and so future
  /// entries (for example, "recently autofilled") can read it
  /// without a refactor.
  final VaultRepository repository;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: ListView(
          padding: AppSpacing.screenPadding,
          children: [
            const SizedBox(height: AppSpacing.md),
            AppSectionHeader(
              eyebrow: l10n.accessEyebrow,
              title: l10n.accessTitle,
              subtitle: l10n.accessSubtitle,
            ),
            const SizedBox(height: AppSpacing.lg),
            _AutofillHeroCard(),
            const SizedBox(height: AppSpacing.lg),
            AppPanel(
              key: const ValueKey('access-autofill-status'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.accessStatusTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    l10n.accessStatusBody,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.accessUnlockPostureTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    l10n.accessUnlockPostureBody,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AnimatedBuilder(
                    animation: securityController,
                    builder: (context, _) {
                      final tone = securityController.isUnlocked
                          ? AppPillTint.success
                          : AppPillTint.warning;
                      final label = securityController.isUnlocked
                          ? l10n.accessUnlocked
                          : l10n.accessLocked;
                      return AppPill(label: label, tint: tone);
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.tonalIcon(
                    onPressed: securityController.isUnlocked
                        ? securityController.lock
                        : null,
                    icon: const Icon(Icons.lock_rounded),
                    label: Text(l10n.accessLockNow),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.accessRoadmapTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    l10n.accessRoadmapBody,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xxxl),
          ],
        ),
      ),
    );
  }
}

class _AutofillHeroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return AppGlassSurface(
      tint: AppGlassTint.strong,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.crimson,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  color: AppColors.paperDark,
                  size: 30,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.accessHeroTitle,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.accessHeroBody,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              AppPill(
                icon: Icons.schedule_rounded,
                label: l10n.accessComingSoon,
                tint: AppPillTint.warning,
              ),
              AppPill(
                icon: Icons.android_rounded,
                label: l10n.accessPlatformAndroid,
                tint: AppPillTint.neutral,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
