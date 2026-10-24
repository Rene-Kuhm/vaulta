import '../../../core/security/vault_security_message.dart';
import '../../../l10n/app_localizations.dart';

/// Resolves a [VaultSecurityMessage] to the string the user reads.
///
/// This is the only place a security status becomes copy. The security layer
/// emits codes ([VaultSecurityMessageCode]) so an English device shows
/// English on the security gate, the biometric setup dialog and the settings
/// screen instead of the Spanish literals the controller used to hold.
///
/// The ARB key for a code is `securityMessage` plus the code name in
/// UpperCamelCase, which is what [vaultSecurityMessageArbKey] returns and what
/// `test/features/security/presentation/vault_security_message_l10n_test.dart`
/// checks against both locale files. A code whose copy is missing from
/// `app_es.arb` would otherwise fall back to English silently.
String vaultSecurityMessageText(
  AppLocalizations l10n,
  VaultSecurityMessage message,
) {
  switch (message.code) {
    case VaultSecurityMessageCode.stateUnreadable:
      return l10n.securityMessageStateUnreadable;
    case VaultSecurityMessageCode.passwordConfirmationMismatch:
      return l10n.securityMessagePasswordConfirmationMismatch;
    case VaultSecurityMessageCode.newPasswordConfirmationMismatch:
      return l10n.securityMessageNewPasswordConfirmationMismatch;
    case VaultSecurityMessageCode.newPasswordMustDifferFromCurrent:
      return l10n.securityMessageNewPasswordMustDifferFromCurrent;
    case VaultSecurityMessageCode.masterPasswordTooShort:
      return l10n.securityMessageMasterPasswordTooShort(message.detail ?? '');
    case VaultSecurityMessageCode.masterPasswordTooLong:
      return l10n.securityMessageMasterPasswordTooLong(message.detail ?? '');
    case VaultSecurityMessageCode.masterPasswordBreached:
      return l10n.securityMessageMasterPasswordBreached;
    case VaultSecurityMessageCode.biometricNotAvailableOnDevice:
      return l10n.securityMessageBiometricNotAvailableOnDevice;
    case VaultSecurityMessageCode.biometricNotEnrolled:
      return l10n.securityMessageBiometricNotEnrolled;
    case VaultSecurityMessageCode.noMasterPasswordConfigured:
      return l10n.securityMessageNoMasterPasswordConfigured;
    case VaultSecurityMessageCode.passwordMismatch:
      return l10n.securityMessagePasswordMismatch;
    case VaultSecurityMessageCode.currentPasswordMismatch:
      return l10n.securityMessageCurrentPasswordMismatch;
    case VaultSecurityMessageCode.biometricUnlockNotWired:
      return l10n.securityMessageBiometricUnlockNotWired;
    case VaultSecurityMessageCode.biometricIdentityRejected:
      return l10n.securityMessageBiometricIdentityRejected;
    case VaultSecurityMessageCode.biometricKeyRejected:
      return l10n.securityMessageBiometricKeyRejected(
        message.detail ?? 'unknown',
      );
    case VaultSecurityMessageCode.biometricKeyInconsistent:
      return l10n.securityMessageBiometricKeyInconsistent;
    case VaultSecurityMessageCode.biometricSessionRecoveryFailed:
      return l10n.securityMessageBiometricSessionRecoveryFailed;
    case VaultSecurityMessageCode.vaultCannotBeOpened:
      return l10n.securityMessageVaultCannotBeOpened;
    case VaultSecurityMessageCode.masterPasswordNeedsMigration:
      return l10n.securityMessageMasterPasswordNeedsMigration;
    case VaultSecurityMessageCode.biometricEnrollmentFailed:
      return l10n.securityMessageBiometricEnrollmentFailed(
        message.detail ?? 'unknown',
      );
    case VaultSecurityMessageCode.unlockBeforeChangingMasterPassword:
      return l10n.securityMessageUnlockBeforeChangingMasterPassword;
    case VaultSecurityMessageCode.sessionNotInMemory:
      return l10n.securityMessageSessionNotInMemory;
    case VaultSecurityMessageCode.sessionRecordKeyMismatch:
      return l10n.securityMessageSessionRecordKeyMismatch;
    case VaultSecurityMessageCode.rekeyFailed:
      return l10n.securityMessageRekeyFailed;
    case VaultSecurityMessageCode.recordSaveFailed:
      return l10n.securityMessageRecordSaveFailed;
    case VaultSecurityMessageCode.rekeyRollbackFailed:
      return l10n.securityMessageRekeyRollbackFailed;
    case VaultSecurityMessageCode.recordMigrationRollbackFailed:
      return l10n.securityMessageRecordMigrationRollbackFailed;
    case VaultSecurityMessageCode.itemsMigrationFailed:
      return l10n.securityMessageItemsMigrationFailed;
    case VaultSecurityMessageCode.masterPasswordCreated:
      return l10n.securityMessageMasterPasswordCreated;
    case VaultSecurityMessageCode.masterPasswordChanged:
      return l10n.securityMessageMasterPasswordChanged;
    case VaultSecurityMessageCode.vaultUnlocked:
      return l10n.securityMessageVaultUnlocked;
    case VaultSecurityMessageCode.vaultUnlockedAndMigrated:
      return l10n.securityMessageVaultUnlockedAndMigrated;
    case VaultSecurityMessageCode.vaultUnlockedMigrationDeferred:
      return l10n.securityMessageVaultUnlockedMigrationDeferred;
    case VaultSecurityMessageCode.vaultUnlockedWithBiometrics:
      return l10n.securityMessageVaultUnlockedWithBiometrics;
    case VaultSecurityMessageCode.biometricNeedsPasswordFirst:
      return l10n.securityMessageBiometricNeedsPasswordFirst;
    case VaultSecurityMessageCode.biometricEnabled:
      return l10n.securityMessageBiometricEnabled;
    case VaultSecurityMessageCode.biometricDisabled:
      return l10n.securityMessageBiometricDisabled;
    case VaultSecurityMessageCode.biometricEnrollmentReady:
      return l10n.securityMessageBiometricEnrollmentReady;
    case VaultSecurityMessageCode.vaultLocked:
      // The only detail-bearing variant: the device-revocation bridge in
      // `lib/app/bootstrap/password_manager_app.dart` still passes a
      // pre-formatted sentence from the sync layer, which is shown after the
      // localized line until that bridge emits a message code of its own.
      final reason = message.detail;
      return reason == null
          ? l10n.securityMessageVaultLocked
          : l10n.securityMessageVaultLockedWithReason(reason);
    case VaultSecurityMessageCode.vaultLockedOnBackground:
      return l10n.securityMessageVaultLockedOnBackground;
    case VaultSecurityMessageCode.vaultLockedOnIdle:
      return l10n.securityMessageVaultLockedOnIdle;
    case VaultSecurityMessageCode.vaultLockedSessionRevoked:
      return l10n.securityMessageVaultLockedSessionRevoked;
    case VaultSecurityMessageCode.vaultLockedAllSessionsRevoked:
      return l10n.securityMessageVaultLockedAllSessionsRevoked;
    case VaultSecurityMessageCode.autoLockBackgroundEnabled:
      return l10n.securityMessageAutoLockBackgroundEnabled;
    case VaultSecurityMessageCode.autoLockBackgroundDisabled:
      return l10n.securityMessageAutoLockBackgroundDisabled;
    case VaultSecurityMessageCode.idleTimeoutEnabled:
      return l10n.securityMessageIdleTimeoutEnabled(
        _formatIdleTimeout(int.tryParse(message.detail ?? '') ?? 0),
      );
    case VaultSecurityMessageCode.idleTimeoutDisabled:
      return l10n.securityMessageIdleTimeoutDisabled;
  }
}

/// ARB key backing [code], derived from the enum name by convention.
///
/// Kept next to [vaultSecurityMessageText] so the localization test can check
/// every key against both `.arb` files without duplicating that table: the
/// switch above is exhaustive by construction, and the key this returns is the
/// one the generated getter reads.
String vaultSecurityMessageArbKey(VaultSecurityMessageCode code) {
  final name = code.name;
  return 'securityMessage${name[0].toUpperCase()}${name.substring(1)}';
}

/// Renders an idle-timeout length for the "{duration}" placeholder. Units are
/// numbers plus a short unit token, not prose, so they do not need an ARB entry.
String _formatIdleTimeout(int seconds) {
  if (seconds < 60) {
    return '${seconds}s';
  }
  return '${seconds ~/ 60} min';
}
