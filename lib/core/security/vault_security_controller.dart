import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'biometric_auth_service.dart';
import 'biometric_key_envelope_service.dart';
import 'biometric_unlock_service.dart';
import 'master_password_record.dart';
import 'master_password_service.dart';
import 'native_biometric_auth_service.dart';
import 'secure_storage_service.dart';
import 'sensitive_clipboard_service.dart';
import 'unlock_attempt_limiter.dart';
import 'vault_session.dart';

/// Function signature for the repository rekey hook. The controller
/// calls this when the master password changes so every entry can be
/// re-encrypted under the new DEK.
typedef VaultRekeyEntries =
    Future<void> Function({
      required VaultSession sourceSession,
      required VaultSession targetSession,
    });

/// Function signature for the repository hook that upgrades every
/// stored item to the current payload format (v3, record-bound AAD).
/// The controller calls it after each successful unlock, once the new
/// session is active. It must be idempotent.
typedef VaultMigrateEntries = Future<void> Function();

/// Top-level UI state of the vault. Drives which screen the
/// [SecurityGate] renders.
enum VaultSecurityStage {
  /// Transient state while the controller reads persisted state.
  loading,

  /// No master password record on disk; show the create-vault flow.
  onboarding,

  /// Record exists but no in-memory session; show the unlock screen.
  locked,

  /// Session is active; show the app shell.
  unlocked,
}

/// Single source of truth for vault unlock state, biometric toggle,
/// idle auto-lock, and lifecycle hooks. UI widgets listen to this
/// via [ChangeNotifier] and render accordingly.
///
/// Construct once at app startup, run [initialize] before mounting
/// the UI. From then on, all mutations go through this controller.
class VaultSecurityController extends ChangeNotifier {
  /// Builds a [VaultSecurityController]. All collaborators are
  /// required except the optional [biometricUnlockService] (when
  /// omitted, biometric unlock is not available).
  ///
  /// [storage] persists the master password record and preferences.
  /// [masterPasswordService] runs the KDF and record lifecycle.
  /// [biometricAuthService] probes the platform's biometric gate.
  /// [rekeyEntries] is the repository hook invoked on master password
  /// change to re-encrypt every entry. [migrateEntries] is the
  /// repository hook run after every successful unlock to upgrade
  /// stored items to the current payload format; if it fails the vault
  /// stays locked. [biometricEnvelopeService]
  /// wraps the DEK for biometric unlock; defaults to a service built
  /// from [storage]. [biometricUnlockService] is the runtime unlock
  /// orchestrator. [unlockAttemptLimiter] throttles master-password
  /// guesses; defaults to a limiter persisted in [storage] that uses
  /// the system clock. [clipboard] is cleared on [lock]; defaults to
  /// [SensitiveClipboardService.shared].
  VaultSecurityController({
    required SecureStorageService storage,
    required MasterPasswordService masterPasswordService,
    required BiometricAuthService biometricAuthService,
    VaultRekeyEntries? rekeyEntries,
    VaultMigrateEntries? migrateEntries,
    BiometricKeyEnvelopeService? biometricEnvelopeService,
    BiometricUnlockService? biometricUnlockService,
    UnlockAttemptLimiter? unlockAttemptLimiter,
    SensitiveClipboardService? clipboard,
  }) : _storage = storage,
       _masterPasswordService = masterPasswordService,
       _biometricAuthService = biometricAuthService,
       _rekeyEntries = rekeyEntries ?? _unsupportedRekey,
       _migrateEntries = migrateEntries,
       _biometricEnvelopeService = biometricEnvelopeService ??
           BiometricKeyEnvelopeService(storage: storage),
       _biometricUnlockService = biometricUnlockService,
       _unlockAttemptLimiter =
           unlockAttemptLimiter ?? UnlockAttemptLimiter(storage: storage),
       _clipboard = clipboard ?? SensitiveClipboardService.shared;

  /// Secure storage key for the serialized [MasterPasswordRecord].
  static const masterPasswordRecordKey = 'vault_master_password_record';

  /// Secure storage key for the user biometric-enabled preference.
  static const biometricEnabledKey = 'vault_biometric_enabled';

  /// Secure storage key for the auto-lock-on-background preference.
  static const autoLockOnBackgroundEnabledKey =
      'vault_auto_lock_on_background_enabled';

  /// Secure storage key for the configured idle timeout (seconds).
  static const idleTimeoutSecondsKey = 'vault_idle_timeout_seconds';

  /// Default idle timeout in seconds (15 minutes) used when no
  /// stored preference is present.
  static const defaultIdleTimeoutSeconds = 900;
  static const _interactionResetThrottle = Duration(milliseconds: 750);

  final SecureStorageService _storage;
  final MasterPasswordService _masterPasswordService;
  final BiometricAuthService _biometricAuthService;
  final VaultRekeyEntries _rekeyEntries;
  final VaultMigrateEntries? _migrateEntries;
  final BiometricKeyEnvelopeService _biometricEnvelopeService;
  final BiometricUnlockService? _biometricUnlockService;
  final UnlockAttemptLimiter _unlockAttemptLimiter;
  bool _unlockAttemptStateUnavailable = false;
  final SensitiveClipboardService _clipboard;

  VaultSecurityStage _stage = VaultSecurityStage.loading;
  BiometricAvailability _biometricAvailability = const BiometricAvailability(
    deviceSupported: false,
    canCheckBiometrics: false,
    availableBiometrics: [],
  );
  bool _biometricEnabled = false;
  bool _busy = false;
  String? _message;
  VaultSession? _vaultSession;
  bool _autoLockOnBackgroundEnabled = true;
  int _idleTimeoutSeconds = defaultIdleTimeoutSeconds;
  Timer? _idleTimer;
  DateTime? _lastInteractionAt;
  /// Stack of "long-running flows" that need the auto-lock to stand
  /// down. Each call to [beginLongRunningFlow] pushes onto the stack
  /// and each call to [endLongRunningFlow] pops. While the stack is
  /// non-empty, the [handleAppLifecycleState] branch that locks the
  /// vault when the app loses foreground is skipped, so flows like
  /// the import picker (which inevitably hands the foreground to the
  /// system file picker) do not get the user kicked back to the
  /// unlock screen mid-flow.
  ///
  /// Using a stack rather than a single bool means two features can
  /// each take a pause independently and the controller only resumes
  /// normal auto-lock when *all* of them are done. The previous
  /// one-flag design leaked: a screen that requested a pause and
  /// crashed before releasing it left the vault permanently
  /// un-lockable by background, which is exactly the kind of silent
  /// footgun this kind of state always turns into.
  int _longRunningFlowCount = 0;
  /// Cached state of the wrapped-DEK envelope on disk. Refreshed on
  /// initialize, after every successful enrollment, and after every
  /// successful biometric unlock. The unlock screen uses this to
  /// decide whether to render the "Activate biometric unlock" CTA
  /// without having to hit the secure storage on every build.
  bool _envelopeEnrolled = false;

  /// Current UI stage (loading / onboarding / locked / unlocked).
  VaultSecurityStage get stage => _stage;

  /// Last-known biometric availability snapshot from the platform.
  BiometricAvailability get biometricAvailability => _biometricAvailability;

  /// True when the user has biometric unlock turned on.
  bool get biometricEnabled => _biometricEnabled;

  /// True when the wrapped-DEK envelope is currently persisted. The
  /// unlock screen renders the one-tap biometric-setup CTA when
  /// the user has the preference on (or the device has biometrics
  /// enrolled and the user has not turned it on yet) but this
  /// envelope is missing — the two conditions are not the same.
  bool get isBiometricEnvelopeEnrolled => _envelopeEnrolled;

  /// True while a long-running unlock / rekey operation is in flight.
  bool get busy => _busy;

  /// Latest human-readable status message (success or error). Cleared
  /// on the next user action.
  String? get message => _message;

  /// Heuristic tone for the current [message]. The controller itself
  /// does not store a flag because the existing 40+ `_message = …`
  /// sites all use natural-language strings; classifying the tone
  /// here keeps the call sites simple and the visual layer out of
  /// the controller's contract.
  ///
  /// The rule is intentionally narrow: only surface a "danger" tone
  /// for phrases that clearly read as a failure, and an
  /// "info/positive" tone otherwise.
  bool get messageIsError {
    final m = _message;
    if (m == null || m.isEmpty) return false;
    final lower = m.toLowerCase();
    const negative = [
      'no coincide',
      'no pudimos',
      'no se pudo',
      'todavia no',
      'no hay biometria',
      'no esta conectado',
      'error',
      'fail',
      'inv',
      'rechaz',
      'cancel',
      'deneg',
    ];
    for (final word in negative) {
      if (lower.contains(word)) return true;
    }
    return false;
  }

  /// Time left before another master-password attempt is allowed, or
  /// `null` when an attempt is allowed now. The unlock screen polls
  /// this to render the lockout countdown.
  Duration? get unlockLockoutRemaining =>
      _unlockAttemptLimiter.remainingLockout();

  /// True while too many failed master-password attempts keep the
  /// unlock button disabled.
  bool get isUnlockLockedOut => unlockLockoutRemaining != null;

  /// True when the last master-password attempt was refused because
  /// the attempt counter could not be read from or written to secure
  /// storage (fail closed: the password was not checked). The UI
  /// renders a localized error for it. Cleared on the next attempt.
  bool get unlockAttemptStateUnavailable => _unlockAttemptStateUnavailable;

  /// Consecutive failed master-password attempts since the last
  /// successful unlock.
  int get failedUnlockAttempts => _unlockAttemptLimiter.failedCount;

  /// Active in-memory vault session, or `null` when locked.
  VaultSession? get vaultSession => _vaultSession;

  /// True when the vault locks the moment the app goes to background.
  bool get autoLockOnBackgroundEnabled => _autoLockOnBackgroundEnabled;

  /// Configured idle timeout in seconds (0 means disabled).
  int get idleTimeoutSeconds => _idleTimeoutSeconds;

  /// Configured idle timeout as a [Duration], or `null` when disabled.
  Duration? get idleTimeout =>
      _idleTimeoutSeconds <= 0 ? null : Duration(seconds: _idleTimeoutSeconds);

  /// True when the vault is currently unlocked.
  bool get isUnlocked => _stage == VaultSecurityStage.unlocked;

  /// True when the device can offer the biometric toggle (hardware
  /// present + biometric enrolled).
  bool get canOfferBiometricToggle =>
      _biometricAvailability.canAuthenticate &&
      _biometricAvailability.hasEnrolledBiometrics;

  /// True when there is a real path to a biometric unlock on this
  /// device: the platform supports it, biometrics are enrolled, AND
  /// a wrapped-DEK envelope exists on disk for this vault.
  ///
  /// The flag is computed on demand because the platform keychain
  /// state can change between app launches and we never want to show
  /// a biometric button that would just fail.
  Future<bool> canUnlockWithBiometrics() async {
    final unlocker = _biometricUnlockService;
    if (unlocker == null) {
      debugPrint('[Vaulta] canUnlock: no unlocker wired up');
      return false;
    }
    final result = await unlocker.canAttemptUnlock();
    debugPrint('[Vaulta] canUnlock=$result '
        '(enrolled=${_biometricAvailability.hasEnrolledBiometrics}, '
        'canAuth=${_biometricAvailability.canAuthenticate}, '
        'flag=$_biometricEnabled)');
    return result;
  }

  /// True when the unlock screen should *offer* a biometric button.
  /// This is broader than [canUnlockWithBiometrics]: it returns true
  /// as long as the device can authenticate with biometrics AND the
  /// user has the preference on. The actual unlock might still fail
  /// (e.g. no envelope on disk yet) and the controller will explain
  /// the reason in the message.
  ///
  /// The unlock screen uses this to decide whether to render the
  /// fingerprint button. Hiding the button entirely when enrollment
  /// failed silently in the past was a UX trap: the user flipped the
  /// toggle and saw nothing happen.
  bool get canOfferBiometricUnlockButton {
    if (!_biometricEnabled) return false;
    if (!canOfferBiometricToggle) return false;
    return _biometricUnlockService != null;
  }

  /// Single source of truth for the "you have to unlock with the
  /// master password once before biometrics will work" hint. The
  /// proactive unlock-screen banner and the post-failure message
  /// both reference this constant so the user only sees the line
  /// once, no matter which path surfaced it.
  static const biometricNeedsPasswordFirstMessage =
      'Toca el boton "Activar desbloqueo biometrico" abajo para '
      'preparar tu huella. La master password no se guarda ni se envia '
      'a ningun servidor.';

  /// Latest human-readable status of the biometric unlock path, for
  /// the unlock screen to surface when the button is offered but the
  /// underlying envelope is not yet on disk. Returns null when there
  /// is nothing useful to say.
  Future<String?> biometricUnlockStatusMessage() async {
    if (!canOfferBiometricUnlockButton) return null;
    if (await _biometricEnvelopeService.isEnrolled()) {
      return null;
    }
    return biometricNeedsPasswordFirstMessage;
  }

  /// Returns the raw native platform capability, when the active
  /// [BiometricAuthService] is a [NativeBiometricAuthService].
  /// Falls back to [NativeBiometricCapability.empty] on other
  /// targets so the UI never has to special-case platforms.
  Future<NativeBiometricCapability> probeBiometricCapability() async {
    final service = _biometricAuthService;
    if (service is NativeBiometricAuthService) {
      return service.probeCapability();
    }
    return NativeBiometricCapability.empty;
  }

  /// Opens the system biometric-enrollment settings. Returns true
  /// if the intent was launched, false otherwise. The settings
  /// screen uses this to deep-link the user into the platform setup
  /// when [NativeBiometricCapability.needsEnrollment] is true.
  Future<bool> openBiometricEnrollment() async {
    final service = _biometricAuthService;
    if (service is NativeBiometricAuthService) {
      return service.openBiometricEnrollment();
    }
    return false;
  }

  /// Loads the persisted master password record and biometric
  /// preferences, then transitions the stage from [VaultSecurityStage.loading]
  /// to either [VaultSecurityStage.onboarding] (no record) or
  /// [VaultSecurityStage.locked]. Call once at app startup.
  Future<void> initialize() async {
    _setBusy(true);
    _message = null;

    try {
      _biometricAvailability = await _biometricAuthService.getAvailability();
      _biometricEnabled = await _storage.read(biometricEnabledKey) == 'true';
      _autoLockOnBackgroundEnabled =
          await _readBool(
            key: autoLockOnBackgroundEnabledKey,
            fallback: true,
          ) ??
          true;
      _idleTimeoutSeconds =
          await _readInt(
            key: idleTimeoutSecondsKey,
            fallback: defaultIdleTimeoutSeconds,
            min: 0,
          ) ??
          defaultIdleTimeoutSeconds;
      // The limiter fails closed internally (unreadable state starts
      // a lockout), so it never throws into this catch-all.
      await _unlockAttemptLimiter.load();

      final record = await _readRecord();
      _envelopeEnrolled = await _biometricEnvelopeService.isEnrolled();
      _stage = record == null
          ? VaultSecurityStage.onboarding
          : VaultSecurityStage.locked;

      // If the user previously turned biometrics on but the platform
      // enrollment is gone (e.g. they removed their fingerprint from
      // the device or wiped the keystore), drop the preference so the
      // UI does not lie about what's available. The wrapped envelope
      // is also wiped because without the platform-protected key it
      // is useless.
      if (_biometricEnabled && !canOfferBiometricToggle) {
        _biometricEnabled = false;
        await _storage.save(biometricEnabledKey, 'false');
        await _biometricEnvelopeService.clear();
      }
    } catch (_) {
      _stage = VaultSecurityStage.onboarding;
      _message =
          'No pudimos leer el estado seguro del dispositivo. Reinicia la configuracion.';
    } finally {
      _setBusy(false);
      notifyListeners();
    }
  }

  /// First-run flow: validates the password, creates a new
  /// [MasterPasswordRecord], derives the DEK, and transitions to
  /// [VaultSecurityStage.unlocked]. Returns true on success.
  Future<bool> createMasterPassword({
    required String password,
    required String confirmation,
    required bool enableBiometrics,
  }) async {
    final validationError = _masterPasswordService.validate(password);
    if (validationError != null) {
      _message = validationError;
      notifyListeners();
      return false;
    }

    if (password != confirmation) {
      _message = 'La confirmacion no coincide con la master password.';
      notifyListeners();
      return false;
    }

    if (enableBiometrics && !canOfferBiometricToggle) {
      _message = 'La biometria todavia no esta disponible en este dispositivo.';
      notifyListeners();
      return false;
    }

    return _runBusy(() async {
      final record = await _masterPasswordService.createRecord(password);
      _vaultSession = VaultSession.v2(
        keyId: record.keyId,
        secretKey: await _masterPasswordService.deriveVaultKey(
          record: record,
          password: password,
        ),
        kdf: record.kdf!,
        dekWrap: record.dekWrap!,
      );
      await _storage.save(masterPasswordRecordKey, record.encode());
      if (!await _migrateEntriesAfterUnlock()) {
        return false;
      }
      await _persistBiometricPreference(enableBiometrics);
      await _enrollBiometricEnvelopeIfNeeded(record);

      _message =
          'Master password creada. Tu sesion local queda protegida por el sistema.';
      _stage = VaultSecurityStage.unlocked;
      _restartIdleTimer();
      return true;
    });
  }

  /// Recovers the DEK from the wrapped envelope in the persisted
  /// record using [password]. On success, transitions to
  /// [VaultSecurityStage.unlocked] and returns true.
  ///
  /// Throttled by [UnlockAttemptLimiter]: while [isUnlockLockedOut] is
  /// true the call returns false immediately, without running the KDF.
  /// The unlock screen renders the localized lockout banner from
  /// [unlockLockoutRemaining], so [message] is cleared in that case.
  Future<bool> unlockWithPassword(String password) async {
    if (isUnlockLockedOut) {
      _message = null;
      notifyListeners();
      return false;
    }
    return _runBusy(() async {
      final record = await _readRecord();
      if (record == null) {
        _stage = VaultSecurityStage.onboarding;
        _message = 'Todavia no configuraste una master password.';
        return false;
      }

      final verified = await _verifyThrottled(
        record: record,
        password: password,
        mismatchMessage: 'La master password no coincide.',
      );
      if (!verified) {
        return false;
      }

      final sourceSession = VaultSession(
        keyId: record.keyId,
        secretKey: await _masterPasswordService.deriveVaultKey(
          record: record,
          password: password,
        ),
        kdf: record.kdf,
        dekWrap: record.dekWrap,
      );

      var activeRecord = record;
      var activeSession = sourceSession;
      if (record.version < 2 || record.kdf == null || record.dekWrap == null) {
        final migratedRecord = await _masterPasswordService.createRecord(
          password,
        );
        final migratedSession = VaultSession.v2(
          keyId: migratedRecord.keyId,
          secretKey: await _masterPasswordService.deriveVaultKey(
            record: migratedRecord,
            password: password,
          ),
          kdf: migratedRecord.kdf!,
          dekWrap: migratedRecord.dekWrap!,
        );
        await _rekeyEntries(
          sourceSession: sourceSession,
          targetSession: migratedSession,
        );
        await _storage.save(masterPasswordRecordKey, migratedRecord.encode());
        activeRecord = migratedRecord;
        activeSession = migratedSession;
        // Re-enroll the envelope after migration so the new DEK is the
        // one wrapped on disk, not the v1 derived key.
        await _enrollBiometricEnvelopeIfNeeded(activeRecord);
      }

      _vaultSession = activeSession;
      if (!await _migrateEntriesAfterUnlock()) {
        return false;
      }

      // Always try to (re)enroll the biometric envelope on a fresh
      // unlock. The enrollment is silent (no biometric prompt) and
      // only persists the wrapped DEK + RSA-encrypted seed. If the
      // platform cannot provide a key slot (e.g. user removed their
      // fingerprint from the device between unlocks) the call is a
      // no-op and the unlock button will simply not appear next time.
      if (!await _biometricEnvelopeService.isEnrolled() &&
          _biometricEnabled &&
          canOfferBiometricToggle) {
        debugPrint('[Vaulta] envelope missing, retrying enrollment');
        await _enrollBiometricEnvelopeIfNeeded(activeRecord);
      }
      _envelopeEnrolled = await _biometricEnvelopeService.isEnrolled();

      _message = activeRecord == record
          ? 'Vaulta desbloqueada.'
          : 'Vaulta desbloqueada y migrada a cifrado v2.';
      _stage = VaultSecurityStage.unlocked;
      _restartIdleTimer();
      return true;
    });
  }

  /// Triggers a biometric unlock. Returns true on success (DEK
  /// recovered, session active). Returns false (without throwing)
  /// on any structured failure: user cancel, no envelope on disk,
  /// platform rejection. The caller should check the message
  /// afterwards for the reason.
  Future<bool> unlockWithBiometrics() async {
    final unlocker = _biometricUnlockService;
    if (unlocker == null) {
      _message =
          'El desbloqueo biometrico todavia no esta conectado en este dispositivo.';
      notifyListeners();
      return false;
    }

    return _runBusy(() async {
      final record = await _readRecord();
      if (record == null) {
        _stage = VaultSecurityStage.onboarding;
        _message = 'Todavia no configuraste una master password.';
        return false;
      }

      final outcome = await unlocker.unlock(record: record);
      switch (outcome) {
        case BiometricUnlockSuccess(:final session):
          // A successful biometric unlock proves the legitimate user is
          // present, so it clears the master-password failure counter.
          // Biometric failures themselves are throttled by the OS and
          // are not counted here.
          await _unlockAttemptLimiter.recordSuccess();
          _vaultSession = session;
          if (!await _migrateEntriesAfterUnlock()) {
            return false;
          }
          _stage = VaultSecurityStage.unlocked;
          _envelopeEnrolled = true;
          _message = 'Vaulta desbloqueada con biometria.';
          _restartIdleTimer();
          return true;
        case BiometricUnlockNeedsPasswordFirst(:final reason):
          // The unlock screen already shows
          // [biometricNeedsPasswordFirstMessage] as the proactive
          // banner. Repeating it in [message] would render two
          // identical banners stacked on top of each other, which
          // is exactly the layout the user reported in the bug
          // capture. We leave [message] null so the unlock screen
          // renders only the proactive banner.
          _message = null;
          debugPrint('[Vaulta] biometric unlock needs password-first '
              'enrollment: $reason');
          return false;
        case BiometricUnlockRejected(:final reason):
          _message = reason;
          // A rejection that looks like a stale envelope should be
          // cleared so the next attempt is a clean password unlock
          // and the user is not stuck retrying a broken path.
          if (reason.contains('inconsistente') ||
              reason.contains('rechazo')) {
            await unlocker.invalidate();
            _biometricEnabled = false;
            await _storage.save(biometricEnabledKey, 'false');
          }
          return false;
        case BiometricUnlockUnavailable(:final reason):
          _message = reason;
          return false;
      }
    });
  }

  /// Toggles the biometric unlock preference. When enabling, the
  /// vault must be unlocked (so we can wrap the current DEK with a
  /// fresh envelope). When disabling, the existing envelope and
  /// platform key slot are wiped.
  Future<void> setBiometricEnabled(bool enabled) async {
    if (enabled && !canOfferBiometricToggle) {
      _message = 'No hay biometria configurada en este dispositivo.';
      notifyListeners();
      return;
    }

    await _runBusy(() async {
      await _persistBiometricPreference(enabled);
      if (enabled) {
        final record = await _readRecord();
        if (record != null) {
          await _enrollBiometricEnvelopeIfNeeded(record);
        }
        _message =
            'Biometria activada. La proxima vez podras desbloquear Vaulta con tu biometria.';
      } else {
        await _biometricEnvelopeService.clear();
        _message = 'Biometria desactivada. Solo queda la master password.';
      }
      return true;
    });
  }

  /// Drops the in-memory [VaultSession] and transitions to
  /// [VaultSecurityStage.locked]. The optional [reason] is shown in
  /// the lock screen (e.g. "auto-lock on background", "idle timeout").
  ///
  /// Locking also clears a secret Vaulta copied to the clipboard,
  /// unless [clearClipboard] is false. The background auto-lock passes
  /// false on purpose: it fires the moment the user switches apps,
  /// which is exactly when they switch to paste the secret they just
  /// copied. In that case the clipboard's own 30-second timer (native
  /// "clear if owned", which works from the background) removes it.
  /// Manual, idle-timeout and device-revoked locks clear immediately.
  Future<void> lock({String? reason, bool clearClipboard = true}) async {
    _cancelIdleTimer();
    _lastInteractionAt = null;
    _vaultSession = null;
    _stage = VaultSecurityStage.locked;
    _message = reason ?? 'Vaulta bloqueada.';
    // Safety net: if a screen died without releasing its long-running
    // flow counter, we do not want the next unlock to inherit a stuck
    // pause. The user explicitly chose to lock the vault, so the
    // auto-lock is allowed to fire again on the next foreground loss.
    _longRunningFlowCount = 0;
    notifyListeners();
    // Drop the session first (fail closed), then clear the clipboard.
    if (clearClipboard) {
      await _clipboard.clearIfOwned();
    }
  }

  /// Toggles the auto-lock-on-background preference and persists it.
  Future<void> setAutoLockOnBackgroundEnabled(bool enabled) async {
    await _runBusy(() async {
      _autoLockOnBackgroundEnabled = enabled;
      await _storage.save(autoLockOnBackgroundEnabledKey, enabled.toString());
      _message = enabled
          ? 'Auto-lock al ir a background activado.'
          : 'Auto-lock al ir a background desactivado.';
      return true;
    });
  }

  /// Sets the idle timeout in seconds. Use 0 to disable. Persists to
  /// secure storage and restarts the idle timer.
  Future<void> setIdleTimeoutSeconds(int seconds) async {
    if (seconds < 0) {
      return;
    }

    await _runBusy(() async {
      _idleTimeoutSeconds = seconds;
      await _storage.save(idleTimeoutSecondsKey, seconds.toString());
      if (_idleTimeoutSeconds == 0) {
        _cancelIdleTimer();
        _message = 'Auto-lock por inactividad desactivado.';
      } else {
        _restartIdleTimer();
        _message =
            'Auto-lock por inactividad activado (${_formatIdleTimeoutLabel(_idleTimeoutSeconds)}).';
      }
      return true;
    });
  }

  /// Call from any user interaction (tap, keystroke) to reset the
  /// idle auto-lock timer. Throttled internally so a stream of
  /// events doesn't fire [notifyListeners] constantly.
  void registerUserInteraction() {
    if (!isUnlocked || _idleTimeoutSeconds == 0) {
      return;
    }

    final now = DateTime.now();
    final lastInteractionAt = _lastInteractionAt;
    if (lastInteractionAt != null &&
        now.difference(lastInteractionAt) < _interactionResetThrottle) {
      return;
    }

    _lastInteractionAt = now;
    _restartIdleTimer();
  }

  /// Replaces the current master password. Verifies the current
  /// password, derives a new KEK, generates a new DEK, re-encrypts
  /// every entry via the supplied [rekeyEntries] hook, and persists
  /// the new record. Returns true on success.
  ///
  /// The current-password check is throttled by the same
  /// [UnlockAttemptLimiter] as [unlockWithPassword].
  Future<bool> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
    required String confirmation,
  }) async {
    if (!isUnlocked || _vaultSession == null) {
      _message = 'Desbloquea Vaulta antes de cambiar la master password.';
      notifyListeners();
      return false;
    }

    final validationError = _masterPasswordService.validate(newPassword);
    if (validationError != null) {
      _message = validationError;
      notifyListeners();
      return false;
    }

    if (newPassword != confirmation) {
      _message = 'La confirmacion no coincide con la nueva master password.';
      notifyListeners();
      return false;
    }

    if (currentPassword == newPassword) {
      _message = 'La nueva master password debe ser distinta de la actual.';
      notifyListeners();
      return false;
    }

    // Verifying the current password is a guessing oracle for anyone
    // holding an unlocked session, so it shares the unlock throttle.
    if (isUnlockLockedOut) {
      _message = null;
      notifyListeners();
      return false;
    }

    return _runBusy(() async {
      final currentRecord = await _readRecord();
      if (currentRecord == null) {
        _stage = VaultSecurityStage.onboarding;
        _message = 'Todavia no configuraste una master password.';
        return false;
      }

      final verified = await _verifyThrottled(
        record: currentRecord,
        password: currentPassword,
        mismatchMessage: 'La master password actual no coincide.',
      );
      if (!verified) {
        return false;
      }

      final sourceSession = _vaultSession;
      if (sourceSession == null) {
        _stage = VaultSecurityStage.locked;
        _message =
            'No hay una sesion de vault valida en memoria. Volve a desbloquear.';
        return false;
      }

      if (sourceSession.keyId != currentRecord.keyId) {
        _vaultSession = null;
        _stage = VaultSecurityStage.locked;
        _message =
            'La sesion activa no coincide con la clave maestra vigente. Volve a desbloquear antes de reintentar.';
        return false;
      }

      final newRecord = await _masterPasswordService.createRecord(newPassword);
      final targetSession = VaultSession.v2(
        keyId: newRecord.keyId,
        secretKey: await _masterPasswordService.deriveVaultKey(
          record: newRecord,
          password: newPassword,
        ),
        kdf: newRecord.kdf!,
        dekWrap: newRecord.dekWrap!,
      );

      try {
        await _rekeyEntries(
          sourceSession: sourceSession,
          targetSession: targetSession,
        );
      } catch (_) {
        _message =
            'No pudimos completar el re-cifrado del vault. Se mantuvo tu clave actual para evitar inconsistencias.';
        return false;
      }

      try {
        await _storage.save(masterPasswordRecordKey, newRecord.encode());
      } catch (_) {
        var rollbackSucceeded = false;
        try {
          await _rekeyEntries(
            sourceSession: targetSession,
            targetSession: sourceSession,
          );
          rollbackSucceeded = true;
        } catch (_) {
          rollbackSucceeded = false;
        }

        if (!rollbackSucceeded) {
          _vaultSession = null;
          _stage = VaultSecurityStage.locked;
          _message =
              'Fallo al persistir la nueva master password y no pudimos confirmar rollback completo. Vaulta queda bloqueada por seguridad.';
          return false;
        }

        _message =
            'No pudimos guardar la nueva master password. Se mantuvo tu clave actual para evitar inconsistencias.';
        return false;
      }

      _vaultSession = targetSession;
      // The DEK changed, so any previous biometric envelope is stale
      // and would unwrap to the wrong key. Wipe it and re-enroll under
      // the new DEK if the user still has biometrics enabled.
      await _biometricEnvelopeService.clear();
      await _enrollBiometricEnvelopeIfNeeded(newRecord);
      _message =
          'Master password actualizada y vault re-cifrado con una nueva clave.';
      return true;
    });
  }

  /// Hook for [WidgetsBindingObserver.didChangeAppLifecycleState].
  /// Locks the vault when the app loses foreground if
  /// [autoLockOnBackgroundEnabled] is on; otherwise resets the idle
  /// timer when the app comes back to foreground.
  Future<void> handleAppLifecycleState(AppLifecycleState state) async {
    if (!isUnlocked) {
      return;
    }

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _cancelIdleTimer();
        if (_longRunningFlowCount > 0) {
          // A feature explicitly asked us to stand down on the
          // background auto-lock for the duration of a flow that
          // necessarily hands the foreground to a system UI (the
          // import file picker is the canonical case). We do not
          // notify the user and we do not touch the session.
          return;
        }
        if (_autoLockOnBackgroundEnabled) {
          await lock(
            reason:
                'Vaulta bloqueada automaticamente al salir de primer plano.',
            // Keep copy-then-paste-in-another-app working; the
            // clipboard timer clears it. See [lock].
            clearClipboard: false,
          );
        }
        return;
      case AppLifecycleState.resumed:
        _restartIdleTimer();
        return;
    }
  }

  /// Marks the start of a flow that should not get the vault
  /// auto-locked when the app temporarily leaves the foreground.
  ///
  /// MUST be paired with a matching [endLongRunningFlow] call. The
  /// pairing is stack-based: nested calls are fine, the auto-lock
  /// only re-enables once every flow has called its end.
  ///
  /// Typical use: the import screen pushes before opening the
  /// `FilePicker` (which takes the foreground), and pops when the
  /// user either confirms the import or backs out of the screen.
  void beginLongRunningFlow() {
    _longRunningFlowCount++;
    if (_longRunningFlowCount == 1) {
      // The first time a flow starts, make sure the idle timer
      // does not fire while we are inside it. The user could be
      // doing nothing in Flutter land because the system picker
      // owns the foreground, so an idle-based lock would be
      // indistinguishable from a background lock.
      _cancelIdleTimer();
    }
  }

  /// Counterpart to [beginLongRunningFlow]. If a flow that began was
  /// never ended (for example, the screen was disposed mid-flow
  /// because the user backed out of the whole app), the stack is
  /// clamped back to zero on the next [lock] call so the system
  /// recovers gracefully. See [lock].
  void endLongRunningFlow() {
    if (_longRunningFlowCount > 0) {
      _longRunningFlowCount--;
    }
  }

  @override
  void dispose() {
    _cancelIdleTimer();
    super.dispose();
  }

  Future<void> _persistBiometricPreference(bool enabled) async {
    _biometricEnabled = enabled;
    await _storage.save(biometricEnabledKey, enabled.toString());
  }

  /// Enrolls the wrapped-DEK envelope if biometrics are enabled on
  /// this device and the platform reports a usable key slot. Silently
  /// no-ops when any precondition is missing — the unlock UI will
  /// surface the explanation.
  Future<void> _enrollBiometricEnvelopeIfNeeded(
    MasterPasswordRecord record,
  ) async {
    if (!_biometricEnabled) {
      debugPrint('[Vaulta] enroll skipped: biometricEnabled=false');
      return;
    }
    if (!canOfferBiometricToggle) {
      debugPrint('[Vaulta] enroll skipped: no biometric available '
          '(canAuth=${_biometricAvailability.canAuthenticate}, '
          'enrolled=${_biometricAvailability.hasEnrolledBiometrics})');
      return;
    }
    if (record.version < 2 || record.kdf == null || record.dekWrap == null) {
      debugPrint('[Vaulta] enroll skipped: record is not v2');
      return;
    }

    final unlocker = _biometricUnlockService;
    if (unlocker == null) {
      debugPrint('[Vaulta] enroll skipped: no unlock service');
      return;
    }

    final dekBytes = await _unwrapCurrentDek(record);
    if (dekBytes == null) {
      debugPrint('[Vaulta] enroll: no DEK in current session');
      return;
    }

    // This is the silent (post-password-unlock) enrollment path.
    // Failures here are not user-facing — the user just unlocked
    // with their password and the next unlock attempt will
    // re-attempt the enrollment, so we just log the reason for
    // diagnosis.
    final result = await _enrollEnvelopeWithDek(
      unlocker: unlocker,
      dekBytes: dekBytes,
    );
    if (!result.ok) {
      debugPrint('[Vaulta] silent enroll failed: ${result.reason}');
    }
  }

  /// Shared enrollment implementation that takes the DEK as a
  /// parameter. Used by [_enrollBiometricEnvelopeIfNeeded] (which
  /// reads the DEK out of the active session) and by
  /// [setupBiometricFromPassword] (which derives a one-shot DEK
  /// without unlocking the vault).
  ///
  /// Returns a `({bool ok, String? reason})` so callers can surface
  /// the *actual* failure reason in the unlock-screen banner. The
  /// previous version swallowed every null and reported a single
  /// generic "could not prepare fingerprint" string, which made
  /// platform-specific bugs impossible to diagnose from the UI.
  Future<({bool ok, String? reason})> _enrollEnvelopeWithDek({
    required BiometricUnlockService unlocker,
    required Uint8List dekBytes,
  }) async {
    BiometricEnvelopeKeyResult acquireResult;
    try {
      acquireResult =
          await unlocker.envelopeKeyProvider.acquireEnvelopeKey();
    } catch (error, stack) {
      debugPrint('[Vaulta] enroll: provider threw $error\n$stack');
      return (
        ok: false,
        reason: 'provider_threw:${error.runtimeType}',
      );
    }
    if (!acquireResult.isSuccess) {
      debugPrint('[Vaulta] enroll: provider returned failure '
          '${acquireResult.failureReason}');
      return (ok: false, reason: acquireResult.failureReason);
    }
    final envelopeKey = acquireResult.key!;
    try {
      await _biometricEnvelopeService.enroll(
        dekBytes: dekBytes,
        envelopeKey: envelopeKey,
      );
      debugPrint('[Vaulta] enroll: envelope persisted');
      return (ok: true, reason: null);
    } catch (error, stack) {
      debugPrint('[Vaulta] enroll: enroll() failed $error\n$stack');
      return (
        ok: false,
        reason: 'enroll_threw:${error.runtimeType}',
      );
    }
  }

  /// One-shot setup flow used by the unlock screen when the user
  /// wants to enable biometric unlock for the first time but the
  /// vault is still locked. We verify the master password (without
  /// unlocking), derive a throwaway DEK, enroll the wrapped-DEK
  /// envelope, and flip the biometric preference on. The vault
  /// stays locked — the user is still on the unlock screen and can
  /// choose to enter with their password or wait for the next
  /// unlock where the fingerprint will already work.
  ///
  /// Returns `true` on success and writes a friendly `_message`.
  /// Returns `false` on any failure (no record, no biometric, wrong
  /// password, missing v2 metadata, enrollment failure) and writes
  /// a specific `_message` for the UI.
  ///
  /// This flow runs on the lock screen and verifies the master
  /// password, so it is throttled by the same [UnlockAttemptLimiter]
  /// as [unlockWithPassword]; otherwise it would be an unthrottled
  /// guessing oracle.
  Future<bool> setupBiometricFromPassword(String password) async {
    if (isUnlockLockedOut) {
      _message = null;
      notifyListeners();
      return false;
    }
    return _runBusy(() async {
      final record = await _readRecord();
      if (record == null) {
        _message = 'Todavia no configuraste una master password.';
        return false;
      }

      if (!canOfferBiometricToggle) {
        _message = 'No hay biometria configurada en este dispositivo.';
        return false;
      }

      final verified = await _verifyThrottled(
        record: record,
        password: password,
        mismatchMessage: 'La master password no coincide.',
      );
      if (!verified) {
        return false;
      }

      if (record.version < 2 || record.kdf == null || record.dekWrap == null) {
        _message = 'Tu master password es de una version anterior. '
            'Desbloquea una vez para migrar y vuelve a intentar.';
        return false;
      }

      final unlocker = _biometricUnlockService;
      if (unlocker == null) {
        _message = 'El desbloqueo biometrico no esta conectado '
            'en este dispositivo.';
        return false;
      }

      final session = VaultSession.v2(
        keyId: record.keyId,
        secretKey: await _masterPasswordService.deriveVaultKey(
          record: record,
          password: password,
        ),
        kdf: record.kdf!,
        dekWrap: record.dekWrap!,
      );
      final dekBytes = Uint8List.fromList(await session.secretKey.extractBytes());

      final enrollResult = await _enrollEnvelopeWithDek(
        unlocker: unlocker,
        dekBytes: dekBytes,
      );
      if (!enrollResult.ok) {
        // Surface the *real* reason in the banner so the user can
        // tell us exactly what their device reported. The technical
        // code (e.g. `ensure_key_failed:KEYSTORE_ERROR`) is in
        // brackets; the leading sentence stays user-friendly.
        _message = 'No pudimos preparar la huella en este dispositivo. '
            'Reintenta o usa la master password. '
            '[${enrollResult.reason ?? "unknown"}]';
        return false;
      }

      await _persistBiometricPreference(true);
      _envelopeEnrolled = true;
      _message = 'Listo. La proxima vez podras desbloquear Vaulta con tu huella.';
      // Drop the throwaway session — we are NOT unlocking the vault.
      return true;
    });
  }

  /// Re-confirms the master password of an unlocked vault before a
  /// sensitive action (encrypted backup export). Returns true only when
  /// the vault is unlocked and [password] matches.
  ///
  /// Throttled by the same [UnlockAttemptLimiter] as
  /// [unlockWithPassword]: while [isUnlockLockedOut] is true, or when
  /// the attempt counter cannot be persisted, it returns false without
  /// running the KDF. It never sets [message]; callers render localized
  /// feedback (see `unlockThrottleMessage`).
  Future<bool> reauthenticateWithPassword(String password) async {
    final session = _vaultSession;
    if (!isUnlocked || session == null || isUnlockLockedOut) {
      return false;
    }
    return _runBusy(() async {
      final record = await _readRecord();
      if (record == null || record.keyId != session.keyId) {
        return false;
      }
      final verified = await _verifyThrottled(
        record: record,
        password: password,
        mismatchMessage: '',
      );
      _message = null;
      // The vault may have been locked while the KDF ran.
      return verified && isUnlocked && identical(_vaultSession, session);
    });
  }

  /// Runs the master-password verifier through the attempt limiter
  /// and maps the outcome onto [message]. Returns true on a match.
  ///
  /// Lockout and storage-failure rejections leave [message] null: the
  /// UI renders localized text from [unlockLockoutRemaining] and
  /// [unlockAttemptStateUnavailable] instead.
  Future<bool> _verifyThrottled({
    required MasterPasswordRecord record,
    required String password,
    required String mismatchMessage,
  }) async {
    _unlockAttemptStateUnavailable = false;
    final outcome = await _unlockAttemptLimiter.runAttempt(
      () => _masterPasswordService.verify(record: record, password: password),
    );
    switch (outcome) {
      case UnlockAttemptOutcome.succeeded:
        return true;
      case UnlockAttemptOutcome.failed:
        _message = mismatchMessage;
        return false;
      case UnlockAttemptOutcome.rejected:
        _message = null;
        return false;
      case UnlockAttemptOutcome.storageFailure:
        _unlockAttemptStateUnavailable = true;
        _message = null;
        return false;
    }
  }

  /// Runs the [VaultMigrateEntries] hook against the session that was
  /// just activated. Fails closed: if the upgrade throws, the session
  /// is dropped and the vault stays locked (the stored items are left
  /// intact by the repository, so the next unlock simply retries).
  /// Returns true when the vault may proceed to the unlocked stage.
  Future<bool> _migrateEntriesAfterUnlock() async {
    final migrate = _migrateEntries;
    if (migrate == null) {
      return true;
    }
    try {
      await migrate();
      return true;
    } catch (error) {
      debugPrint(
        '[Vaulta] item payload migration failed: ${error.runtimeType}',
      );
      _vaultSession = null;
      _stage = VaultSecurityStage.locked;
      _message =
          'No pudimos actualizar el cifrado del vault. Tus datos siguen intactos; volve a desbloquear para reintentar.';
      return false;
    }
  }

  Future<Uint8List?> _unwrapCurrentDek(MasterPasswordRecord record) async {
    final session = _vaultSession;
    if (session == null || session.keyId != record.keyId) {
      return null;
    }
    final bytes = await session.secretKey.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<MasterPasswordRecord?> _readRecord() async {
    final raw = await _storage.read(masterPasswordRecordKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    return MasterPasswordRecord.decode(raw);
  }

  Future<bool> _runBusy(Future<bool> Function() action) async {
    _setBusy(true);
    try {
      return await action();
    } finally {
      _setBusy(false);
      notifyListeners();
    }
  }

  void _setBusy(bool value) {
    _busy = value;
  }

  Future<bool?> _readBool({required String key, required bool fallback}) async {
    final rawValue = await _storage.read(key);
    if (rawValue == null) {
      return fallback;
    }

    if (rawValue == 'true') {
      return true;
    }

    if (rawValue == 'false') {
      return false;
    }

    return fallback;
  }

  Future<int?> _readInt({
    required String key,
    required int fallback,
    int? min,
  }) async {
    final rawValue = await _storage.read(key);
    if (rawValue == null) {
      return fallback;
    }

    final parsed = int.tryParse(rawValue);
    if (parsed == null) {
      return fallback;
    }

    if (min != null && parsed < min) {
      return fallback;
    }

    return parsed;
  }

  void _restartIdleTimer() {
    _cancelIdleTimer();

    final timeout = idleTimeout;
    if (timeout == null || !isUnlocked) {
      return;
    }

    _lastInteractionAt = DateTime.now();

    _idleTimer = Timer(timeout, () {
      if (!isUnlocked) {
        return;
      }

      unawaited(
        lock(reason: 'Vaulta bloqueada automaticamente por inactividad.'),
      );
    });
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  String _formatIdleTimeoutLabel(int seconds) {
    if (seconds < 60) {
      return '${seconds}s';
    }

    final minutes = seconds ~/ 60;
    return '$minutes min';
  }

  static Future<void> _unsupportedRekey({
    required VaultSession sourceSession,
    required VaultSession targetSession,
  }) async {
    throw UnsupportedError('Vault rekeying operation is not configured.');
  }
}
