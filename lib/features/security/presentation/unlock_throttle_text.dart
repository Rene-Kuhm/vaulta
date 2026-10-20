import '../../../core/security/vault_security_controller.dart';
import '../../../l10n/app_localizations.dart';

/// Formats a lockout countdown as `m:ss`, rounding partial seconds
/// up so the display never shows `0:00` while still locked.
String formatLockoutRemaining(Duration remaining) {
  final totalSeconds = (remaining.inMilliseconds + 999) ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Localized reason why the master-password throttle refused the last
/// attempt, or `null` when it did not. Shared by the unlock screen,
/// the biometric setup dialog and the change-password dialog.
String? unlockThrottleMessage(
  AppLocalizations l10n,
  VaultSecurityController controller,
) {
  if (controller.unlockAttemptStateUnavailable) {
    return l10n.securityUnlockStateUnavailable;
  }
  final remaining = controller.unlockLockoutRemaining;
  if (remaining != null) {
    return l10n.securityUnlockLockedOut(formatLockoutRemaining(remaining));
  }
  return null;
}
