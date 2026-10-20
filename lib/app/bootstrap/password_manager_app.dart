import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

import '../localization/app_locale_controller.dart';
import '../../core/security/aes_gcm_vault_crypto_service.dart';
import '../../core/security/android_keystore_envelope_key_provider.dart';
import '../../core/security/biometric_auth_service.dart';
import '../../core/security/biometric_key_envelope_service.dart';
import '../../core/security/biometric_unlock_service.dart';
import '../../core/security/common_password_blocklist.dart';
import '../../core/security/flutter_secure_storage_service.dart';
import '../../core/security/local_encrypted_vault_repository.dart';
import '../../core/security/master_password_service.dart';
import '../../core/security/secure_storage_service.dart';
import '../../core/security/native_biometric_auth_service.dart';
import '../../core/security/vault_repository.dart';
import '../../core/security/vault_security_controller.dart';
import '../../core/sync/device_registration_repository.dart';
import '../../core/sync/device_registration_service.dart';
import '../../core/sync/device_sync_bootstrap.dart';
import '../../core/sync/local_vault_mutation.dart';
import '../../features/home/presentation/app_shell.dart';
import '../../features/security/presentation/security_gate.dart';
import '../theme/app_theme.dart';

/// Bootstraps the app: wires the security layer, the locale
/// controller, the encrypted vault, and (when configured) the
/// Supabase sync layer, then mounts [PasswordManagerApp]. Called from
/// `main.dart`; tests that don't need a real platform channel
/// build a different widget tree directly.
Future<void> runPasswordManagerApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  final storage = FlutterSecureStorageService();
  final localeController = AppLocaleController(storage: storage);
  final mutationSink = RelayLocalVaultMutationSink();
  late final VaultSecurityController securityController;
  final repository = LocalEncryptedVaultRepository(
    storage: storage,
    cryptoService: AesGcmVaultCryptoService(),
    readSession: () => securityController.vaultSession,
    mutationSink: mutationSink,
  );
  final envelopeService = BiometricKeyEnvelopeService(storage: storage);
  final envelopeKeyProvider = _buildEnvelopeKeyProvider(storage: storage);
  // The biometric auth service is platform-aware: on Android we use
  // the native MethodChannel (the same one the KeyStore provider uses
  // to open the BiometricPrompt) so the gate and the prompt can never
  // disagree. On every other target we fall back to local_auth which
  // does not have a hardware-backed variant yet.
  final biometricAuthService = _buildBiometricAuthService();
  final biometricUnlockService = BiometricUnlockService(
    storage: storage,
    biometricAuthService: biometricAuthService,
    envelopeService: envelopeService,
    envelopeKeyProvider: envelopeKeyProvider,
  );
  securityController = VaultSecurityController(
    storage: storage,
    masterPasswordService: MasterPasswordService(),
    biometricAuthService: biometricAuthService,
    rekeyEntries: repository.rekeyEntries,
    migrateEntries: repository.migrateItemsToCurrentVersion,
    biometricEnvelopeService: envelopeService,
    biometricUnlockService: biometricUnlockService,
  );

  await securityController.initialize();
  await localeController.initialize();

  final deviceSyncLifecycle = await buildDeviceSyncLifecycle(
    storage: storage,
    vaultRepository: repository,
    mutationSink: mutationSink,
    onCurrentDeviceRevoked: (DeviceAccessStatus status) {
      return securityController.lock(reason: status.userFacingReason());
    },
  );

  runApp(
    PasswordManagerApp(
      repository: repository,
      securityController: securityController,
      localeController: localeController,
      secureStorage: storage,
      deviceSyncLifecycle: deviceSyncLifecycle,
    ),
  );

  // Fire-and-forget on purpose. The breach corpus is ~2.7 MB of digests
  // and takes tens of milliseconds to parse; blocking the first frame on
  // it would make startup feel slower for a screen that does not need it
  // yet. Until it lands, password screening falls back to the in-source
  // curated list, which is correct but smaller: a password typed in the
  // first moments after launch is screened against the short list. That
  // trade is stated in ADR-001 rather than hidden.
  unawaited(loadBreachCorpus());
}

/// On Android we use the hardware-backed KeyStore provider. On every
/// other target we fall back to a no-op provider that always reports
/// "no envelope key", which surfaces a clean "biometrics not
/// available" message instead of crashing.
///
/// Tests that don't want to involve the platform channel can override
/// the provider in their own bootstrap.
BiometricEnvelopeKeyProvider _buildEnvelopeKeyProvider({
  required dynamic storage,
}) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidKeystoreEnvelopeKeyProvider(
      storage: storage as FlutterSecureStorageService,
    );
  }
  // The unlock service replaces this with its own no-op default if
  // we pass null, so this branch is only here to make the intent
  // explicit in the source.
  return const _NullEnvelopeKeyProvider();
}

/// Picks the right [BiometricAuthService] for the current platform.
///
/// On Android we deliberately bypass `local_auth` and talk to the
/// native `MethodChannel` directly so the gate (canAuthenticate) and
/// the prompt (`BiometricPrompt.authenticate`) are guaranteed to be
/// looking at the same `BiometricManager` state. Mixing the two was
/// the root cause of the "the unlock button disappeared" bug on
/// devices that only have weak biometrics enrolled.
///
/// On every other target we keep the `local_auth` path since the
/// KeyStore-backed provider is Android-only.
BiometricAuthService _buildBiometricAuthService() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return NativeBiometricAuthService();
  }
  return LocalBiometricAuthService();
}

class _NullEnvelopeKeyProvider implements BiometricEnvelopeKeyProvider {
  const _NullEnvelopeKeyProvider();

  @override
  Future<BiometricEnvelopeKeyResult> acquireEnvelopeKey() async {
    return const BiometricEnvelopeKeyResult.unavailable(
      'platform_not_android',
    );
  }

  @override
  Future<BiometricEnvelopeKeyResult> releaseEnvelopeKey() async {
    return const BiometricEnvelopeKeyResult.unavailable(
      'platform_not_android',
    );
  }
}

/// Root widget of the app. Wires the [MaterialApp] (theme,
/// localizations, locale) and mounts the [SecurityGate] over the
/// [AppShell]. All collaborators are required; the secure [storage]
/// is passed down so screens can read locale / preferences without
/// each holding their own reference.
class PasswordManagerApp extends StatelessWidget {
  /// Builds the root widget. All collaborators are required.
  const PasswordManagerApp({
    super.key,
    required this.repository,
    required this.securityController,
    required this.localeController,
    required this.secureStorage,
    this.deviceSyncLifecycle,
  });

  /// Encrypted vault repository. Injected so the [AppShell] can
  /// re-key without holding its own reference.
  final VaultRepository repository;

  /// Single source of truth for vault lock state. Drives the
  /// [SecurityGate].
  final VaultSecurityController securityController;

  /// Locale preference controller. The [MaterialApp.locale] is
  /// wired to [AppLocaleController.locale].
  final AppLocaleController localeController;

  /// Secure storage handle. Passed down for screens that need
  /// direct read access to locale / preferences.
  final SecureStorageService secureStorage;

  /// Optional device sync lifecycle. When non-null, the [AppShell]
  /// picks up the conflict resolver and revocation service from it.
  final DeviceSyncLifecycle? deviceSyncLifecycle;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: localeController,
      builder: (context, _) {
        return MaterialApp(
          onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: defaultTargetPlatform == TargetPlatform.windows
              ? ThemeMode.dark
              : ThemeMode.system,
          locale: localeController.locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: SecurityGate(
            controller: securityController,
            deviceSyncLifecycle: deviceSyncLifecycle,
            child: AppShell(
              repository: repository,
              securityController: securityController,
              localeController: localeController,
              conflictResolver: deviceSyncLifecycle?.conflictResolver,
              revocationService: deviceSyncLifecycle?.revocationService,
              secureStorage: secureStorage,
            ),
          ),
        );
      },
    );
  }
}
