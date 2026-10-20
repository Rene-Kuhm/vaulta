import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Vaulta'**
  String get appTitle;

  /// No description provided for @navVault.
  ///
  /// In en, this message translates to:
  /// **'Vault'**
  String get navVault;

  /// No description provided for @navAccess.
  ///
  /// In en, this message translates to:
  /// **'Access'**
  String get navAccess;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @brandFooter.
  ///
  /// In en, this message translates to:
  /// **'Tecnodespegue.com'**
  String get brandFooter;

  /// No description provided for @languageSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSectionTitle;

  /// No description provided for @languageSelectorLabel.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get languageSelectorLabel;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageSpanish.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get languageSpanish;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutTitle;

  /// No description provided for @aboutCreator.
  ///
  /// In en, this message translates to:
  /// **'Created by René Kuhm, founder of Tecnodespegue.'**
  String get aboutCreator;

  /// No description provided for @aboutAgency.
  ///
  /// In en, this message translates to:
  /// **'Tecnodespegue.com'**
  String get aboutAgency;

  /// No description provided for @settingsLocalUnlockPostureTitle.
  ///
  /// In en, this message translates to:
  /// **'Local unlock posture'**
  String get settingsLocalUnlockPostureTitle;

  /// No description provided for @settingsLocalUnlockPostureDescription.
  ///
  /// In en, this message translates to:
  /// **'Vaulta keeps sensitive state in Keychain / Keystore. On Android, biometrics unlock the vault through a hardware-protected key; other platforms still use the master password path.'**
  String get settingsLocalUnlockPostureDescription;

  /// No description provided for @settingsMasterPasswordCreated.
  ///
  /// In en, this message translates to:
  /// **'Master password created'**
  String get settingsMasterPasswordCreated;

  /// No description provided for @settingsBiometricsAvailable.
  ///
  /// In en, this message translates to:
  /// **'Biometrics available'**
  String get settingsBiometricsAvailable;

  /// No description provided for @settingsBiometricsEnabled.
  ///
  /// In en, this message translates to:
  /// **'Biometrics enabled'**
  String get settingsBiometricsEnabled;

  /// No description provided for @settingsUnlockWithBiometrics.
  ///
  /// In en, this message translates to:
  /// **'Use biometrics to unlock on Android'**
  String get settingsUnlockWithBiometrics;

  /// No description provided for @settingsBiometricSupportedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use {biometricLabel} to unlock the vault on Android. The master password is still required for recovery, activation, or biometric re-enrollment.'**
  String settingsBiometricSupportedSubtitle(Object biometricLabel);

  /// No description provided for @settingsBiometricUnavailableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Biometrics are not configured or supported in this environment.'**
  String get settingsBiometricUnavailableSubtitle;

  /// No description provided for @settingsAutoLockBackgroundTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-lock on background'**
  String get settingsAutoLockBackgroundTitle;

  /// No description provided for @settingsAutoLockBackgroundSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Locks Vaulta automatically if the app becomes inactive, paused, or detached.'**
  String get settingsAutoLockBackgroundSubtitle;

  /// No description provided for @settingsIdleTimeoutLabel.
  ///
  /// In en, this message translates to:
  /// **'Foreground idle auto-lock'**
  String get settingsIdleTimeoutLabel;

  /// No description provided for @settingsLockNow.
  ///
  /// In en, this message translates to:
  /// **'Lock now'**
  String get settingsLockNow;

  /// No description provided for @settingsChangeMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'Change master password'**
  String get settingsChangeMasterPassword;

  /// No description provided for @settingsSessionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Devices and sessions'**
  String get settingsSessionsTitle;

  /// No description provided for @settingsSessionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'You can revoke one device or cut every other active session.'**
  String get settingsSessionsSubtitle;

  /// No description provided for @settingsSessionsRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh sessions'**
  String get settingsSessionsRefresh;

  /// No description provided for @settingsRevokeOtherDevices.
  ///
  /// In en, this message translates to:
  /// **'Revoke all other sessions'**
  String get settingsRevokeOtherDevices;

  /// No description provided for @settingsRevokeDevice.
  ///
  /// In en, this message translates to:
  /// **'Revoke device'**
  String get settingsRevokeDevice;

  /// No description provided for @settingsRevokeCurrentDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke this device?'**
  String get settingsRevokeCurrentDeviceTitle;

  /// No description provided for @settingsRevokeCurrentDeviceBody.
  ///
  /// In en, this message translates to:
  /// **'Revoking the current device will immediately lock this session. You will need to unlock again to continue.'**
  String get settingsRevokeCurrentDeviceBody;

  /// No description provided for @settingsRevokeNow.
  ///
  /// In en, this message translates to:
  /// **'Revoke now'**
  String get settingsRevokeNow;

  /// No description provided for @settingsRevokeDeviceError.
  ///
  /// In en, this message translates to:
  /// **'We could not revoke this device. Please retry in a few seconds.'**
  String get settingsRevokeDeviceError;

  /// No description provided for @settingsRevokedAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Session revoked on all devices'**
  String get settingsRevokedAllTitle;

  /// No description provided for @settingsRevokedAllBody.
  ///
  /// In en, this message translates to:
  /// **'Your account access was revoked for all sessions. This device will lock now for safety.'**
  String get settingsRevokedAllBody;

  /// No description provided for @settingsCurrentDeviceRevokedTitle.
  ///
  /// In en, this message translates to:
  /// **'Current device revoked'**
  String get settingsCurrentDeviceRevokedTitle;

  /// No description provided for @settingsCurrentDeviceRevokedBody.
  ///
  /// In en, this message translates to:
  /// **'This device no longer has an active session. Vaulta will lock now for safety.'**
  String get settingsCurrentDeviceRevokedBody;

  /// No description provided for @settingsNoDevices.
  ///
  /// In en, this message translates to:
  /// **'No registered devices for this user.'**
  String get settingsNoDevices;

  /// No description provided for @settingsCurrentDeviceLabel.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get settingsCurrentDeviceLabel;

  /// No description provided for @settingsSessionStatusActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get settingsSessionStatusActive;

  /// No description provided for @settingsSessionStatusRevoked.
  ///
  /// In en, this message translates to:
  /// **'Revoked'**
  String get settingsSessionStatusRevoked;

  /// No description provided for @settingsDeviceNeverSeen.
  ///
  /// In en, this message translates to:
  /// **'No activity recorded'**
  String get settingsDeviceNeverSeen;

  /// No description provided for @settingsDeviceRevokedMessage.
  ///
  /// In en, this message translates to:
  /// **'Device revoked successfully.'**
  String get settingsDeviceRevokedMessage;

  /// No description provided for @settingsRevokeOthersDone.
  ///
  /// In en, this message translates to:
  /// **'Other active sessions were revoked.'**
  String get settingsRevokeOthersDone;

  /// No description provided for @settingsRevokeOthersFailed.
  ///
  /// In en, this message translates to:
  /// **'We could not revoke other sessions. Please retry in a few seconds.'**
  String get settingsRevokeOthersFailed;

  /// No description provided for @settingsRoadmapTitle.
  ///
  /// In en, this message translates to:
  /// **'Platform security roadmap'**
  String get settingsRoadmapTitle;

  /// No description provided for @settingsRoadmapNotes.
  ///
  /// In en, this message translates to:
  /// **'Vault items use ADR-001 v2: Argon2id derives a KEK from the master password, and a random DEK encrypts entries with AES-256-GCM. Android now uses KeyStore for biometric unlock; iOS/macOS bindings remain pending.'**
  String get settingsRoadmapNotes;

  /// No description provided for @settingsSecureStorage.
  ///
  /// In en, this message translates to:
  /// **'Secure storage'**
  String get settingsSecureStorage;

  /// No description provided for @settingsBiometricUnlock.
  ///
  /// In en, this message translates to:
  /// **'Biometric key recovery'**
  String get settingsBiometricUnlock;

  /// No description provided for @settingsHardwareBackedKeys.
  ///
  /// In en, this message translates to:
  /// **'Hardware-backed keys'**
  String get settingsHardwareBackedKeys;

  /// No description provided for @settingsVaultEncryptionReady.
  ///
  /// In en, this message translates to:
  /// **'Vault item encryption wired end-to-end'**
  String get settingsVaultEncryptionReady;

  /// No description provided for @settingsConflictsTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync conflicts'**
  String get settingsConflictsTitle;

  /// No description provided for @settingsConflictsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No pending conflicts. Sync queue is clean.'**
  String get settingsConflictsEmpty;

  /// No description provided for @settingsConflictsRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get settingsConflictsRefresh;

  /// No description provided for @settingsConflictsLoadError.
  ///
  /// In en, this message translates to:
  /// **'We could not load sync conflicts. Please retry.'**
  String get settingsConflictsLoadError;

  /// No description provided for @settingsSessionsLoadError.
  ///
  /// In en, this message translates to:
  /// **'We could not load device sessions. Please retry.'**
  String get settingsSessionsLoadError;

  /// No description provided for @settingsConflictsKindConflict.
  ///
  /// In en, this message translates to:
  /// **'Conflict'**
  String get settingsConflictsKindConflict;

  /// No description provided for @settingsConflictsReasonFallback.
  ///
  /// In en, this message translates to:
  /// **'CAS conflict detected while pushing mutation.'**
  String get settingsConflictsReasonFallback;

  /// No description provided for @settingsConflictsVersionRow.
  ///
  /// In en, this message translates to:
  /// **'Local base v{expected} · Remote v{remote}'**
  String settingsConflictsVersionRow(Object expected, Object remote);

  /// No description provided for @settingsDeviceStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'status: {code}'**
  String settingsDeviceStatusLabel(Object code);

  /// No description provided for @settingsDeviceRevokeHint.
  ///
  /// In en, this message translates to:
  /// **'If you revoke this device, Vaulta will lock immediately.'**
  String get settingsDeviceRevokeHint;

  /// No description provided for @idleNever.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get idleNever;

  /// No description provided for @idleDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get idleDisabled;

  /// No description provided for @idleOneMinute.
  ///
  /// In en, this message translates to:
  /// **'1 minute'**
  String get idleOneMinute;

  /// No description provided for @idleFiveMinutes.
  ///
  /// In en, this message translates to:
  /// **'5 minutes'**
  String get idleFiveMinutes;

  /// No description provided for @idleFifteenMinutes.
  ///
  /// In en, this message translates to:
  /// **'15 minutes'**
  String get idleFifteenMinutes;

  /// No description provided for @idleStrict.
  ///
  /// In en, this message translates to:
  /// **'Strict'**
  String get idleStrict;

  /// No description provided for @idleRecommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended'**
  String get idleRecommended;

  /// No description provided for @idleRelaxed.
  ///
  /// In en, this message translates to:
  /// **'Relaxed'**
  String get idleRelaxed;

  /// No description provided for @changeMasterPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Change master password'**
  String get changeMasterPasswordTitle;

  /// No description provided for @changeMasterPasswordCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current master password'**
  String get changeMasterPasswordCurrent;

  /// No description provided for @changeMasterPasswordNew.
  ///
  /// In en, this message translates to:
  /// **'New master password'**
  String get changeMasterPasswordNew;

  /// No description provided for @changeMasterPasswordConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm new master password'**
  String get changeMasterPasswordConfirm;

  /// No description provided for @changeMasterPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'This re-encrypts the entire vault with a new key.'**
  String get changeMasterPasswordHint;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @masterPasswordUpdatedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Master password updated successfully.'**
  String get masterPasswordUpdatedSuccess;

  /// No description provided for @changeMasterPasswordErrorFallback.
  ///
  /// In en, this message translates to:
  /// **'We could not change the master password. Review the data and try again.'**
  String get changeMasterPasswordErrorFallback;

  /// No description provided for @securityOnboardingEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Secure onboarding'**
  String get securityOnboardingEyebrow;

  /// No description provided for @securityOnboardingTitle.
  ///
  /// In en, this message translates to:
  /// **'We create your master key with no dangerous shortcuts.'**
  String get securityOnboardingTitle;

  /// No description provided for @securityOnboardingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The master password validates local access and derives the key that encrypts vault items.'**
  String get securityOnboardingSubtitle;

  /// No description provided for @securityMasterPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Master password'**
  String get securityMasterPasswordTitle;

  /// No description provided for @securityMasterPasswordDescription.
  ///
  /// In en, this message translates to:
  /// **'Use 12+ characters with real variety. Never store this key in plaintext.'**
  String get securityMasterPasswordDescription;

  /// No description provided for @securityMasterPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'A master password is required.'**
  String get securityMasterPasswordRequired;

  /// No description provided for @securityMasterPasswordMinLength.
  ///
  /// In en, this message translates to:
  /// **'Use at least 12 characters.'**
  String get securityMasterPasswordMinLength;

  /// No description provided for @securityMasterPasswordMismatch.
  ///
  /// In en, this message translates to:
  /// **'The confirmation does not match the master password.'**
  String get securityMasterPasswordMismatch;

  /// No description provided for @securityCreateMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'Create master password'**
  String get securityCreateMasterPassword;

  /// No description provided for @securityConfirmMasterPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm master password'**
  String get securityConfirmMasterPassword;

  /// No description provided for @securityChecklistHash.
  ///
  /// In en, this message translates to:
  /// **'Argon2id verifies the master password.'**
  String get securityChecklistHash;

  /// No description provided for @securityChecklistDerive.
  ///
  /// In en, this message translates to:
  /// **'Argon2id derives a KEK that unwraps a random vault DEK.'**
  String get securityChecklistDerive;

  /// No description provided for @securityChecklistEncrypt.
  ///
  /// In en, this message translates to:
  /// **'Local items are encrypted with AES-256-GCM and records are stored with Keychain / Keystore.'**
  String get securityChecklistEncrypt;

  /// No description provided for @securityEnableBiometrics.
  ///
  /// In en, this message translates to:
  /// **'Enable local biometrics'**
  String get securityEnableBiometrics;

  /// No description provided for @securityBiometricAvailable.
  ///
  /// In en, this message translates to:
  /// **'Enable {biometricLabel} to unlock Vaulta on Android. The master password remains the recovery and re-enrollment path.'**
  String securityBiometricAvailable(Object biometricLabel);

  /// No description provided for @securityBiometricUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No biometrics detected. You can still unlock with your master password.'**
  String get securityBiometricUnavailable;

  /// No description provided for @securityCreateSecureAccess.
  ///
  /// In en, this message translates to:
  /// **'Create secure vault access'**
  String get securityCreateSecureAccess;

  /// No description provided for @securityUnlockEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get securityUnlockEyebrow;

  /// No description provided for @securityUnlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Your vault stays closed until real identity is verified.'**
  String get securityUnlockTitle;

  /// No description provided for @securityUnlockBiometricSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use your master password or the biometrics already enabled on this device.'**
  String securityUnlockBiometricSubtitle(Object biometricLabel);

  /// No description provided for @securityUnlockPasswordSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use your master password to recover access.'**
  String get securityUnlockPasswordSubtitle;

  /// No description provided for @securityUnlockBiometricHint.
  ///
  /// In en, this message translates to:
  /// **'Type your master password or tap the fingerprint button to unlock.'**
  String get securityUnlockBiometricHint;

  /// No description provided for @securityUnlockPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Type your master password to unlock the vault.'**
  String get securityUnlockPasswordHint;

  /// Shown on the unlock screen while too many failed master-password attempts keep unlock disabled. The time placeholder is the remaining wait formatted as m:ss.
  ///
  /// In en, this message translates to:
  /// **'Too many failed attempts. Try again in {time}.'**
  String securityUnlockLockedOut(String time);

  /// No description provided for @securityUnlockStateUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Vaulta could not record this attempt in secure storage, so the password was not checked. Try again; if it keeps happening, restart the app.'**
  String get securityUnlockStateUnavailable;

  /// No description provided for @securityProtectedAccess.
  ///
  /// In en, this message translates to:
  /// **'Protected access'**
  String get securityProtectedAccess;

  /// No description provided for @securityUnlockVault.
  ///
  /// In en, this message translates to:
  /// **'Unlock vault'**
  String get securityUnlockVault;

  /// No description provided for @securityBiometricButton.
  ///
  /// In en, this message translates to:
  /// **'Biometric'**
  String get securityBiometricButton;

  /// No description provided for @dashboardDecryptError.
  ///
  /// In en, this message translates to:
  /// **'Vaulta could not decrypt the local vault right now.'**
  String get dashboardDecryptError;

  /// No description provided for @dashboardDecryptErrorAdvice.
  ///
  /// In en, this message translates to:
  /// **'Lock and unlock again with your master password, then retry. Details are hidden to avoid leaking sensitive state.'**
  String get dashboardDecryptErrorAdvice;

  /// No description provided for @entryDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Entry detail'**
  String get entryDetailTitle;

  /// No description provided for @entryEditTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit entry'**
  String get entryEditTooltip;

  /// No description provided for @entryDeleteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete entry'**
  String get entryDeleteTooltip;

  /// No description provided for @entryUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get entryUsernameLabel;

  /// No description provided for @entryWebsiteLabel.
  ///
  /// In en, this message translates to:
  /// **'Website'**
  String get entryWebsiteLabel;

  /// No description provided for @entryStrengthLabel.
  ///
  /// In en, this message translates to:
  /// **'Strength'**
  String get entryStrengthLabel;

  /// No description provided for @entryUpdatedLabel.
  ///
  /// In en, this message translates to:
  /// **'Updated'**
  String get entryUpdatedLabel;

  /// No description provided for @entrySecretTitle.
  ///
  /// In en, this message translates to:
  /// **'Secret'**
  String get entrySecretTitle;

  /// No description provided for @entryShowSecret.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get entryShowSecret;

  /// No description provided for @entryHideSecret.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get entryHideSecret;

  /// No description provided for @copySecret.
  ///
  /// In en, this message translates to:
  /// **'Copy secret'**
  String get copySecret;

  /// No description provided for @secretCopiedLocally.
  ///
  /// In en, this message translates to:
  /// **'Secret copied. The clipboard will be cleared in 30 seconds if unchanged.'**
  String get secretCopiedLocally;

  /// No description provided for @clipboardCleared.
  ///
  /// In en, this message translates to:
  /// **'Clipboard cleared.'**
  String get clipboardCleared;

  /// No description provided for @entryNotesTitle.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get entryNotesTitle;

  /// No description provided for @entryDeleteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete entry?'**
  String get entryDeleteDialogTitle;

  /// No description provided for @entryDeleteDialogBody.
  ///
  /// In en, this message translates to:
  /// **'This removes the encrypted record from the local vault. Remote recovery is not available in offline mode.'**
  String get entryDeleteDialogBody;

  /// No description provided for @entryDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get entryDeleteConfirm;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @newEntry.
  ///
  /// In en, this message translates to:
  /// **'New entry'**
  String get newEntry;

  /// No description provided for @entryCreatedMessage.
  ///
  /// In en, this message translates to:
  /// **'Encrypted entry created.'**
  String get entryCreatedMessage;

  /// No description provided for @vaultUpdatedMessage.
  ///
  /// In en, this message translates to:
  /// **'Vault updated locally.'**
  String get vaultUpdatedMessage;

  /// No description provided for @dashboardSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your encrypted control room'**
  String get dashboardSubtitle;

  /// No description provided for @dashboardHeroTitle.
  ///
  /// In en, this message translates to:
  /// **'Protected by system hardware'**
  String get dashboardHeroTitle;

  /// No description provided for @dashboardHeroBody.
  ///
  /// In en, this message translates to:
  /// **'The local vault encrypts every entry with AES-256-GCM. Local CRUD, search, filters, and password generation are ready; remote sync remains optional and experimental.'**
  String get dashboardHeroBody;

  /// No description provided for @dashboardPillTrustedDevices.
  ///
  /// In en, this message translates to:
  /// **'{count} devices trusted'**
  String dashboardPillTrustedDevices(int count);

  /// No description provided for @dashboardPillSyncEnabled.
  ///
  /// In en, this message translates to:
  /// **'Secure sync on'**
  String get dashboardPillSyncEnabled;

  /// No description provided for @dashboardPillSyncDisabled.
  ///
  /// In en, this message translates to:
  /// **'Offline encrypted vault'**
  String get dashboardPillSyncDisabled;

  /// No description provided for @dashboardPillWeakNeedRotation.
  ///
  /// In en, this message translates to:
  /// **'{count} passwords need rotation'**
  String dashboardPillWeakNeedRotation(int count);

  /// No description provided for @dashboardQuickActionsEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Action'**
  String get dashboardQuickActionsEyebrow;

  /// No description provided for @securityScore.
  ///
  /// In en, this message translates to:
  /// **'Security score'**
  String get securityScore;

  /// No description provided for @vaultEntries.
  ///
  /// In en, this message translates to:
  /// **'Vault entries'**
  String get vaultEntries;

  /// No description provided for @weakPasswords.
  ///
  /// In en, this message translates to:
  /// **'Weak passwords'**
  String get weakPasswords;

  /// No description provided for @reusedItems.
  ///
  /// In en, this message translates to:
  /// **'Reused items'**
  String get reusedItems;

  /// No description provided for @trustedDevices.
  ///
  /// In en, this message translates to:
  /// **'Trusted devices'**
  String get trustedDevices;

  /// No description provided for @priorityActions.
  ///
  /// In en, this message translates to:
  /// **'Priority actions'**
  String get priorityActions;

  /// No description provided for @dashboardQuickActionsSummary.
  ///
  /// In en, this message translates to:
  /// **'The vault is now real: create, edit, view details, and delete with encryption preserved end-to-end.'**
  String get dashboardQuickActionsSummary;

  /// No description provided for @createEncryptedEntry.
  ///
  /// In en, this message translates to:
  /// **'Create encrypted entry'**
  String get createEncryptedEntry;

  /// No description provided for @createEncryptedEntrySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add new credentials and store them encrypted at rest.'**
  String get createEncryptedEntrySubtitle;

  /// No description provided for @planNextHardeningStep.
  ///
  /// In en, this message translates to:
  /// **'Plan next hardening step'**
  String get planNextHardeningStep;

  /// No description provided for @dashboardRoadmapSyncEnabled.
  ///
  /// In en, this message translates to:
  /// **'Remote sync is experimental and requires a configured Supabase session.'**
  String get dashboardRoadmapSyncEnabled;

  /// No description provided for @dashboardRoadmapSyncDisabled.
  ///
  /// In en, this message translates to:
  /// **'Offline-first release: local vault, search, filters, and generator are available without cloud sync.'**
  String get dashboardRoadmapSyncDisabled;

  /// No description provided for @vaultEntriesSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Vault entries'**
  String get vaultEntriesSectionTitle;

  /// No description provided for @searchVault.
  ///
  /// In en, this message translates to:
  /// **'Search title, username, or website'**
  String get searchVault;

  /// No description provided for @filter.
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get filter;

  /// No description provided for @filterAllEntries.
  ///
  /// In en, this message translates to:
  /// **'All entries'**
  String get filterAllEntries;

  /// No description provided for @filterWeakOnly.
  ///
  /// In en, this message translates to:
  /// **'Weak passwords only'**
  String get filterWeakOnly;

  /// No description provided for @filterWithNotes.
  ///
  /// In en, this message translates to:
  /// **'Entries with notes'**
  String get filterWithNotes;

  /// No description provided for @resetFilters.
  ///
  /// In en, this message translates to:
  /// **'Reset filters'**
  String get resetFilters;

  /// No description provided for @noResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'No entries match your current filters'**
  String get noResultsTitle;

  /// No description provided for @noResultsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Try a different query or reset filters to see all items again.'**
  String get noResultsSubtitle;

  /// No description provided for @emptyVaultTitle.
  ///
  /// In en, this message translates to:
  /// **'Your vault is empty'**
  String get emptyVaultTitle;

  /// No description provided for @emptyVaultSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create your first entry and Vaulta encrypts it before persisting.'**
  String get emptyVaultSubtitle;

  /// No description provided for @createFirstEntry.
  ///
  /// In en, this message translates to:
  /// **'Create first entry'**
  String get createFirstEntry;

  /// No description provided for @itemsTotal.
  ///
  /// In en, this message translates to:
  /// **'{count} total'**
  String itemsTotal(int count);

  /// No description provided for @itemsShownOfTotal.
  ///
  /// In en, this message translates to:
  /// **'{shown} shown - {total} total'**
  String itemsShownOfTotal(int shown, int total);

  /// No description provided for @editorTitleEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit entry'**
  String get editorTitleEdit;

  /// No description provided for @editorTitleNew.
  ///
  /// In en, this message translates to:
  /// **'New entry'**
  String get editorTitleNew;

  /// No description provided for @editorIdentityTitle.
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get editorIdentityTitle;

  /// No description provided for @editorTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get editorTitleLabel;

  /// No description provided for @editorTitleHint.
  ///
  /// In en, this message translates to:
  /// **'GitHub, banking, Wi-Fi...'**
  String get editorTitleHint;

  /// No description provided for @editorTitleValidation.
  ///
  /// In en, this message translates to:
  /// **'Give this entry a clear title.'**
  String get editorTitleValidation;

  /// No description provided for @editorUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username or email'**
  String get editorUsernameLabel;

  /// No description provided for @editorUsernameValidation.
  ///
  /// In en, this message translates to:
  /// **'Add the account identifier.'**
  String get editorUsernameValidation;

  /// No description provided for @editorCategoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get editorCategoryLabel;

  /// No description provided for @editorCategoryWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get editorCategoryWork;

  /// No description provided for @editorCategoryFinance.
  ///
  /// In en, this message translates to:
  /// **'Finance'**
  String get editorCategoryFinance;

  /// No description provided for @editorCategoryPersonal.
  ///
  /// In en, this message translates to:
  /// **'Personal'**
  String get editorCategoryPersonal;

  /// No description provided for @editorCategoryInfrastructure.
  ///
  /// In en, this message translates to:
  /// **'Infrastructure'**
  String get editorCategoryInfrastructure;

  /// No description provided for @editorSecretTitle.
  ///
  /// In en, this message translates to:
  /// **'Secret'**
  String get editorSecretTitle;

  /// No description provided for @editorSecretDescription.
  ///
  /// In en, this message translates to:
  /// **'Vaulta recalculates strength locally before re-encrypting the entry.'**
  String get editorSecretDescription;

  /// No description provided for @editorSecretLabel.
  ///
  /// In en, this message translates to:
  /// **'Password or secret'**
  String get editorSecretLabel;

  /// No description provided for @editorSecretRequiredValidation.
  ///
  /// In en, this message translates to:
  /// **'Store a real secret, not an empty field.'**
  String get editorSecretRequiredValidation;

  /// No description provided for @editorSecretMinValidation.
  ///
  /// In en, this message translates to:
  /// **'Use at least 8 characters.'**
  String get editorSecretMinValidation;

  /// No description provided for @editorGeneratorTitle.
  ///
  /// In en, this message translates to:
  /// **'Password generator'**
  String get editorGeneratorTitle;

  /// No description provided for @editorGeneratorChars.
  ///
  /// In en, this message translates to:
  /// **'{count} chars'**
  String editorGeneratorChars(int count);

  /// No description provided for @editorGenerateInsert.
  ///
  /// In en, this message translates to:
  /// **'Generate and insert'**
  String get editorGenerateInsert;

  /// No description provided for @editorWebsiteLabel.
  ///
  /// In en, this message translates to:
  /// **'Website or app'**
  String get editorWebsiteLabel;

  /// No description provided for @editorWebsiteHint.
  ///
  /// In en, this message translates to:
  /// **'https://example.com'**
  String get editorWebsiteHint;

  /// No description provided for @editorNotesLabel.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get editorNotesLabel;

  /// No description provided for @editorNotesHint.
  ///
  /// In en, this message translates to:
  /// **'Recovery codes, context, reminders...'**
  String get editorNotesHint;

  /// No description provided for @editorSaveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save changes'**
  String get editorSaveChanges;

  /// No description provided for @editorCreateEntry.
  ///
  /// In en, this message translates to:
  /// **'Create entry'**
  String get editorCreateEntry;

  /// No description provided for @editorGeneratorSetRequired.
  ///
  /// In en, this message translates to:
  /// **'Choose at least one character set to generate.'**
  String get editorGeneratorSetRequired;

  /// No description provided for @editorGeneratedInserted.
  ///
  /// In en, this message translates to:
  /// **'Generated password inserted.'**
  String get editorGeneratedInserted;

  /// No description provided for @syncConflictsTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync conflicts'**
  String get syncConflictsTitle;

  /// No description provided for @syncConflictsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A remote change arrived while your local edit was pending. Choose which version to keep.'**
  String get syncConflictsSubtitle;

  /// No description provided for @syncConflictsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No pending conflicts. Everything is in sync.'**
  String get syncConflictsEmpty;

  /// No description provided for @syncConflictsLoadError.
  ///
  /// In en, this message translates to:
  /// **'We could not load pending conflicts. Please retry.'**
  String get syncConflictsLoadError;

  /// No description provided for @syncConflictResolveError.
  ///
  /// In en, this message translates to:
  /// **'We could not resolve this conflict. Please retry.'**
  String get syncConflictResolveError;

  /// No description provided for @syncConflictsBannerLabel.
  ///
  /// In en, this message translates to:
  /// **'{count} sync {count, plural, =1{conflict} other{conflicts}} pending'**
  String syncConflictsBannerLabel(int count);

  /// No description provided for @syncConflictsBannerAction.
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get syncConflictsBannerAction;

  /// No description provided for @syncConflictLocalVersion.
  ///
  /// In en, this message translates to:
  /// **'Your version'**
  String get syncConflictLocalVersion;

  /// No description provided for @syncConflictRemoteVersion.
  ///
  /// In en, this message translates to:
  /// **'Remote version'**
  String get syncConflictRemoteVersion;

  /// No description provided for @syncConflictKeepLocal.
  ///
  /// In en, this message translates to:
  /// **'Keep mine'**
  String get syncConflictKeepLocal;

  /// No description provided for @syncConflictKeepRemote.
  ///
  /// In en, this message translates to:
  /// **'Use remote'**
  String get syncConflictKeepRemote;

  /// No description provided for @syncConflictKindUpsert.
  ///
  /// In en, this message translates to:
  /// **'Edit conflict'**
  String get syncConflictKindUpsert;

  /// No description provided for @syncConflictKindDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete conflict'**
  String get syncConflictKindDelete;

  /// No description provided for @biometricSlotExpired.
  ///
  /// In en, this message translates to:
  /// **'The biometric vault key is not ready or was invalidated. Enter your master password and enable biometrics again.'**
  String get biometricSlotExpired;

  /// No description provided for @biometricUnlockSuccess.
  ///
  /// In en, this message translates to:
  /// **'Biometric verification accepted.'**
  String get biometricUnlockSuccess;

  /// No description provided for @biometricEnrollCta.
  ///
  /// In en, this message translates to:
  /// **'Set up biometrics on this device'**
  String get biometricEnrollCta;

  /// No description provided for @biometricEnrollSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your device has no biometric enrolled (fingerprint or face unlock). Open the system settings to enable it.'**
  String get biometricEnrollSubtitle;

  /// No description provided for @biometricEnrollAction.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get biometricEnrollAction;

  /// No description provided for @biometricEnrollUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Biometrics are not available on this device. Use the master password to unlock.'**
  String get biometricEnrollUnavailable;

  /// No description provided for @securitySetupBiometricCta.
  ///
  /// In en, this message translates to:
  /// **'Enable biometric unlock'**
  String get securitySetupBiometricCta;

  /// No description provided for @securitySetupBiometricDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable biometric unlock'**
  String get securitySetupBiometricDialogTitle;

  /// No description provided for @securitySetupBiometricDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Enter your master password once so Vaulta can wrap the key that protects your fingerprint.'**
  String get securitySetupBiometricDialogBody;

  /// No description provided for @securitySetupBiometricDialogAction.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get securitySetupBiometricDialogAction;

  /// No description provided for @securitySetupBiometricDialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get securitySetupBiometricDialogCancel;

  /// No description provided for @securitySetupBiometricSuccess.
  ///
  /// In en, this message translates to:
  /// **'Done. Next time you can unlock Vaulta with your fingerprint.'**
  String get securitySetupBiometricSuccess;

  /// No description provided for @securitySetupBiometricError.
  ///
  /// In en, this message translates to:
  /// **'We could not enable the fingerprint. Verify your master password and try again.'**
  String get securitySetupBiometricError;

  /// No description provided for @updateTitle.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get updateTitle;

  /// No description provided for @updateInstalled.
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get updateInstalled;

  /// No description provided for @updateRemote.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get updateRemote;

  /// No description provided for @updateDescription.
  ///
  /// In en, this message translates to:
  /// **'New versions are published automatically when there is a push to master. Tap below to check for a newer build without uninstalling the app.'**
  String get updateDescription;

  /// No description provided for @updateCheck.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheck;

  /// No description provided for @updateChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking...'**
  String get updateChecking;

  /// No description provided for @updateDownload.
  ///
  /// In en, this message translates to:
  /// **'Download and install'**
  String get updateDownload;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading APK...'**
  String get updateDownloading;

  /// No description provided for @updateInstalling.
  ///
  /// In en, this message translates to:
  /// **'Opening installer...'**
  String get updateInstalling;

  /// No description provided for @updateRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get updateRetry;

  /// No description provided for @updateUpToDateTitle.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get updateUpToDateTitle;

  /// No description provided for @updateUpToDateBody.
  ///
  /// In en, this message translates to:
  /// **'The installed build matches the latest release on master.'**
  String get updateUpToDateBody;

  /// No description provided for @updateErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'We could not check for updates'**
  String get updateErrorTitle;

  /// No description provided for @updateInstallerFailed.
  ///
  /// In en, this message translates to:
  /// **'We could not open the system installer. Verify that \"Unknown sources\" is enabled.'**
  String get updateInstallerFailed;

  /// No description provided for @updateAvailableVersion.
  ///
  /// In en, this message translates to:
  /// **'New version {tag}'**
  String updateAvailableVersion(Object tag);

  /// No description provided for @updateReleaseId.
  ///
  /// In en, this message translates to:
  /// **'release #{id}'**
  String updateReleaseId(Object id);

  /// No description provided for @updateAvailableBanner.
  ///
  /// In en, this message translates to:
  /// **'New version {tag} is available'**
  String updateAvailableBanner(Object tag);

  /// No description provided for @updateActionUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updateActionUpdate;

  /// No description provided for @updateInstallPrompt.
  ///
  /// In en, this message translates to:
  /// **'Confirm the installation on the system screen.'**
  String get updateInstallPrompt;

  /// No description provided for @updateInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'We could not open the installer. Enable \"Unknown sources\" in Settings and try again.'**
  String get updateInstallFailed;

  /// No description provided for @updateGenericError.
  ///
  /// In en, this message translates to:
  /// **'Update failed: {error}'**
  String updateGenericError(Object error);

  /// No description provided for @accessEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Autofill & access'**
  String get accessEyebrow;

  /// No description provided for @accessTitle.
  ///
  /// In en, this message translates to:
  /// **'Vault on every input'**
  String get accessTitle;

  /// No description provided for @accessSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set Vaulta as the system autofill provider and unlock your entries the moment a password field needs them.'**
  String get accessSubtitle;

  /// No description provided for @accessHeroTitle.
  ///
  /// In en, this message translates to:
  /// **'One-tap autofill'**
  String get accessHeroTitle;

  /// No description provided for @accessHeroBody.
  ///
  /// In en, this message translates to:
  /// **'Hardware-backed. Offline-first. No data leaves the device.'**
  String get accessHeroBody;

  /// No description provided for @accessPlatformAndroid.
  ///
  /// In en, this message translates to:
  /// **'Android 11+'**
  String get accessPlatformAndroid;

  /// No description provided for @accessPlatformBiometrics.
  ///
  /// In en, this message translates to:
  /// **'Biometric unlock'**
  String get accessPlatformBiometrics;

  /// No description provided for @accessPlatformOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline by default'**
  String get accessPlatformOffline;

  /// No description provided for @accessSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Setup in three steps'**
  String get accessSetupTitle;

  /// No description provided for @accessSetupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'On Android 11 and above the platform exposes an Autofill service that Vaulta can plug into.'**
  String get accessSetupSubtitle;

  /// No description provided for @accessSetupStep1Title.
  ///
  /// In en, this message translates to:
  /// **'Open Android settings'**
  String get accessSetupStep1Title;

  /// No description provided for @accessSetupStep1Body.
  ///
  /// In en, this message translates to:
  /// **'Go to System → Languages & input → Autofill service.'**
  String get accessSetupStep1Body;

  /// No description provided for @accessSetupStep2Title.
  ///
  /// In en, this message translates to:
  /// **'Pick Vaulta'**
  String get accessSetupStep2Title;

  /// No description provided for @accessSetupStep2Body.
  ///
  /// In en, this message translates to:
  /// **'Select Vaulta as the active service. Android will ask for confirmation.'**
  String get accessSetupStep2Body;

  /// No description provided for @accessSetupStep3Title.
  ///
  /// In en, this message translates to:
  /// **'Unlock and approve'**
  String get accessSetupStep3Title;

  /// No description provided for @accessSetupStep3Body.
  ///
  /// In en, this message translates to:
  /// **'Next time you tap a password field, Vaulta prompts for biometrics or master password and fills the right entry.'**
  String get accessSetupStep3Body;

  /// No description provided for @accessUnlockPostureTitle.
  ///
  /// In en, this message translates to:
  /// **'Unlock posture'**
  String get accessUnlockPostureTitle;

  /// No description provided for @accessUnlockPostureBody.
  ///
  /// In en, this message translates to:
  /// **'Autofill requests are gated by the same unlock state as the rest of the app.'**
  String get accessUnlockPostureBody;

  /// No description provided for @accessUnlocked.
  ///
  /// In en, this message translates to:
  /// **'Vault is unlocked'**
  String get accessUnlocked;

  /// No description provided for @accessLocked.
  ///
  /// In en, this message translates to:
  /// **'Vault is locked'**
  String get accessLocked;

  /// No description provided for @accessLockNow.
  ///
  /// In en, this message translates to:
  /// **'Lock vault now'**
  String get accessLockNow;

  /// No description provided for @accessRoadmapTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s next'**
  String get accessRoadmapTitle;

  /// No description provided for @accessRoadmapBody.
  ///
  /// In en, this message translates to:
  /// **'iOS and desktop autofill ship after the biometric platform bindings (iOS/macOS) are in place.'**
  String get accessRoadmapBody;

  /// No description provided for @backupSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup'**
  String get backupSectionTitle;

  /// No description provided for @backupSectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Export your vault to an encrypted .vaulta file so you can restore it on a new device. Keep the file somewhere other than this device.'**
  String get backupSectionSubtitle;

  /// No description provided for @backupExportAction.
  ///
  /// In en, this message translates to:
  /// **'Export backup'**
  String get backupExportAction;

  /// No description provided for @backupRestoreAction.
  ///
  /// In en, this message translates to:
  /// **'Restore backup'**
  String get backupRestoreAction;

  /// No description provided for @backupExportTitle.
  ///
  /// In en, this message translates to:
  /// **'Export encrypted backup'**
  String get backupExportTitle;

  /// No description provided for @backupReauthBody.
  ///
  /// In en, this message translates to:
  /// **'Re-enter your master password to export the vault.'**
  String get backupReauthBody;

  /// No description provided for @backupMasterPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Master password'**
  String get backupMasterPasswordLabel;

  /// No description provided for @backupContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get backupContinue;

  /// No description provided for @backupMasterPasswordMismatch.
  ///
  /// In en, this message translates to:
  /// **'The master password does not match.'**
  String get backupMasterPasswordMismatch;

  /// No description provided for @backupItemCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{The backup will contain 1 entry.} other{The backup will contain {count} entries.}}'**
  String backupItemCount(int count);

  /// No description provided for @backupPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Backup password'**
  String get backupPasswordLabel;

  /// No description provided for @backupPasswordConfirmLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm backup password'**
  String get backupPasswordConfirmLabel;

  /// No description provided for @backupPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'At least 12 characters, mixing upper and lower case letters, numbers and symbols.'**
  String get backupPasswordHint;

  /// No description provided for @backupPasswordWarning.
  ///
  /// In en, this message translates to:
  /// **'Vaulta cannot recover the backup password. If you forget it, nobody can open this backup, not even you.'**
  String get backupPasswordWarning;

  /// No description provided for @backupPasswordTooShort.
  ///
  /// In en, this message translates to:
  /// **'Use at least {min} characters.'**
  String backupPasswordTooShort(int min);

  /// No description provided for @backupPasswordWeak.
  ///
  /// In en, this message translates to:
  /// **'Combine upper and lower case letters, numbers and symbols.'**
  String get backupPasswordWeak;

  /// No description provided for @backupPasswordMismatch.
  ///
  /// In en, this message translates to:
  /// **'The confirmation does not match the backup password.'**
  String get backupPasswordMismatch;

  /// No description provided for @backupCreateAction.
  ///
  /// In en, this message translates to:
  /// **'Create backup'**
  String get backupCreateAction;

  /// No description provided for @backupSaveAgain.
  ///
  /// In en, this message translates to:
  /// **'Save file'**
  String get backupSaveAgain;

  /// No description provided for @backupSaveCancelled.
  ///
  /// In en, this message translates to:
  /// **'Saving was cancelled. No file was written.'**
  String get backupSaveCancelled;

  /// No description provided for @backupExportSuccess.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup saved.'**
  String get backupExportSuccess;

  /// No description provided for @backupExportFailed.
  ///
  /// In en, this message translates to:
  /// **'The backup could not be created. Try again.'**
  String get backupExportFailed;

  /// No description provided for @backupReauthExpired.
  ///
  /// In en, this message translates to:
  /// **'Your confirmation expired. Start the export again.'**
  String get backupReauthExpired;

  /// No description provided for @backupRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore backup'**
  String get backupRestoreTitle;

  /// No description provided for @backupRestoreIntro.
  ///
  /// In en, this message translates to:
  /// **'Pick a .vaulta file and enter its backup password. Nothing is written to your vault until you confirm.'**
  String get backupRestoreIntro;

  /// No description provided for @backupPickFile.
  ///
  /// In en, this message translates to:
  /// **'Choose backup file'**
  String get backupPickFile;

  /// No description provided for @backupPickFailed.
  ///
  /// In en, this message translates to:
  /// **'The file could not be opened.'**
  String get backupPickFailed;

  /// No description provided for @backupUnlockAction.
  ///
  /// In en, this message translates to:
  /// **'Open backup'**
  String get backupUnlockAction;

  /// No description provided for @backupOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'The backup could not be opened. Check the backup password; the file may also be damaged or modified.'**
  String get backupOpenFailed;

  /// No description provided for @backupUnsupportedVersion.
  ///
  /// In en, this message translates to:
  /// **'This backup was made by a newer version of Vaulta. Update the app and try again.'**
  String get backupUnsupportedVersion;

  /// No description provided for @backupPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Backup contents'**
  String get backupPreviewTitle;

  /// No description provided for @backupPreviewCreatedAt.
  ///
  /// In en, this message translates to:
  /// **'Created {date}'**
  String backupPreviewCreatedAt(String date);

  /// No description provided for @backupPreviewSummary.
  ///
  /// In en, this message translates to:
  /// **'{total} entries: {fresh} new, {conflicts} kept next to a similar entry, {duplicates} already in your vault.'**
  String backupPreviewSummary(int total, int fresh, int conflicts, int duplicates);

  /// No description provided for @backupConflictSuffix.
  ///
  /// In en, this message translates to:
  /// **' (restored)'**
  String get backupConflictSuffix;

  /// No description provided for @backupRestoreConfirm.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Restore 1 entry} other{Restore {count} entries}}'**
  String backupRestoreConfirm(int count);

  /// No description provided for @backupRestoreNothing.
  ///
  /// In en, this message translates to:
  /// **'Every entry in this backup is already in your vault.'**
  String get backupRestoreNothing;

  /// No description provided for @backupRestoreSuccess.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Restored 1 entry.} other{Restored {count} entries.}}'**
  String backupRestoreSuccess(int count);

  /// No description provided for @backupRestoreFailed.
  ///
  /// In en, this message translates to:
  /// **'The restore was interrupted. Entries written before the error were kept.'**
  String get backupRestoreFailed;

  /// No description provided for @backupRestoreLocked.
  ///
  /// In en, this message translates to:
  /// **'Unlock Vaulta to restore a backup.'**
  String get backupRestoreLocked;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en': return AppLocalizationsEn();
    case 'es': return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
