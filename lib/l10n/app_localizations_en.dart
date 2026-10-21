// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Vaulta';

  @override
  String get navVault => 'Vault';

  @override
  String get navAccess => 'Access';

  @override
  String get navSettings => 'Settings';

  @override
  String get brandFooter => 'Tecnodespegue.com';

  @override
  String get languageSectionTitle => 'Language';

  @override
  String get languageSelectorLabel => 'App language';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSpanish => 'Spanish';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutCreator => 'Created by René Kuhm, founder of Tecnodespegue.';

  @override
  String get aboutAgency => 'Tecnodespegue.com';

  @override
  String get settingsLocalUnlockPostureTitle => 'Local unlock posture';

  @override
  String get settingsLocalUnlockPostureDescription => 'Vaulta keeps sensitive state in Keychain / Keystore. On Android, biometrics unlock the vault through a hardware-protected key; other platforms still use the master password path.';

  @override
  String get settingsMasterPasswordCreated => 'Master password created';

  @override
  String get settingsBiometricsAvailable => 'Biometrics available';

  @override
  String get settingsBiometricsEnabled => 'Biometrics enabled';

  @override
  String get settingsUnlockWithBiometrics => 'Use biometrics to unlock on Android';

  @override
  String settingsBiometricSupportedSubtitle(Object biometricLabel) {
    return 'Use $biometricLabel to unlock the vault on Android. The master password is still required for recovery, activation, or biometric re-enrollment.';
  }

  @override
  String get settingsBiometricUnavailableSubtitle => 'Biometrics are not configured or supported in this environment.';

  @override
  String get settingsAutoLockBackgroundTitle => 'Auto-lock on background';

  @override
  String get settingsAutoLockBackgroundSubtitle => 'Locks Vaulta automatically if the app becomes inactive, paused, or detached.';

  @override
  String get settingsIdleTimeoutLabel => 'Foreground idle auto-lock';

  @override
  String get settingsLockNow => 'Lock now';

  @override
  String get settingsChangeMasterPassword => 'Change master password';

  @override
  String get settingsSessionsTitle => 'Devices and sessions';

  @override
  String get settingsSessionsSubtitle => 'You can revoke one device or cut every other active session.';

  @override
  String get settingsSessionsRefresh => 'Refresh sessions';

  @override
  String get settingsRevokeOtherDevices => 'Revoke all other sessions';

  @override
  String get settingsRevokeDevice => 'Revoke device';

  @override
  String get settingsRevokeCurrentDeviceTitle => 'Revoke this device?';

  @override
  String get settingsRevokeCurrentDeviceBody => 'Revoking the current device will immediately lock this session. You will need to unlock again to continue.';

  @override
  String get settingsRevokeNow => 'Revoke now';

  @override
  String get settingsRevokeDeviceError => 'We could not revoke this device. Please retry in a few seconds.';

  @override
  String get settingsRevokedAllTitle => 'Session revoked on all devices';

  @override
  String get settingsRevokedAllBody => 'Your account access was revoked for all sessions. This device will lock now for safety.';

  @override
  String get settingsCurrentDeviceRevokedTitle => 'Current device revoked';

  @override
  String get settingsCurrentDeviceRevokedBody => 'This device no longer has an active session. Vaulta will lock now for safety.';

  @override
  String get settingsNoDevices => 'No registered devices for this user.';

  @override
  String get settingsCurrentDeviceLabel => 'This device';

  @override
  String get settingsSessionStatusActive => 'Active';

  @override
  String get settingsSessionStatusRevoked => 'Revoked';

  @override
  String get settingsDeviceNeverSeen => 'No activity recorded';

  @override
  String get settingsDeviceRevokedMessage => 'Device revoked successfully.';

  @override
  String get settingsRevokeOthersDone => 'Other active sessions were revoked.';

  @override
  String get settingsRevokeOthersFailed => 'We could not revoke other sessions. Please retry in a few seconds.';

  @override
  String get settingsRoadmapTitle => 'Platform security roadmap';

  @override
  String get settingsRoadmapNotes => 'Vault items use ADR-001 payload v4: Argon2id derives a KEK from the master password, a random DEK unlocks the vault, and every item is then sealed with AES-256-GCM under its own key, with the ciphertext bound to its record id, item key id, item key version and IV. Android recovers the DEK with biometrics through a KeyStore key; iOS/macOS bindings remain pending.';

  @override
  String get settingsSecureStorage => 'Secure storage';

  @override
  String get settingsBiometricUnlock => 'Biometric key recovery';

  @override
  String get settingsHardwareBackedKeys => 'KeyStore-held key';

  @override
  String get settingsVaultEncryptionReady => 'Vault item encryption wired end-to-end';

  @override
  String get settingsCapabilitySupported => 'Available';

  @override
  String get settingsCapabilityUnsupported => 'Not available';

  @override
  String get settingsCapabilityUnknown => 'Could not determine';

  @override
  String get settingsConflictsTitle => 'Sync conflicts';

  @override
  String get settingsConflictsEmpty => 'No pending conflicts. Sync queue is clean.';

  @override
  String get settingsConflictsRefresh => 'Refresh';

  @override
  String get settingsConflictsLoadError => 'We could not load sync conflicts. Please retry.';

  @override
  String get settingsSessionsLoadError => 'We could not load device sessions. Please retry.';

  @override
  String get settingsConflictsKindConflict => 'Conflict';

  @override
  String get settingsConflictsReasonFallback => 'CAS conflict detected while pushing mutation.';

  @override
  String settingsConflictsVersionRow(Object expected, Object remote) {
    return 'Local base v$expected · Remote v$remote';
  }

  @override
  String settingsDeviceStatusLabel(Object code) {
    return 'status: $code';
  }

  @override
  String get settingsDeviceRevokeHint => 'If you revoke this device, Vaulta will lock immediately.';

  @override
  String get idleNever => 'Never';

  @override
  String get idleDisabled => 'Disabled';

  @override
  String get idleOneMinute => '1 minute';

  @override
  String get idleFiveMinutes => '5 minutes';

  @override
  String get idleFifteenMinutes => '15 minutes';

  @override
  String get idleStrict => 'Strict';

  @override
  String get idleRecommended => 'Recommended';

  @override
  String get idleRelaxed => 'Relaxed';

  @override
  String get changeMasterPasswordTitle => 'Change master password';

  @override
  String get changeMasterPasswordCurrent => 'Current master password';

  @override
  String get changeMasterPasswordNew => 'New master password';

  @override
  String get changeMasterPasswordConfirm => 'Confirm new master password';

  @override
  String get changeMasterPasswordHint => 'This re-encrypts the entire vault with a new key.';

  @override
  String get cancel => 'Cancel';

  @override
  String get apply => 'Apply';

  @override
  String get masterPasswordUpdatedSuccess => 'Master password updated successfully.';

  @override
  String get changeMasterPasswordErrorFallback => 'We could not change the master password. Review the data and try again.';

  @override
  String get securityOnboardingEyebrow => 'Secure onboarding';

  @override
  String get securityOnboardingTitle => 'We create your master key with no dangerous shortcuts.';

  @override
  String get securityOnboardingSubtitle => 'The master password validates local access and derives the key that encrypts vault items.';

  @override
  String get securityMasterPasswordTitle => 'Master password';

  @override
  String get securityMasterPasswordDescription => 'Use 12+ characters with real variety. Never store this key in plaintext.';

  @override
  String get securityMasterPasswordRequired => 'A master password is required.';

  @override
  String get securityMasterPasswordMinLength => 'Use at least 12 characters.';

  @override
  String get securityMasterPasswordMismatch => 'The confirmation does not match the master password.';

  @override
  String get securityCreateMasterPassword => 'Create master password';

  @override
  String get securityConfirmMasterPassword => 'Confirm master password';

  @override
  String get securityChecklistHash => 'Argon2id verifies the master password.';

  @override
  String get securityChecklistDerive => 'Argon2id derives a KEK that unwraps a random vault DEK.';

  @override
  String get securityChecklistEncrypt => 'Local items are encrypted with AES-256-GCM and records are stored with Keychain / Keystore.';

  @override
  String get securityEnableBiometrics => 'Enable local biometrics';

  @override
  String securityBiometricAvailable(Object biometricLabel) {
    return 'Enable $biometricLabel to unlock Vaulta on Android. The master password remains the recovery and re-enrollment path.';
  }

  @override
  String get securityBiometricUnavailable => 'Biometric unlock is unavailable: no biometrics are enrolled, or this Android version cannot require a biometric. You can still unlock with your master password.';

  @override
  String get securityShowPassword => 'Show password';

  @override
  String get securityHidePassword => 'Hide password';

  @override
  String get securityCreateSecureAccess => 'Create secure vault access';

  @override
  String get securityUnlockEyebrow => 'Unlock';

  @override
  String get securityUnlockTitle => 'Your vault stays closed until real identity is verified.';

  @override
  String securityUnlockBiometricSubtitle(Object biometricLabel) {
    return 'Use your master password or the biometrics already enabled on this device.';
  }

  @override
  String get securityUnlockPasswordSubtitle => 'Use your master password to recover access.';

  @override
  String get securityUnlockBiometricHint => 'Type your master password or tap the fingerprint button to unlock.';

  @override
  String get securityUnlockPasswordHint => 'Type your master password to unlock the vault.';

  @override
  String securityUnlockLockedOut(String time) {
    return 'Too many failed attempts. Try again in $time.';
  }

  @override
  String get securityUnlockStateUnavailable => 'Vaulta could not record this attempt in secure storage, so the password was not checked. Try again; if it keeps happening, restart the app.';

  @override
  String get securityProtectedAccess => 'Protected access';

  @override
  String get securityUnlockVault => 'Unlock vault';

  @override
  String get securityBiometricButton => 'Biometric';

  @override
  String get dashboardDecryptError => 'Vaulta could not decrypt the local vault right now.';

  @override
  String get dashboardDecryptErrorAdvice => 'Lock and unlock again with your master password, then retry. Details are hidden to avoid leaking sensitive state.';

  @override
  String get entryDetailTitle => 'Entry detail';

  @override
  String get entryEditTooltip => 'Edit entry';

  @override
  String get entryDeleteTooltip => 'Delete entry';

  @override
  String get entryUsernameLabel => 'Username';

  @override
  String get entryWebsiteLabel => 'Website';

  @override
  String get entryStrengthLabel => 'Strength';

  @override
  String get entryUpdatedLabel => 'Updated';

  @override
  String get entrySecretTitle => 'Secret';

  @override
  String get entryShowSecret => 'Show';

  @override
  String get entryHideSecret => 'Hide';

  @override
  String get copySecret => 'Copy secret';

  @override
  String get secretCopiedLocally => 'Secret copied. The clipboard will be cleared in 30 seconds if unchanged.';

  @override
  String get clipboardCleared => 'Clipboard cleared.';

  @override
  String get entryPasswordHistoryTitle => 'Previous passwords';

  @override
  String get entryPasswordHistoryHint => 'Older passwords kept when you change the secret. Newest first.';

  @override
  String get entryPasswordHistoryCopyTooltip => 'Copy previous password';

  @override
  String get entryPasswordHistoryRevealTooltip => 'Show previous password';

  @override
  String get entryPasswordHistoryHideTooltip => 'Hide previous password';

  @override
  String get totpTitle => 'One-time code';

  @override
  String get totpCopyCode => 'Copy code';

  @override
  String totpSecondsRemaining(int seconds) {
    return '${seconds}s remaining';
  }

  @override
  String get totpUnavailable => 'This entry\'s one-time code could not be read.';

  @override
  String get entryNotesTitle => 'Notes';

  @override
  String get entryDeleteDialogTitle => 'Delete entry?';

  @override
  String get entryDeleteDialogBody => 'This removes the encrypted record from the local vault. Remote recovery is not available in offline mode.';

  @override
  String get entryDeleteConfirm => 'Delete';

  @override
  String get retry => 'Retry';

  @override
  String get newEntry => 'New entry';

  @override
  String get entryCreatedMessage => 'Encrypted entry created.';

  @override
  String get vaultUpdatedMessage => 'Vault updated locally.';

  @override
  String get dashboardSubtitle => 'Your encrypted control room';

  @override
  String get dashboardHeroTitle => 'Protected by system hardware';

  @override
  String get dashboardHeroBody => 'The local vault encrypts every entry with AES-256-GCM. Local CRUD, search, filters, and password generation are ready; remote sync remains optional and experimental.';

  @override
  String dashboardPillTrustedDevices(int count) {
    return '$count devices trusted';
  }

  @override
  String get dashboardPillSyncEnabled => 'Secure sync on';

  @override
  String get dashboardPillSyncDisabled => 'Offline encrypted vault';

  @override
  String dashboardPillWeakNeedRotation(int count) {
    return '$count passwords need rotation';
  }

  @override
  String get dashboardQuickActionsEyebrow => 'Action';

  @override
  String get securityScore => 'Security score';

  @override
  String get vaultEntries => 'Vault entries';

  @override
  String get weakPasswords => 'Weak passwords';

  @override
  String get reusedItems => 'Reused items';

  @override
  String get trustedDevices => 'Trusted devices';

  @override
  String get priorityActions => 'Priority actions';

  @override
  String get dashboardQuickActionsSummary => 'The vault is now real: create, edit, view details, and delete with encryption preserved end-to-end.';

  @override
  String get createEncryptedEntry => 'Create encrypted entry';

  @override
  String get createEncryptedEntrySubtitle => 'Add new credentials and store them encrypted at rest.';

  @override
  String get planNextHardeningStep => 'Plan next hardening step';

  @override
  String get dashboardRoadmapSyncEnabled => 'Remote sync is experimental and requires a configured Supabase session.';

  @override
  String get dashboardRoadmapSyncDisabled => 'Offline-first release: local vault, search, filters, and generator are available without cloud sync.';

  @override
  String get vaultEntriesSectionTitle => 'Vault entries';

  @override
  String get searchVault => 'Search title, username, or website';

  @override
  String get filter => 'Filter';

  @override
  String get filterAllEntries => 'All entries';

  @override
  String get filterWeakOnly => 'Weak passwords only';

  @override
  String get filterWithNotes => 'Entries with notes';

  @override
  String get resetFilters => 'Reset filters';

  @override
  String get noResultsTitle => 'No entries match your current filters';

  @override
  String get noResultsSubtitle => 'Try a different query or reset filters to see all items again.';

  @override
  String get emptyVaultTitle => 'Your vault is empty';

  @override
  String get emptyVaultSubtitle => 'Create your first entry and Vaulta encrypts it before persisting.';

  @override
  String get createFirstEntry => 'Create first entry';

  @override
  String itemsTotal(int count) {
    return '$count total';
  }

  @override
  String itemsShownOfTotal(int shown, int total) {
    return '$shown shown - $total total';
  }

  @override
  String get editorTitleEdit => 'Edit entry';

  @override
  String get editorTitleNew => 'New entry';

  @override
  String get editorIdentityTitle => 'Identity';

  @override
  String get editorTitleLabel => 'Title';

  @override
  String get editorTitleHint => 'GitHub, banking, Wi-Fi...';

  @override
  String get editorTitleValidation => 'Give this entry a clear title.';

  @override
  String get editorUsernameLabel => 'Username or email';

  @override
  String get editorUsernameValidation => 'Add the account identifier.';

  @override
  String get editorCategoryLabel => 'Category';

  @override
  String get editorCategoryWork => 'Work';

  @override
  String get editorCategoryFinance => 'Finance';

  @override
  String get editorCategoryPersonal => 'Personal';

  @override
  String get editorCategoryInfrastructure => 'Infrastructure';

  @override
  String get editorSecretTitle => 'Secret';

  @override
  String get editorSecretDescription => 'Vaulta recalculates strength locally before re-encrypting the entry.';

  @override
  String get editorSecretLabel => 'Password or secret';

  @override
  String get editorSecretRequiredValidation => 'Store a real secret, not an empty field.';

  @override
  String get editorSecretMinValidation => 'Use at least 8 characters.';

  @override
  String get editorGeneratorTitle => 'Password generator';

  @override
  String editorGeneratorChars(int count) {
    return '$count chars';
  }

  @override
  String get editorGenerateInsert => 'Generate and insert';

  @override
  String get editorWebsiteLabel => 'Website or app';

  @override
  String get editorWebsiteHint => 'https://example.com';

  @override
  String get editorNotesLabel => 'Notes';

  @override
  String get editorNotesHint => 'Recovery codes, context, reminders...';

  @override
  String get editorSaveChanges => 'Save changes';

  @override
  String get editorCreateEntry => 'Create entry';

  @override
  String get editorGeneratorSetRequired => 'Choose at least one character set to generate.';

  @override
  String get editorGeneratedInserted => 'Generated password inserted.';

  @override
  String get syncConflictsTitle => 'Sync conflicts';

  @override
  String get syncConflictsSubtitle => 'A remote change arrived while your local edit was pending. Choose which version to keep.';

  @override
  String get syncConflictsEmpty => 'No pending conflicts. Everything is in sync.';

  @override
  String get syncConflictsLoadError => 'We could not load pending conflicts. Please retry.';

  @override
  String get syncConflictResolveError => 'We could not resolve this conflict. Please retry.';

  @override
  String syncConflictsBannerLabel(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'conflicts',
      one: 'conflict',
    );
    return '$count sync $_temp0 pending';
  }

  @override
  String get syncConflictsBannerAction => 'Review';

  @override
  String get syncConflictLocalVersion => 'Your version';

  @override
  String get syncConflictRemoteVersion => 'Remote version';

  @override
  String get syncConflictKeepLocal => 'Keep mine';

  @override
  String get syncConflictKeepRemote => 'Use remote';

  @override
  String get syncConflictKindUpsert => 'Edit conflict';

  @override
  String get syncConflictKindDelete => 'Delete conflict';

  @override
  String get biometricSlotExpired => 'The biometric vault key is not ready or was invalidated. Enter your master password and enable biometrics again.';

  @override
  String get biometricUnlockSuccess => 'Biometric verification accepted.';

  @override
  String get biometricEnrollCta => 'Set up biometrics on this device';

  @override
  String get biometricEnrollSubtitle => 'Your device has no biometric enrolled (fingerprint or face unlock). Open the system settings to enable it.';

  @override
  String get biometricEnrollAction => 'Open settings';

  @override
  String get biometricEnrollUnavailable => 'Biometrics are not available on this device. Use the master password to unlock.';

  @override
  String get securitySetupBiometricCta => 'Enable biometric unlock';

  @override
  String get securitySetupBiometricDialogTitle => 'Enable biometric unlock';

  @override
  String get securitySetupBiometricDialogBody => 'Enter your master password once so Vaulta can wrap the key that protects your fingerprint.';

  @override
  String get securitySetupBiometricDialogAction => 'Enable';

  @override
  String get securitySetupBiometricDialogCancel => 'Cancel';

  @override
  String get securitySetupBiometricSuccess => 'Done. Next time you can unlock Vaulta with your fingerprint.';

  @override
  String get securitySetupBiometricError => 'We could not enable the fingerprint. Verify your master password and try again.';

  @override
  String get updateTitle => 'Updates';

  @override
  String get updateInstalled => 'Installed';

  @override
  String get updateRemote => 'Remote';

  @override
  String get updateDescription => 'Stable versions are published from tagged releases. Before installing, every download is checked against the release SHA-256 checksums and the app signing certificate.';

  @override
  String get updateCheck => 'Check for updates';

  @override
  String get updateChecking => 'Checking...';

  @override
  String get updateDownload => 'Download and install';

  @override
  String get updateDownloading => 'Downloading APK...';

  @override
  String get updateInstalling => 'Opening installer...';

  @override
  String get updateRetry => 'Retry';

  @override
  String get updateUpToDateTitle => 'Up to date';

  @override
  String get updateUpToDateBody => 'The installed build matches the latest release on this channel.';

  @override
  String get updateErrorTitle => 'We could not check for updates';

  @override
  String get updateInstallerFailed => 'We could not open the system installer. Verify that \"Unknown sources\" is enabled.';

  @override
  String updateAvailableVersion(Object tag) {
    return 'New version $tag';
  }

  @override
  String updateReleaseId(Object id) {
    return 'release #$id';
  }

  @override
  String updateAvailableBanner(Object tag) {
    return 'New version $tag is available';
  }

  @override
  String get updateActionUpdate => 'Update';

  @override
  String get updateDevChannelTitle => 'Dev channel';

  @override
  String get updateDevChannelSubtitle => 'Receive the rolling build published on every change to master. Less tested than stable releases; downloads are still verified.';

  @override
  String get updateChecksumMissing => 'Update refused: the release does not publish a SHA-256 checksum for this APK, so it cannot be verified.';

  @override
  String get updateChecksumMismatch => 'Update refused: the downloaded APK does not match the published SHA-256 checksum. It was deleted.';

  @override
  String get updateSignatureMismatch => 'Update refused: the downloaded APK is not signed with the same certificate as the installed app. It was deleted.';

  @override
  String get updateInstallPrompt => 'Confirm the installation on the system screen.';

  @override
  String get updateInstallFailed => 'We could not open the installer. Enable \"Unknown sources\" in Settings and try again.';

  @override
  String updateGenericError(Object error) {
    return 'Update failed: $error';
  }

  @override
  String get accessEyebrow => 'Autofill & access';

  @override
  String get accessTitle => 'Autofill is on the way';

  @override
  String get accessSubtitle => 'Vaulta cannot fill passwords in other apps yet. This screen will walk you through the setup as soon as the Android autofill service ships.';

  @override
  String get accessHeroTitle => 'Autofill: coming soon';

  @override
  String get accessHeroBody => 'Until then, open the entry in Vaulta and copy the secret. Copied secrets are cleared from the clipboard automatically.';

  @override
  String get accessPlatformAndroid => 'Android first';

  @override
  String get accessComingSoon => 'Coming soon';

  @override
  String get accessStatusTitle => 'Not available in this version';

  @override
  String get accessStatusBody => 'This build does not register an Android autofill service, so Vaulta will not appear under Settings → Autofill service yet. Nothing on this screen changes your system settings.';

  @override
  String get accessUnlockPostureTitle => 'Unlock posture';

  @override
  String get accessUnlockPostureBody => 'When autofill ships, its requests will be gated by the same unlock state as the rest of the app.';

  @override
  String get accessUnlocked => 'Vault is unlocked';

  @override
  String get accessLocked => 'Vault is locked';

  @override
  String get accessLockNow => 'Lock vault now';

  @override
  String get accessRoadmapTitle => 'What\'s next';

  @override
  String get accessRoadmapBody => 'Next up: a native Android autofill service that reuses this screen. iOS and desktop autofill come after it.';

  @override
  String get accessPlatformBiometrics => 'Biometric unlock';

  @override
  String get accessPlatformOffline => 'Offline by default';

  @override
  String get accessSetupTitle => 'Setup in three steps';

  @override
  String get accessSetupSubtitle => 'On Android 11 and above the platform exposes an Autofill service that Vaulta can plug into.';

  @override
  String get accessSetupStep1Title => 'Open Android settings';

  @override
  String get accessSetupStep1Body => 'Go to System → Languages & input → Autofill service.';

  @override
  String get accessSetupStep2Title => 'Pick Vaulta';

  @override
  String get accessSetupStep2Body => 'Select Vaulta as the active service. Android will ask for confirmation.';

  @override
  String get accessSetupStep3Title => 'Unlock and approve';

  @override
  String get accessSetupStep3Body => 'Next time you tap a password field, Vaulta prompts for biometrics or master password and fills the right entry.';

  @override
  String get backupSectionTitle => 'Encrypted backup';

  @override
  String get backupSectionSubtitle => 'Export your vault to an encrypted .vaulta file so you can restore it on a new device. Keep the file somewhere other than this device.';

  @override
  String get backupExportAction => 'Export backup';

  @override
  String get backupRestoreAction => 'Restore backup';

  @override
  String get backupExportTitle => 'Export encrypted backup';

  @override
  String get backupReauthBody => 'Re-enter your master password to export the vault.';

  @override
  String get backupMasterPasswordLabel => 'Master password';

  @override
  String get backupContinue => 'Continue';

  @override
  String get backupMasterPasswordMismatch => 'The master password does not match.';

  @override
  String backupItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'The backup will contain $count entries.',
      one: 'The backup will contain 1 entry.',
    );
    return '$_temp0';
  }

  @override
  String get backupPasswordLabel => 'Backup password';

  @override
  String get backupPasswordConfirmLabel => 'Confirm backup password';

  @override
  String get backupPasswordHint => 'At least 12 characters, and not a password that already appears in leaked-password lists. A passphrase works best.';

  @override
  String get backupPasswordWarning => 'Vaulta cannot recover the backup password. If you forget it, nobody can open this backup, not even you.';

  @override
  String backupPasswordTooShort(int min) {
    return 'Use at least $min characters.';
  }

  @override
  String get backupPasswordWeak => 'That password appears on lists of leaked passwords. Choose another.';

  @override
  String get backupPasswordMismatch => 'The confirmation does not match the backup password.';

  @override
  String get backupCreateAction => 'Create backup';

  @override
  String get backupSaveAgain => 'Save file';

  @override
  String get backupSaveCancelled => 'Saving was cancelled. No file was written.';

  @override
  String get backupExportSuccess => 'Encrypted backup saved.';

  @override
  String get backupExportFailed => 'The backup could not be created. Try again.';

  @override
  String get backupExportClearTextAction => 'Export unencrypted (CSV/JSON)';

  @override
  String get backupClearTextTitle => 'Export unencrypted file';

  @override
  String get backupClearTextReauthBody => 'Re-enter your master password to export the vault in clear text.';

  @override
  String backupClearTextItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'The file will contain $count entries.',
      one: 'The file will contain 1 entry.',
    );
    return '$_temp0';
  }

  @override
  String get backupClearTextWarning => 'This file is NOT encrypted. Every password in it is readable by anyone who opens it, including any app that syncs it to the cloud. Delete it as soon as you finish migrating.';

  @override
  String get backupClearTextFormatLabel => 'Format';

  @override
  String get backupClearTextFormatCsv => 'CSV — password managers and spreadsheets';

  @override
  String get backupClearTextFormatJson => 'JSON — every field, no information loss';

  @override
  String get backupClearTextConfirm => 'I understand the file will be unencrypted on disk.';

  @override
  String get backupClearTextCreateAction => 'Export unencrypted file';

  @override
  String get backupClearTextSuccess => 'Unencrypted file saved. Delete it once you are done with it.';

  @override
  String get backupClearTextExportFailed => 'The unencrypted file could not be created. Try again.';

  @override
  String get backupReauthExpired => 'Your confirmation expired. Start the export again.';

  @override
  String get backupRestoreTitle => 'Restore backup';

  @override
  String get backupRestoreIntro => 'Pick a .vaulta file and enter its backup password. Nothing is written to your vault until you confirm.';

  @override
  String get backupPickFile => 'Choose backup file';

  @override
  String get backupPickFailed => 'The file could not be opened.';

  @override
  String get backupUnlockAction => 'Open backup';

  @override
  String get backupOpenFailed => 'The backup could not be opened. Check the backup password; the file may also be damaged or modified.';

  @override
  String get backupUnsupportedVersion => 'This backup was made by a newer version of Vaulta. Update the app and try again.';

  @override
  String get backupPreviewTitle => 'Backup contents';

  @override
  String backupPreviewCreatedAt(String date) {
    return 'Created $date';
  }

  @override
  String backupPreviewSummary(int total, int fresh, int conflicts, int duplicates) {
    return '$total entries: $fresh new, $conflicts kept next to a similar entry, $duplicates already in your vault.';
  }

  @override
  String get backupConflictSuffix => ' (restored)';

  @override
  String backupRestoreConfirm(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Restore $count entries',
      one: 'Restore 1 entry',
    );
    return '$_temp0';
  }

  @override
  String get backupRestoreNothing => 'Every entry in this backup is already in your vault.';

  @override
  String backupRestoreSuccess(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Restored $count entries.',
      one: 'Restored 1 entry.',
    );
    return '$_temp0';
  }

  @override
  String get backupRestoreFailed => 'The restore was interrupted. Entries written before the error were kept.';

  @override
  String get backupRestoreLocked => 'Unlock Vaulta to restore a backup.';
}
