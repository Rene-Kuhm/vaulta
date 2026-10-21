import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/design_system/app_panel.dart';
import '../../../app/localization/l10n.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/security/sensitive_clipboard_service.dart';
import '../domain/otp_auth_uri.dart';
import '../domain/totp.dart';

/// Live one-time-code card for the detail screen of an entry whose
/// [VaultItem.otpAuthUri] is set.
///
/// Renders the issuer and account, the current code split into two
/// groups (the way authenticator apps show it), the seconds left in
/// the current time step, and a copy button. The code refreshes on
/// its own every second.
///
/// The secret only ever lives in memory here: nothing is logged, and
/// the code is plain [Text] rather than a selectable widget so the
/// platform cannot offer a non-sensitive copy path next to the button
/// that goes through [SensitiveClipboardService].
class TotpCodePanel extends StatefulWidget {
  /// Builds the panel for [uri], an `otpauth://totp/...` key URI.
  ///
  /// [clipboardService] defaults to [SensitiveClipboardService.shared]
  /// so copied codes are cleared like any other secret; [clock] lets
  /// tests pin the instant used to compute the code.
  const TotpCodePanel({
    super.key,
    required this.uri,
    this.clipboardService,
    this.clock,
  });

  /// The `otpauth://totp/...` URI stored on the entry.
  final String uri;

  /// Writes copied codes to the clipboard flagged as sensitive.
  /// Defaults to [SensitiveClipboardService.shared].
  final SensitiveClipboardService? clipboardService;

  /// Source of "now". Defaults to [DateTime.now].
  final DateTime Function()? clock;

  @override
  State<TotpCodePanel> createState() => _TotpCodePanelState();
}

class _TotpCodePanelState extends State<TotpCodePanel> {
  late final DateTime Function() _clock = widget.clock ?? DateTime.now;
  late final SensitiveClipboardService _clipboard =
      widget.clipboardService ?? SensitiveClipboardService.shared;

  OtpAuthUri? _entry;
  TotpConfig? _config;
  String _code = '';
  int _secondsRemaining = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    try {
      final parsed = parseOtpAuthUri(widget.uri);
      final config = parsed.totpConfig;
      _entry = parsed;
      _config = config;
      _refresh(notify: false);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    } on FormatException {
      // A stored URI this app cannot read must never render a
      // plausible code; the panel says so instead.
      _entry = null;
      _config = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _refresh({bool notify = true}) {
    final config = _config;
    if (config == null) {
      return;
    }
    final now = _clock();
    final code = generateTotpCode(config, now);
    final remaining = totpSecondsRemaining(config, now);
    if (!notify) {
      _code = code;
      _secondsRemaining = remaining;
      return;
    }
    if (!mounted || (code == _code && remaining == _secondsRemaining)) {
      return;
    }
    setState(() {
      _code = code;
      _secondsRemaining = remaining;
    });
  }

  Future<void> _copyCode() async {
    await _clipboard.copySensitive(_code, onAutoCleared: _showCleared);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final entry = _entry;
    final config = _config;

    if (entry == null || config == null) {
      return AppPanel(
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: AppColors.crimsonBright,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                l10n.totpUnavailable,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }

    final remainingRatio = _secondsRemaining / config.period;

    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.totpTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              const Icon(
                Icons.timer_outlined,
                color: AppColors.crimsonBright,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.issuer ?? entry.account,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (entry.issuer != null)
                      Text(
                        entry.account,
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
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.backgroundDark,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(color: AppColors.borderDark),
            ),
            child: Text(
              _groupCode(_code),
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: AppColors.paperDark,
                letterSpacing: 2.4,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.totpSecondsRemaining(_secondsRemaining),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
            child: LinearProgressIndicator(
              value: remainingRatio,
              minHeight: AppSpacing.xxs,
              backgroundColor: AppColors.borderDark,
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.crimsonBright,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: _copyCode,
            icon: const Icon(Icons.copy_rounded),
            label: Text(l10n.totpCopyCode),
          ),
        ],
      ),
    );
  }

  /// Splits [code] into two equal groups, the way authenticator apps
  /// display it ("123 456", "1234 5678").
  String _groupCode(String code) {
    if (code.length < 2) {
      return code;
    }
    final half = code.length ~/ 2;
    return '${code.substring(0, half)} ${code.substring(half)}';
  }
}
