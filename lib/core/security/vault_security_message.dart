import 'package:flutter/foundation.dart';

/// Every user-facing status the vault security layer can report.
///
/// The security layer never holds copy. It emits one of these codes and the
/// presentation layer maps it to a localized string, so the same code reads
/// in English on an English device and in Spanish on a Spanish one (see
/// `lib/features/security/presentation/vault_security_message_l10n.dart`).
///
/// The ARB key for a code is `securityMessage` followed by the code name in
/// UpperCamelCase: [VaultSecurityMessageCode.vaultLocked] is
/// `securityMessageVaultLocked`. Every code therefore needs a matching key in
/// both `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb`, which
/// `test/features/security/presentation/vault_security_message_l10n_test.dart`
/// enforces. A browser tab on the security screen is the last place a user
/// should read a language they did not pick, and a missing translation is a
/// silent fallback to the template locale, so the suite — not a reviewer's
/// attention — has to notice.
enum VaultSecurityMessageCode {
  /// The persisted secure state could not be read at all.
  stateUnreadable(isError: true),

  /// The two fields of the create-vault form disagree.
  passwordConfirmationMismatch(isError: true),

  /// The new password and its confirmation disagree.
  newPasswordConfirmationMismatch(isError: true),

  /// Reusing the current master password is refused.
  newPasswordMustDifferFromCurrent(isError: true),

  /// The master password is shorter than the policy minimum.
  masterPasswordTooShort(isError: true),

  /// The master password is longer than the policy maximum.
  masterPasswordTooLong(isError: true),

  /// The master password appears in a breached-password list.
  masterPasswordBreached(isError: true),

  /// This device or build cannot offer biometrics.
  biometricNotAvailableOnDevice(isError: true),

  /// Biometrics cannot be tried because nothing is enrolled on the device.
  biometricNotEnrolled(isError: true),

  /// No master password record exists on this device yet.
  noMasterPasswordConfigured(isError: true),

  /// The submitted master password does not match the record.
  passwordMismatch(isError: true),

  /// The submitted current password does not match the record.
  currentPasswordMismatch(isError: true),

  /// The biometric unlock path is not wired into this build.
  biometricUnlockNotWired(isError: true),

  /// The platform rejected the biometric prompt itself.
  biometricIdentityRejected(isError: true),

  /// The platform refused to release the wrapped key.
  biometricKeyRejected(isError: true),

  /// The platform released a wrapped key that does not open the envelope.
  biometricKeyInconsistent(isError: true),

  /// The biometric path could not recover a session.
  biometricSessionRecoveryFailed(isError: true),

  /// The stored key cannot be unwrapped: the vault cannot be opened.
  ///
  /// Reported instead of a raw exception when a record carries a missing or
  /// corrupt wrapped DEK. The user needs one clear sentence, not a stack
  /// trace from the crypto layer.
  vaultCannotBeOpened(isError: true),

  /// The record needs re-encryption before biometrics can be enrolled.
  masterPasswordNeedsMigration(isError: true),

  /// Preparing the platform-protected envelope failed.
  biometricEnrollmentFailed(isError: true),

  /// The vault must be unlocked before the master password can change.
  unlockBeforeChangingMasterPassword(isError: true),

  /// The session the caller expects is no longer in memory.
  sessionNotInMemory(isError: true),

  /// The in-memory session does not match the live record.
  sessionRecordKeyMismatch(isError: true),

  /// Re-encrypting every entry failed; the old key was kept.
  rekeyFailed(isError: true),

  /// Persisting the new record failed; the old key was kept.
  recordSaveFailed(isError: true),

  /// The record write and its rollback both failed; the vault is locked.
  rekeyRollbackFailed(isError: true),

  /// The legacy record rewrite could not be rolled back; the vault is locked.
  recordMigrationRollbackFailed(isError: true),

  /// The stored items could not be upgraded to the current payload format.
  itemsMigrationFailed(isError: true),

  /// A new master password record was created.
  masterPasswordCreated(isError: false),

  /// The master password was changed and the vault re-encrypted.
  masterPasswordChanged(isError: false),

  /// The vault is unlocked.
  vaultUnlocked(isError: false),

  /// The vault is unlocked and the record was upgraded.
  vaultUnlockedAndMigrated(isError: false),

  /// The vault is unlocked; the item upgrade will be retried later.
  vaultUnlockedMigrationDeferred(isError: false),

  /// The vault is unlocked through biometrics.
  vaultUnlockedWithBiometrics(isError: false),

  /// The user has to unlock with the password once before biometrics work.
  biometricNeedsPasswordFirst(isError: false),

  /// Biometric unlock was turned on.
  biometricEnabled(isError: false),

  /// Biometric unlock was turned off.
  biometricDisabled(isError: false),

  /// The biometric unlock envelope is enrolled and ready.
  biometricEnrollmentReady(isError: false),

  /// The vault is locked.
  vaultLocked(isError: false),

  /// The vault locked itself because the app left the foreground.
  vaultLockedOnBackground(isError: false),

  /// The vault locked itself after the idle timeout.
  vaultLockedOnIdle(isError: false),

  /// The vault locked because this device's session was revoked.
  vaultLockedSessionRevoked(isError: false),

  /// The vault locked because every session of the account was revoked.
  vaultLockedAllSessionsRevoked(isError: false),

  /// Auto-lock on background was turned on.
  autoLockBackgroundEnabled(isError: false),

  /// Auto-lock on background was turned off.
  autoLockBackgroundDisabled(isError: false),

  /// The idle auto-lock was turned on.
  idleTimeoutEnabled(isError: false),

  /// The idle auto-lock was turned off.
  idleTimeoutDisabled(isError: false);

  const VaultSecurityMessageCode({required this.isError});

  /// True when this code reports a failure rather than a confirmation. The
  /// UI renders an error tone and an error icon for it, so the classification
  /// lives with the code instead of being guessed from the wording.
  final bool isError;
}

/// A status message: a [VaultSecurityMessageCode] plus the optional machine
/// [detail] that its localized string interpolates.
///
/// [detail] is data, never copy: a count, a number of seconds, or a
/// diagnostic token such as `ensure_key_failed:KEYSTORE_ERROR`. The sentence
/// around it comes from the ARB files.
@immutable
class VaultSecurityMessage {
  /// Builds a message for [code], optionally carrying [detail].
  const VaultSecurityMessage(this.code, {this.detail});

  /// Which message this is.
  final VaultSecurityMessageCode code;

  /// Machine detail the localized string interpolates, or `null`.
  final String? detail;

  /// True when the message reports a failure. See
  /// [VaultSecurityMessageCode.isError].
  bool get isError => code.isError;

  @override
  bool operator ==(Object other) =>
      other is VaultSecurityMessage &&
      other.code == code &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(code, detail);

  @override
  String toString() => detail == null
      ? 'VaultSecurityMessage($code)'
      : 'VaultSecurityMessage($code, $detail)';
}
