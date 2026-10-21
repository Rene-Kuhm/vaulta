import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

import '../localization/app_locale_controller.dart';
import '../../core/sync/remote_snapshot_applier.dart';
import '../../core/storage/lazy_sqlite_vault_repository.dart';
import '../../core/storage/vault_storage_flags.dart';
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
  final cryptoService = AesGcmVaultCryptoService();

  // The payload floor lives in secure storage and the SQLite repository needs it
  // through a synchronous getter, so it is read once during bootstrap.
  var payloadFloor = 1;
  Future<void> readPayloadFloor() async {
    final raw = await storage.read(
      LocalEncryptedVaultRepository.itemPayloadMinVersionKey,
    );
    payloadFloor = (raw == null || raw.isEmpty)
        ? 1
        : int.tryParse(raw) ??
              LocalEncryptedVaultRepository.currentItemPayloadVersion;
  }

  // ADR-007: the encrypted database is behind a compile-time flag, off by
  // default. Both paths are [VaultRepository]; only the rekey and payload-upgrade
  // hooks differ, because the database re-keys a file instead of re-encrypting a
  // blob.
  final VaultRepository repository;
  final VaultRekeyEntries rekeyHook;
  final VaultMigrateEntries migrateHook;
  // Sync's pull path applies snapshots through this narrow port, and both
  // storages implement it, so a pulled change reaches the vault whichever one
  // the flag selects. `buildDeviceSyncLifecycle` still documents `null` as
  // "pull advances sync state, vault unchanged", but nothing here passes it any
  // more.
  late final RemoteSnapshotApplier snapshotApplier;
  if (vaultSqliteStorageEnabled) {
    final sqlite = LazySqliteVaultRepository(
      storage: storage,
      cryptoService: cryptoService,
      readSession: () => securityController.vaultSession,
      readMinimumVersion: () => payloadFloor,
      databasePath: () async {
        final directory = await getApplicationSupportDirectory();
        return '${directory.path}/vault.db';
      },
    );
    repository = sqlite;
    rekeyHook = sqlite.rekeyEntries;
    migrateHook = sqlite.migrateItemsToCurrentVersion;
    snapshotApplier = sqlite;
  } else {
    final blob = LocalEncryptedVaultRepository(
      storage: storage,
      cryptoService: cryptoService,
      readSession: () => securityController.vaultSession,
      mutationSink: mutationSink,
    );
    repository = blob;
    rekeyHook = blob.rekeyEntries;
    migrateHook = blob.migrateItemsToCurrentVersion;
    snapshotApplier = blob;
  }
  await readPayloadFloor();
  final envelopeService = BiometricKeyEnvelopeService(storage: storage);
  // The biometric stack is resolved in ONE place. It used to be two
  // independent `defaultTargetPlatform` branches — one for the envelope
  // key provider, one for the auth service — and nothing tied the two
  // together, so pairing the KeyStore provider with the self-prompting
  // `local_auth` gate was a one-line mistake away and would have shown
  // the user two biometric prompts per unlock. [BiometricStack] makes
  // each platform's pairing a type instead.
  final biometricStack = resolveBiometricStack(storage: storage);
  final biometricAuthService = biometricStack.authService;
  final biometricUnlockService = BiometricUnlockService(
    storage: storage,
    biometricAuthService: biometricAuthService,
    envelopeService: envelopeService,
    envelopeKeyProvider: biometricStack.envelopeKeyProvider,
  );
  securityController = VaultSecurityController(
    storage: storage,
    masterPasswordService: MasterPasswordService(),
    biometricAuthService: biometricAuthService,
    rekeyEntries: rekeyHook,
    migrateEntries: migrateHook,
    biometricEnvelopeService: envelopeService,
    biometricUnlockService: biometricUnlockService,
  );

  await securityController.initialize();
  await localeController.initialize();

  final deviceSyncLifecycle = await buildDeviceSyncLifecycle(
    storage: storage,
    vaultRepository: snapshotApplier,
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

/// Everything the biometric unlock path needs for one platform, as a
/// single value.
///
/// The property this type exists to protect is "exactly one
/// `BiometricPrompt` per unlock". Two halves of the unlock path can each
/// open a prompt — the gate ([BiometricAuthService.authenticateForUnlock])
/// and the envelope key provider
/// ([BiometricEnvelopeKeyProvider.releaseEnvelopeKey]) — and only one of
/// them may. Which half owns it is a per-platform fact, so it belongs in
/// the composition rather than in a comment next to an `if`:
///
///   * Android — [AndroidKeystoreBiometricStack]. The prompt has to be
///     bound to the KeyStore private key through a `CryptoObject`, so
///     the provider owns it and the gate stays a probe
///     ([NonPromptingBiometricAuthService]).
///   * Every other target — [LocalAuthBiometricStack]. There is no
///     platform-protected envelope key, so the gate owns the prompt
///     ([PromptingBiometricAuthService]) and the provider is inert.
///
/// [BiometricStack] is sealed and both subclasses are `final`, so adding
/// a platform means adding a case here, where the pairing is visible,
/// instead of adding a branch next to an unrelated one.
sealed class BiometricStack {
  const BiometricStack();

  /// The gate the controller and the unlock service talk to.
  BiometricAuthService get authService;

  /// The provider that mints (enrollment) and releases (unlock) the
  /// platform-protected envelope key.
  BiometricEnvelopeKeyProvider get envelopeKeyProvider;
}

/// Android: the hardware-backed KeyStore pair. Exactly one prompt, and it
/// is the one the KeyStore crypto object requires.
final class AndroidKeystoreBiometricStack extends BiometricStack {
  /// Wires the native gate to the native provider. [storage] backs the
  /// RSA-encrypted seed, so both halves have to be built together.
  AndroidKeystoreBiometricStack({required FlutterSecureStorageService storage})
    : authService = NativeBiometricAuthService(),
      envelopeKeyProvider = AndroidKeystoreEnvelopeKeyProvider(
        storage: storage,
      );

  @override
  final NativeBiometricAuthService authService;

  @override
  final AndroidKeystoreEnvelopeKeyProvider envelopeKeyProvider;
}

/// Every non-Android target: `local_auth` owns the prompt and the
/// provider reports "not supported" instead of touching a channel that
/// was never registered.
final class LocalAuthBiometricStack extends BiometricStack {
  /// Builds the desktop / web stack, where there is no platform key.
  LocalAuthBiometricStack()
    : authService = LocalBiometricAuthService(),
      envelopeKeyProvider = const _NullEnvelopeKeyProvider();

  @override
  final LocalBiometricAuthService authService;

  @override
  final BiometricEnvelopeKeyProvider envelopeKeyProvider;
}

/// Resolves the biometric stack for the current platform. This is the
/// only place that branch lives.
///
/// On Android we deliberately bypass `local_auth` and talk to the native
/// `MethodChannel`s directly, so the gate (`BiometricManager`) and the
/// prompt are guaranteed to be looking at the same state. Mixing the two
/// was the root cause of the "the unlock button disappeared" bug on
/// devices that only have weak biometrics enrolled. On every other target
/// we keep the `local_auth` path, since the KeyStore-backed provider is
/// Android-only.
BiometricStack resolveBiometricStack({
  required FlutterSecureStorageService storage,
}) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidKeystoreBiometricStack(storage: storage);
  }
  return LocalAuthBiometricStack();
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
