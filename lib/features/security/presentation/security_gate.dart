// ignore_for_file: prefer_const_constructors

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_components.dart';
import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/native_biometric_auth_service.dart';
import '../../../core/security/vault_security_controller.dart';
import '../../../core/sync/device_registration_service.dart';
import 'unlock_throttle_text.dart';

/// Top-level gate that swaps between loading / onboarding / locked
/// / unlocked and animates the transition.
class SecurityGate extends StatefulWidget {
  /// Builds the gate. [controller] drives the [VaultSecurityStage]
  /// machine and [child] is the unlocked subtree. [deviceSyncLifecycle]
  /// is optional and only needed if the app is wired to a sync
  /// backend.
  const SecurityGate({
    super.key,
    required this.controller,
    required this.child,
    this.deviceSyncLifecycle,
  });

  /// Controller that owns the [VaultSecurityStage] transition
  /// machine. The gate rebuilds whenever the controller notifies its
  /// listeners.
  final VaultSecurityController controller;

  /// The widget subtree shown once the stage reaches
  /// [VaultSecurityStage.unlocked] (typically the [AppShell]).
  final Widget child;

  /// Optional lifecycle hook fired on session start and on app
  /// resume. Used by the sync layer to refresh device state without
  /// coupling the gate to a specific implementation.
  final DeviceSyncLifecycle? deviceSyncLifecycle;

  @override
  State<SecurityGate> createState() => _SecurityGateState();
}

class _SecurityGateState extends State<SecurityGate>
    with WidgetsBindingObserver {
  late VaultSecurityStage _lastStage;
  bool _canOfferBiometricButton = false;

  @override
  void initState() {
    super.initState();
    _lastStage = widget.controller.stage;
    widget.controller.addListener(_handleSecurityStageChange);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshBiometricUnlockAvailability());
  }

  @override
  void didUpdateWidget(covariant SecurityGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }

    oldWidget.controller.removeListener(_handleSecurityStageChange);
    widget.controller.addListener(_handleSecurityStageChange);
    _lastStage = widget.controller.stage;
  }

  Future<void> _refreshBiometricUnlockAvailability() async {
    final nextOffer = widget.controller.canOfferBiometricUnlockButton;
    if (!mounted) return;
    if (nextOffer != _canOfferBiometricButton) {
      setState(() => _canOfferBiometricButton = nextOffer);
    }
  }

  void _handleSecurityStageChange() {
    final currentStage = widget.controller.stage;
    final movedToUnlocked =
        _lastStage != VaultSecurityStage.unlocked &&
        currentStage == VaultSecurityStage.unlocked;
    final movedToLocked =
        _lastStage != VaultSecurityStage.locked &&
        currentStage == VaultSecurityStage.locked;
    final leftUnlocked =
        _lastStage == VaultSecurityStage.unlocked &&
        currentStage != VaultSecurityStage.unlocked;
    _lastStage = currentStage;

    if (leftUnlocked) {
      _dismissRoutesAboveGate();
    }

    if (movedToLocked || movedToUnlocked) {
      unawaited(_refreshBiometricUnlockAvailability());
    }

    if (!movedToUnlocked) {
      return;
    }

    final lifecycle = widget.deviceSyncLifecycle;
    if (lifecycle == null) {
      return;
    }

    _runLifecycleAction(lifecycle.onSessionStarted());
  }

  /// Fail closed on lock: pops every route pushed above the gate
  /// (entry detail, editor, import / backup screens, dialogs, bottom
  /// sheets). They are not part of the gate's subtree, so swapping the
  /// stage alone would leave them, and the secrets they render, on top
  /// of the lock screen. Popping disposes their state, which drops any
  /// sensitive data they hold.
  void _dismissRoutesAboveGate() {
    if (!mounted) return;
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator == null) return;
    // pop (not maybePop) so a PopScope on a route cannot veto the lock.
    navigator.popUntil((route) => route.isFirst);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.handleAppLifecycleState(state);

    final lifecycle = widget.deviceSyncLifecycle;
    if (state == AppLifecycleState.resumed &&
        widget.controller.isUnlocked &&
        lifecycle != null) {
      _runLifecycleAction(lifecycle.onAppResumed());
    }
  }

  void _runLifecycleAction(Future<void> action) {
    unawaited(action.catchError((_) {}));
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleSecurityStageChange);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return AnimatedSwitcher(
          duration: AppMotion.slow,
          switchInCurve: AppMotion.enter,
          switchOutCurve: AppMotion.exit,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.04),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: switch (widget.controller.stage) {
            VaultSecurityStage.loading => const _LoadingStage(
              key: ValueKey('security.loading'),
            ),
            VaultSecurityStage.onboarding => _OnboardingScreen(
              key: const ValueKey('security.onboarding'),
              controller: widget.controller,
            ),
            VaultSecurityStage.locked => _UnlockScreen(
              key: const ValueKey('security.locked'),
              controller: widget.controller,
            ),
            VaultSecurityStage.unlocked => _UnlockedHost(
              key: const ValueKey('security.unlocked'),
              controller: widget.controller,
              child: widget.child,
            ),
          },
        );
      },
    );
  }
}

/// Wraps the unlocked UI in the same idle/pointer tracking the
/// previous gate did, but visually identityless — the AppShell
/// paints its own background.
class _UnlockedHost extends StatelessWidget {
  const _UnlockedHost({
    super.key,
    required this.controller,
    required this.child,
  });

  final VaultSecurityController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, _) {
        controller.registerUserInteraction();
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => controller.registerUserInteraction(),
        onPointerMove: (_) => controller.registerUserInteraction(),
        onPointerSignal: (_) => controller.registerUserInteraction(),
        onPointerPanZoomStart: (_) => controller.registerUserInteraction(),
        child: child,
      ),
    );
  }
}

class _LoadingStage extends StatelessWidget {
  const _LoadingStage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppHeroBackground(
      child: const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Onboarding
// ---------------------------------------------------------------------------

class _OnboardingScreen extends StatefulWidget {
  const _OnboardingScreen({super.key, required this.controller});

  final VaultSecurityController controller;

  @override
  State<_OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<_OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _enableBiometrics = false;
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controller = widget.controller;
    final isWide = MediaQuery.sizeOf(context).width >= 880;

    final form = _OnboardingForm(
      formKey: _formKey,
      controller: controller,
      passwordController: _passwordController,
      confirmationController: _confirmationController,
      enableBiometrics: _enableBiometrics,
      obscurePassword: _obscurePassword,
      obscureConfirmation: _obscureConfirmation,
      onEnableBiometricsChanged: (value) {
        setState(() => _enableBiometrics = value);
      },
      onTogglePasswordObscure: () {
        setState(() => _obscurePassword = !_obscurePassword);
      },
      onToggleConfirmationObscure: () {
        setState(() => _obscureConfirmation = !_obscureConfirmation);
      },
    );

    final hero = _OnboardingHero(
      eyebrow: l10n.securityOnboardingEyebrow,
      title: l10n.securityOnboardingTitle,
      subtitle: l10n.securityOnboardingSubtitle,
    );

    return AppHeroBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: isWide
              ? _SplitLayout(
                  hero: hero,
                  form: form,
                  footer: const _BrandFooter(),
                )
              : _StackedLayout(
                  hero: hero,
                  form: form,
                  footer: const _BrandFooter(),
                ),
        ),
      ),
    );
  }
}

class _SplitLayout extends StatelessWidget {
  const _SplitLayout({required this.hero, required this.form, this.footer});
  final Widget hero;
  final Widget form;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xxl,
              AppSpacing.xxl,
              AppSpacing.xxl,
              AppSpacing.xxl,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: hero,
              ),
            ),
          ),
        ),
        Expanded(
          flex: 6,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.xl,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    form,
                    if (footer case final footer?) ...[
                      const SizedBox(height: AppSpacing.lg),
                      footer,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StackedLayout extends StatelessWidget {
  const _StackedLayout({required this.hero, required this.form, this.footer});
  final Widget hero;
  final Widget form;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      children: [
        hero,
        const SizedBox(height: AppSpacing.xl),
        form,
        if (footer case final footer?) ...[
          const SizedBox(height: AppSpacing.lg),
          footer,
        ],
      ],
    );
  }
}

class _BrandFooter extends StatelessWidget {
  const _BrandFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Text(
      context.l10n.brandFooter,
      textAlign: TextAlign.center,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
    );
  }
}

class _OnboardingHero extends StatelessWidget {
  const _OnboardingHero({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });

  final String eyebrow;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const VaultaLogomark(size: 64),
            const SizedBox(width: AppSpacing.md),
            Text(
              l10n.appTitle,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 2.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.crimson.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
            border: Border.all(
              color: AppColors.crimson.withValues(alpha: 0.45),
            ),
          ),
          child: Text(
            eyebrow,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.crimsonBright,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          title,
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.05,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          subtitle,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        _SecurityChecklist(
          items: [
            _ChecklistItemData(
              icon: Icons.shield_moon_rounded,
              titleKey: 'Argon2id master key',
              subtitleKey: 'KEK derived on-device, never persisted.',
            ),
            _ChecklistItemData(
              icon: Icons.lock_reset_rounded,
              titleKey: 'Random per-vault DEK',
              subtitleKey: 'Wrapped with AES-256-GCM, rotates with password.',
            ),
            _ChecklistItemData(
              icon: Icons.account_tree_rounded,
              titleKey: 'Hardware-backed biometrics',
              subtitleKey: 'Android KeyStore on Pixel & Samsung-class devices.',
            ),
          ],
        ),
      ],
    );
  }
}

class _ChecklistItemData {
  _ChecklistItemData({
    required this.icon,
    required this.titleKey,
    required this.subtitleKey,
  });
  final IconData icon;
  final String titleKey;
  final String subtitleKey;
}

class _SecurityChecklist extends StatelessWidget {
  const _SecurityChecklist({required this.items});
  final List<_ChecklistItemData> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.crimson.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Icon(
                  item.icon,
                  size: 18,
                  color: AppColors.crimsonBright,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.titleKey,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.subtitleKey,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}

class _OnboardingForm extends StatelessWidget {
  const _OnboardingForm({
    required this.formKey,
    required this.controller,
    required this.passwordController,
    required this.confirmationController,
    required this.enableBiometrics,
    required this.obscurePassword,
    required this.obscureConfirmation,
    required this.onEnableBiometricsChanged,
    required this.onTogglePasswordObscure,
    required this.onToggleConfirmationObscure,
  });

  final GlobalKey<FormState> formKey;
  final VaultSecurityController controller;
  final TextEditingController passwordController;
  final TextEditingController confirmationController;
  final bool enableBiometrics;
  final bool obscurePassword;
  final bool obscureConfirmation;
  final ValueChanged<bool> onEnableBiometricsChanged;
  final VoidCallback onTogglePasswordObscure;
  final VoidCallback onToggleConfirmationObscure;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return AppGlassSurface(
      tint: AppGlassTint.strong,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.securityMasterPasswordTitle,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              l10n.securityMasterPasswordDescription,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextFormField(
              controller: passwordController,
              obscureText: obscurePassword,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.securityCreateMasterPassword,
                prefixIcon: const Icon(Icons.password_rounded),
                suffixIcon: IconButton(
                  onPressed: onTogglePasswordObscure,
                  icon: Icon(
                    obscurePassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.securityMasterPasswordRequired;
                }
                if (value.length < 12) {
                  return l10n.securityMasterPasswordMinLength;
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: confirmationController,
              obscureText: obscureConfirmation,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l10n.securityConfirmMasterPassword,
                prefixIcon: const Icon(Icons.password_rounded),
                suffixIcon: IconButton(
                  onPressed: onToggleConfirmationObscure,
                  icon: Icon(
                    obscureConfirmation
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                ),
              ),
              validator: (value) {
                if (value != passwordController.text) {
                  return l10n.securityMasterPasswordMismatch;
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            _Checklist(
              items: [
                l10n.securityChecklistHash,
                l10n.securityChecklistDerive,
                l10n.securityChecklistEncrypt,
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: enableBiometrics,
                onChanged: controller.canOfferBiometricToggle
                    ? onEnableBiometricsChanged
                    : null,
                title: Text(
                  l10n.securityEnableBiometrics,
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Text(
                  controller.canOfferBiometricToggle
                      ? l10n.securityBiometricAvailable(
                          controller.biometricAvailability.label,
                        )
                      : l10n.securityBiometricUnavailable,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (controller.message case final message?) ...[
              const SizedBox(height: AppSpacing.sm),
              AppBanner(
                message: message,
                tone: _bannerToneFor(controller.message),
                icon: controller.messageIsError == true
                    ? Icons.error_outline_rounded
                    : Icons.info_outline_rounded,
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: controller.busy ? null : _submit,
              icon: controller.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.shield_rounded),
              label: Text(l10n.securityCreateSecureAccess),
            ),
          ],
        ),
      ),
    );
  }

  AppBannerTone _bannerToneFor(String? message) {
    if (message == null) return AppBannerTone.info;
    final lower = message.toLowerCase();
    if (lower.contains('error') ||
        lower.contains('fail') ||
        lower.contains('inv')) {
      return AppBannerTone.danger;
    }
    return AppBannerTone.info;
  }

  Future<void> _submit() async {
    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }
    final created = await controller.createMasterPassword(
      password: passwordController.text,
      confirmation: confirmationController.text,
      enableBiometrics: enableBiometrics,
    );
    if (created) {
      // Unfocus the password field by grabbing the current focus
      // node from the active element. We don't carry a context
      // through the async gap, so we just clear focus globally.
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }
}

// ---------------------------------------------------------------------------
// Unlock
// ---------------------------------------------------------------------------

class _UnlockScreen extends StatefulWidget {
  const _UnlockScreen({super.key, required this.controller});

  final VaultSecurityController controller;

  @override
  State<_UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<_UnlockScreen> {
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _canOfferBiometricButton = false;
  String? _biometricStatusMessage;
  NativeBiometricCapability _biometricCapability =
      NativeBiometricCapability.empty;
  bool _enrollingBiometric = false;
  bool _settingUpBiometric = false;
  bool _envelopeEnrolled = false;

  /// Rebuilds the form once per second while a failed-attempt lockout
  /// is active so the countdown and the disabled button stay current.
  Timer? _lockoutTicker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChange);
    unawaited(_refreshBiometricUnlockAvailability());
    _syncLockoutTicker();
  }

  @override
  void dispose() {
    _lockoutTicker?.cancel();
    widget.controller.removeListener(_handleControllerChange);
    _passwordController.dispose();
    super.dispose();
  }

  void _handleControllerChange() {
    unawaited(_refreshBiometricUnlockAvailability());
    _syncLockoutTicker();
  }

  void _syncLockoutTicker() {
    if (!widget.controller.isUnlockLockedOut) {
      _lockoutTicker?.cancel();
      _lockoutTicker = null;
      return;
    }
    _lockoutTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (!widget.controller.isUnlockLockedOut) {
        _lockoutTicker?.cancel();
        _lockoutTicker = null;
      }
    });
  }

  Future<void> _refreshBiometricUnlockAvailability() async {
    final nextOffer = widget.controller.canOfferBiometricUnlockButton;
    final nextMessage = await widget.controller.biometricUnlockStatusMessage();
    final nextCap = await widget.controller.probeBiometricCapability();
    final nextEnvelopeEnrolled = widget.controller.isBiometricEnvelopeEnrolled;
    if (!mounted) return;
    final capChanged =
        nextCap.canUseStrongOrCredential !=
            _biometricCapability.canUseStrongOrCredential ||
        nextCap.canUseStrong != _biometricCapability.canUseStrong ||
        nextCap.canUseWeak != _biometricCapability.canUseWeak ||
        nextCap.needsEnrollment != _biometricCapability.needsEnrollment;
    if (nextOffer != _canOfferBiometricButton ||
        nextMessage != _biometricStatusMessage ||
        capChanged ||
        nextEnvelopeEnrolled != _envelopeEnrolled) {
      setState(() {
        _canOfferBiometricButton = nextOffer;
        _biometricStatusMessage = nextMessage;
        _envelopeEnrolled = nextEnvelopeEnrolled;
        _biometricCapability = nextCap;
      });
    }
  }

  Future<void> _openBiometricEnrollment() async {
    if (_enrollingBiometric) return;
    setState(() => _enrollingBiometric = true);
    try {
      final ok = await widget.controller.openBiometricEnrollment();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.biometricEnrollUnavailable)),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await _refreshBiometricUnlockAvailability();
    } finally {
      if (mounted) {
        setState(() => _enrollingBiometric = false);
      }
    }
  }

  Future<void> _openBiometricSetupDialog() async {
    if (_settingUpBiometric) return;
    final lockout = widget.controller.unlockLockoutRemaining;
    if (lockout != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.securityUnlockLockedOut(
              formatLockoutRemaining(lockout),
            ),
          ),
        ),
      );
      return;
    }
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _SetupBiometricDialog(),
    );
    if (password == null || password.isEmpty || !mounted) {
      return;
    }
    setState(() => _settingUpBiometric = true);
    try {
      final ok = await widget.controller.setupBiometricFromPassword(password);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? widget.controller.message ??
                      context.l10n.securitySetupBiometricSuccess
                : widget.controller.message ??
                      unlockThrottleMessage(context.l10n, widget.controller) ??
                      context.l10n.securitySetupBiometricError,
          ),
        ),
      );
      await _refreshBiometricUnlockAvailability();
    } finally {
      if (mounted) {
        setState(() => _settingUpBiometric = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controller = widget.controller;
    final isWide = MediaQuery.sizeOf(context).width >= 880;

    final form = _UnlockForm(
      controller: controller,
      passwordController: _passwordController,
      obscurePassword: _obscurePassword,
      canOfferBiometricButton: _canOfferBiometricButton,
      biometricStatusMessage: _biometricStatusMessage,
      biometricCapability: _biometricCapability,
      envelopeEnrolled: _envelopeEnrolled,
      enrollingBiometric: _enrollingBiometric,
      settingUpBiometric: _settingUpBiometric,
      onToggleObscure: () {
        setState(() => _obscurePassword = !_obscurePassword);
      },
      onUnlockWithPassword: _unlockWithPassword,
      onUnlockWithBiometrics: _unlockWithBiometrics,
      onOpenBiometricEnrollment: _openBiometricEnrollment,
      onOpenBiometricSetup: _openBiometricSetupDialog,
    );

    final hero = _UnlockHero(
      eyebrow: l10n.securityUnlockEyebrow,
      title: l10n.securityUnlockTitle,
      subtitle: _canOfferBiometricButton
          ? l10n.securityUnlockBiometricSubtitle(
              controller.biometricAvailability.label,
            )
          : l10n.securityUnlockPasswordSubtitle,
    );

    return AppHeroBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: isWide
              ? _SplitLayout(
                  hero: hero,
                  form: form,
                  footer: const _BrandFooter(),
                )
              : _StackedLayout(
                  hero: hero,
                  form: form,
                  footer: const _BrandFooter(),
                ),
        ),
      ),
    );
  }

  Future<void> _unlockWithPassword() async {
    // The keyboard "go" action bypasses the disabled button, so guard
    // here too. The controller rejects the attempt anyway; this just
    // avoids a pointless round-trip.
    if (widget.controller.busy || widget.controller.isUnlockLockedOut) {
      return;
    }
    await widget.controller.unlockWithPassword(_passwordController.text);
    if (mounted && widget.controller.isUnlocked) {
      FocusScope.of(context).unfocus();
      _passwordController.clear();
    }
    if (mounted) {
      unawaited(_refreshBiometricUnlockAvailability());
    }
  }

  Future<void> _unlockWithBiometrics() async {
    await widget.controller.unlockWithBiometrics();
    if (mounted) {
      unawaited(_refreshBiometricUnlockAvailability());
    }
  }
}

class _UnlockHero extends StatelessWidget {
  const _UnlockHero({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });

  final String eyebrow;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const VaultaLogomark(size: 64),
            const SizedBox(width: AppSpacing.md),
            Text(
              l10n.appTitle,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 2.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.crimson.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
            border: Border.all(
              color: AppColors.crimson.withValues(alpha: 0.45),
            ),
          ),
          child: Text(
            eyebrow,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.crimsonBright,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          title,
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.05,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          subtitle,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        _SecurityChecklist(
          items: [
            _ChecklistItemData(
              icon: Icons.fingerprint_rounded,
              titleKey: 'Unlock with biometrics',
              subtitleKey:
                  'Use the fingerprint already enrolled on this device.',
            ),
            _ChecklistItemData(
              icon: Icons.password_rounded,
              titleKey: 'Master password fallback',
              subtitleKey:
                  'Always available — your recovery path if biometrics are unavailable.',
            ),
            _ChecklistItemData(
              icon: Icons.timer_outlined,
              titleKey: 'Auto-lock on background',
              subtitleKey:
                  'Vault closes when the app is backgrounded or after idle.',
            ),
          ],
        ),
      ],
    );
  }
}

class _UnlockForm extends StatelessWidget {
  const _UnlockForm({
    required this.controller,
    required this.passwordController,
    required this.obscurePassword,
    required this.canOfferBiometricButton,
    required this.biometricStatusMessage,
    required this.biometricCapability,
    required this.envelopeEnrolled,
    required this.enrollingBiometric,
    required this.settingUpBiometric,
    required this.onToggleObscure,
    required this.onUnlockWithPassword,
    required this.onUnlockWithBiometrics,
    required this.onOpenBiometricEnrollment,
    required this.onOpenBiometricSetup,
  });

  final VaultSecurityController controller;
  final TextEditingController passwordController;
  final bool obscurePassword;
  final bool canOfferBiometricButton;
  final String? biometricStatusMessage;
  final NativeBiometricCapability biometricCapability;
  final bool envelopeEnrolled;
  final bool enrollingBiometric;
  final bool settingUpBiometric;
  final VoidCallback onToggleObscure;
  final VoidCallback onUnlockWithPassword;
  final VoidCallback onUnlockWithBiometrics;
  final VoidCallback onOpenBiometricEnrollment;
  final VoidCallback onOpenBiometricSetup;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final lockoutRemaining = controller.unlockLockoutRemaining;
    final passwordUnlockDisabled = controller.busy || lockoutRemaining != null;

    return AppGlassSurface(
      tint: AppGlassTint.strong,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.securityProtectedAccess,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            canOfferBiometricButton
                ? l10n.securityUnlockBiometricHint
                : l10n.securityUnlockPasswordHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: passwordController,
            obscureText: obscurePassword,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => onUnlockWithPassword(),
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              labelText: l10n.securityMasterPasswordTitle,
              prefixIcon: const Icon(Icons.password_rounded),
              suffixIcon: IconButton(
                onPressed: onToggleObscure,
                icon: Icon(
                  obscurePassword
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('unlock-with-password-button'),
                  onPressed: passwordUnlockDisabled
                      ? null
                      : onUnlockWithPassword,
                  icon: controller.busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock_open_rounded),
                  label: Text(l10n.securityUnlockVault),
                ),
              ),
              if (canOfferBiometricButton) ...[
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  width: 64,
                  height: 52,
                  child: OutlinedButton(
                    onPressed: controller.busy ? null : onUnlockWithBiometrics,
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          AppSpacing.radiusMd,
                        ),
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    child: const Icon(Icons.fingerprint_rounded, size: 26),
                  ),
                ),
              ],
            ],
          ),
          if (lockoutRemaining != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppBanner(
              key: const ValueKey('unlock-lockout-banner'),
              message: l10n.securityUnlockLockedOut(
                formatLockoutRemaining(lockoutRemaining),
              ),
              tone: AppBannerTone.danger,
              icon: Icons.timer_outlined,
            ),
          ],
          if (controller.unlockAttemptStateUnavailable) ...[
            const SizedBox(height: AppSpacing.md),
            AppBanner(
              key: const ValueKey('unlock-state-unavailable-banner'),
              message: l10n.securityUnlockStateUnavailable,
              tone: AppBannerTone.danger,
              icon: Icons.error_outline_rounded,
            ),
          ],
          if (biometricStatusMessage != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppBanner(
              message: biometricStatusMessage!,
              icon: Icons.fingerprint_rounded,
              tone: AppBannerTone.info,
            ),
          ],
          if (controller.message != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppBanner(
              message: controller.message!,
              tone: controller.messageIsError == true
                  ? AppBannerTone.danger
                  : AppBannerTone.info,
              icon: controller.messageIsError == true
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
            ),
          ],
          if (controller.canOfferBiometricToggle &&
              (!controller.biometricEnabled || !envelopeEnrolled)) ...[
            const SizedBox(height: AppSpacing.md),
            _SetupBiometricButton(
              label: l10n.securitySetupBiometricCta,
              busy: settingUpBiometric,
              onPressed: onOpenBiometricSetup,
            ),
          ],
          if (!canOfferBiometricButton &&
              controller.biometricEnabled &&
              biometricCapability.needsEnrollment) ...[
            const SizedBox(height: AppSpacing.md),
            _BiometricEnrollInline(
              title: l10n.biometricEnrollCta,
              actionLabel: l10n.biometricEnrollAction,
              busy: enrollingBiometric,
              onAction: onOpenBiometricEnrollment,
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact "biometric is enabled but not enrolled" CTA used in the
/// unlock screen. Single row, primary action on the right.
class _BiometricEnrollInline extends StatelessWidget {
  const _BiometricEnrollInline({
    required this.title,
    required this.actionLabel,
    required this.busy,
    required this.onAction,
  });

  final String title;
  final String actionLabel;
  final bool busy;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return AppBanner(
      message: title,
      tone: AppBannerTone.warning,
      icon: Icons.fingerprint_rounded,
      action: FilledButton.tonalIcon(
        onPressed: busy ? null : onAction,
        icon: busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.open_in_new_rounded, size: 16),
        label: Text(actionLabel),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          minimumSize: const Size(0, 36),
        ),
      ),
    );
  }
}

/// Full-width CTA rendered on the unlock screen when the device has
/// biometrics enrolled but the user has not turned biometric unlock
/// on yet. Tapping it opens [_SetupBiometricDialog].
class _SetupBiometricButton extends StatelessWidget {
  const _SetupBiometricButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonalIcon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.fingerprint_rounded),
        label: Text(label),
      ),
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist({required this.items});
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.verified_user_rounded,
                    size: 18,
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Modal dialog that asks for the master password so the controller
/// can derive a one-shot DEK and write the wrapped-DEK envelope
/// without unlocking the vault.
class _SetupBiometricDialog extends StatefulWidget {
  const _SetupBiometricDialog();

  @override
  State<_SetupBiometricDialog> createState() => _SetupBiometricDialogState();
}

class _SetupBiometricDialogState extends State<_SetupBiometricDialog> {
  final _passwordController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _passwordController.text;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.securitySetupBiometricDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.securitySetupBiometricDialogBody,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: l10n.securityMasterPasswordTitle,
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() => _obscure = !_obscure);
                  },
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.securitySetupBiometricDialogCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.securitySetupBiometricDialogAction),
        ),
      ],
    );
  }
}
