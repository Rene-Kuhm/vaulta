import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/platform_security_plan.dart';
import '../../../core/security/vault_security_controller.dart';

/// The capability list of the security screen: what this device can
/// actually do, as answered by the services that do it.
///
/// Three states, three renderings. An unknown state is deliberately not
/// drawn — and not worded — like a confirmed "not available": the screen
/// this replaces reported `false` for capabilities that worked, and a
/// user reading it could not tell a lie from a limitation they could fix.
///
/// The probe runs once when the panel is built, because the answer
/// depends on enrollment state the user can change in system settings.
/// Until it returns, every row reads "unknown" — the honest answer to a
/// question that has not been answered yet.
class SecurityCapabilitiesPanel extends StatefulWidget {
  /// Builds the panel for [controller].
  ///
  /// [probe] overrides the capability probe; tests use it to render a
  /// fixed [PlatformSecurityPlan]. It defaults to
  /// [VaultSecurityController.probeSecurityPlan].
  const SecurityCapabilitiesPanel({
    super.key,
    required this.controller,
    this.probe,
  });

  /// Source of the capabilities shown. Also the default probe.
  final VaultSecurityController controller;

  /// Optional probe override, for tests.
  final Future<PlatformSecurityPlan> Function()? probe;

  @override
  State<SecurityCapabilitiesPanel> createState() =>
      _SecurityCapabilitiesPanelState();
}

class _SecurityCapabilitiesPanelState extends State<SecurityCapabilitiesPanel> {
  PlatformSecurityPlan _plan = PlatformSecurityPlan.unknown;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final probe = widget.probe ?? widget.controller.probeSecurityPlan;
    PlatformSecurityPlan plan;
    try {
      plan = await probe();
    } catch (error) {
      // A probe that throws is an unanswered question, not a "no".
      debugPrint('[Vaulta] capability probe failed: $error');
      plan = PlatformSecurityPlan.unknown;
    }
    if (!mounted) return;
    setState(() => _plan = plan);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CapabilityStateRow(
          title: l10n.settingsSecureStorage,
          state: _plan.secureStorage,
        ),
        _CapabilityStateRow(
          title: l10n.settingsBiometricUnlock,
          state: _plan.biometricUnlock,
        ),
        _CapabilityStateRow(
          title: l10n.settingsHardwareBackedKeys,
          state: _plan.hardwareBackedKeys,
        ),
        _CapabilityStateRow(
          title: l10n.settingsVaultEncryptionReady,
          state: _plan.vaultEncryptionReady,
        ),
      ],
    );
  }
}

/// One capability line: badge, name and the state spelled out in words.
///
/// The state is a word, not only a colour or an icon, so it survives a
/// screen reader, a colour-blind reader and a translation.
class _CapabilityStateRow extends StatelessWidget {
  const _CapabilityStateRow({required this.title, required this.state});

  final String title;
  final SecurityCapabilityState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (state) {
      SecurityCapabilityState.supported => AppColors.success,
      SecurityCapabilityState.unsupported => theme.colorScheme.onSurfaceVariant,
      SecurityCapabilityState.unknown => AppColors.warning,
    };
    final icon = switch (state) {
      SecurityCapabilityState.supported => Icons.verified_user_rounded,
      SecurityCapabilityState.unsupported => Icons.radio_button_unchecked,
      SecurityCapabilityState.unknown => Icons.help_outline_rounded,
    };
    final l10n = context.l10n;
    final label = switch (state) {
      SecurityCapabilityState.supported => l10n.settingsCapabilitySupported,
      SecurityCapabilityState.unsupported => l10n.settingsCapabilityUnsupported,
      SecurityCapabilityState.unknown => l10n.settingsCapabilityUnknown,
    };

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
