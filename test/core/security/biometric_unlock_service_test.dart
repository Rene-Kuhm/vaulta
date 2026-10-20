// Coverage for the biometric unlock orchestration.
//
// These tests run on the host. `BiometricUnlockService` takes an
// `isMobileTarget` seam (defaulting to `Platform.isAndroid ||
// Platform.isIOS`) so the real orchestration runs on Linux with a fake
// envelope-key provider standing in for the KeyStore. The contract under
// test is the security-critical one: a session may only ever come from
// the biometric envelope, never from the master-password path.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'package:gestor_contrasenas/core/security/biometric_auth_service.dart';
import 'package:gestor_contrasenas/core/security/biometric_key_envelope_service.dart';
import 'package:gestor_contrasenas/core/security/biometric_unlock_service.dart';
import 'package:gestor_contrasenas/core/security/master_password_record.dart';
import 'package:gestor_contrasenas/core/security/master_password_service.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';

/// Storage key the wrapped-DEK envelope lives under.
const _envelopeStorageKey = BiometricKeyEnvelopeService.envelopeStorageKey;

/// Master password used to build a real v3 record.
const _password = 'StrongPass!2026';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _InMemoryStorage storage;
  late BiometricKeyEnvelopeService envelopeService;
  late _AlwaysCapableAuthService auth;
  late MasterPasswordService passwords;
  late MasterPasswordRecord record;
  late Uint8List recordDek;

  setUp(() async {
    storage = _InMemoryStorage();
    envelopeService = BiometricKeyEnvelopeService(storage: storage);
    auth = _AlwaysCapableAuthService();
    passwords = MasterPasswordService.test();
    record = await passwords.createRecord(_password);
    recordDek = Uint8List.fromList(
      await (await passwords.deriveVaultKey(
        record: record,
        password: _password,
      )).extractBytes(),
    );
  });

  /// Enrolls the real record DEK into the biometric envelope under
  /// [envelopeKey], so a successful unlock must recover exactly this DEK.
  Future<void> enrollRecordDek(SecretKey envelopeKey) {
    return envelopeService.enroll(
      dekBytes: Uint8List.fromList(recordDek),
      envelopeKey: envelopeKey,
    );
  }

  BiometricUnlockService buildService(
    _StubEnvelopeKeyProvider provider, {
    BiometricAuthService? authService,
    bool mobileTarget = true,
  }) {
    return BiometricUnlockService(
      storage: storage,
      biometricAuthService: authService ?? auth,
      envelopeService: envelopeService,
      envelopeKeyProvider: provider,
      isMobileTarget: mobileTarget,
    );
  }

  group('BiometricUnlockService capability gate', () {
    test('a legacy v1 record asks for the password without prompting', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);
      final legacy = MasterPasswordRecord(
        version: 1,
        verifierIterations: 1,
        verifierSalt: 'c2FsdA==',
        verifier: 'dmVyaWZpZXI=',
        encryptionIterations: 1,
        encryptionSalt: 'c2FsdA==',
        keyId: 'legacy',
        createdAt: DateTime.utc(2026),
      );

      final outcome = await buildService(provider).unlock(record: legacy);

      expect(outcome, isA<BiometricUnlockUnavailable>());
      expect(provider.releaseCalls, 0);
    });

    test('a non-mobile target reports unavailable without prompting', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);

      final outcome = await buildService(
        provider,
        mobileTarget: false,
      ).unlock(record: record);

      expect(outcome, isA<BiometricUnlockUnavailable>());
      expect(
        (outcome as BiometricUnlockUnavailable).reason,
        contains('biometria'),
      );
      expect(provider.releaseCalls, 0);
      expect(auth.authenticateCalls, 0);
    });

    test('an unenrolled biometric reports the enrollment hint', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);

      final outcome = await buildService(
        provider,
        authService: _AlwaysCapableAuthService(enrolled: false),
      ).unlock(record: record);

      expect(outcome, isA<BiometricUnlockUnavailable>());
      expect(
        (outcome as BiometricUnlockUnavailable).reason,
        contains('No hay biometria registrada'),
      );
      expect(auth.authenticateCalls, 0);
      expect(provider.releaseCalls, 0);
    });

    test('no envelope on disk asks for one password unlock first', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();

      final outcome = await buildService(provider).unlock(record: record);

      expect(outcome, isA<BiometricUnlockNeedsPasswordFirst>());
      expect(
        (outcome as BiometricUnlockNeedsPasswordFirst).reason,
        contains('master password'),
      );
      expect(auth.authenticateCalls, 0);
      expect(provider.releaseCalls, 0);
    });

    test('canAttemptUnlock needs capability, enrollment and an envelope', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      final service = buildService(provider);

      expect(await service.canAttemptUnlock(), isFalse);

      await enrollRecordDek(provider.envelopeKey);
      expect(await service.canAttemptUnlock(), isTrue);

      expect(
        await buildService(provider, mobileTarget: false).canAttemptUnlock(),
        isFalse,
      );
      expect(
        await buildService(
          provider,
          authService: _AlwaysCapableAuthService(enrolled: false),
        ).canAttemptUnlock(),
        isFalse,
      );
    });
  });

  group('BiometricUnlockService session source', () {
    test('the recovered session is the DEK from the envelope', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);

      final outcome = await buildService(provider).unlock(record: record);

      expect(outcome, isA<BiometricUnlockSuccess>());
      final session = (outcome as BiometricUnlockSuccess).session;
      // No password was ever passed to unlock(), so this DEK can only
      // have come out of the envelope.
      expect(await session.secretKey.extractBytes(), recordDek);
      expect(session.keyId, record.keyId);
      expect(session.isV2, isTrue);
      expect(session.kdf, record.kdf);
      expect(session.dekWrap, record.dekWrap);
      expect(provider.releaseCalls, 1);
      expect(auth.authenticateCalls, 1);
    });

    test('the session DEK comes from the envelope, not from the record', () async {
      // The envelope deliberately holds a DEK that is *not* the one the
      // master-password record wraps. If the unlock path ever fell back
      // to the record, the session would come back with [recordDek]
      // instead of the envelope's bytes.
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      final envelopeDek = Uint8List.fromList(
        List<int>.generate(32, (i) => 0xA0 + i),
      );
      expect(envelopeDek, isNot(equals(recordDek)));
      await envelopeService.enroll(
        dekBytes: envelopeDek,
        envelopeKey: provider.envelopeKey,
      );

      final outcome = await buildService(provider).unlock(record: record);

      final session = (outcome as BiometricUnlockSuccess).session;
      expect(await session.secretKey.extractBytes(), envelopeDek);
      expect(await session.secretKey.extractBytes(), isNot(recordDek));
    });

    test('a rejected prompt never yields a session', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);

      final outcome = await buildService(
        provider,
        authService: _RejectingAuthService(),
      ).unlock(record: record);

      expect(outcome, isA<BiometricUnlockRejected>());
      expect(outcome, isNot(isA<BiometricUnlockSuccess>()));
      expect(provider.releaseCalls, 0, reason: 'no prompt, no key release');
    });

    test('an envelope key that cannot be released never yields a session', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);
      provider.releaseResult = const BiometricEnvelopeKeyResult.unavailable(
        'rsa_decrypt_returned_null',
      );

      final outcome = await buildService(provider).unlock(record: record);

      expect(outcome, isA<BiometricUnlockRejected>());
      expect(outcome, isNot(isA<BiometricUnlockSuccess>()));
      expect(
        (outcome as BiometricUnlockRejected).reason,
        contains('rsa_decrypt_returned_null'),
      );
      // The envelope is left intact so the next attempt can still work.
      expect(await envelopeService.isEnrolled(), isTrue);
    });

    test('a wrong envelope key is rejected, not swapped for a password key', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);
      // Same flow, but the platform hands back a different seed.
      provider.releaseResult = BiometricEnvelopeKeyResult.success(
        SecretKey(List<int>.generate(32, (i) => 0xC0 + i)),
      );

      final outcome = await buildService(provider).unlock(record: record);

      expect(outcome, isA<BiometricUnlockRejected>());
      expect(outcome, isNot(isA<BiometricUnlockSuccess>()));
      expect(
        (outcome as BiometricUnlockRejected).reason,
        contains('clave inconsistente'),
      );
      expect(await envelopeService.isEnrolled(), isTrue);
    });

    test('a release failure does not destroy the enrolled envelope', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);
      provider.releaseResult = const BiometricEnvelopeKeyResult.unavailable(
        'ensure_key_failed:KEYSTORE',
      );
      final before = await storage.read(_envelopeStorageKey);

      await buildService(provider).unlock(record: record);

      expect(await storage.read(_envelopeStorageKey), before);
      expect(provider.deleteKeyCalls, 0);
    });
  });

  group('BiometricUnlockService.invalidate', () {
    test('wipes the envelope, the platform key and the slot reference', () async {
      final provider = _StubEnvelopeKeyProvider.fixedSeed();
      await enrollRecordDek(provider.envelopeKey);
      await storage.save(BiometricUnlockService.envelopeKeySlotKey, 'alias');
      final service = buildService(provider);

      await service.invalidate();

      expect(await envelopeService.isEnrolled(), isFalse);
      expect(await storage.read(_envelopeStorageKey), isNull);
      expect(
        await storage.read(BiometricUnlockService.envelopeKeySlotKey),
        isNull,
      );
      expect(provider.deleteKeyCalls, 1);
      expect(await service.canAttemptUnlock(), isFalse);
    });
  });
}

/// Stands in for the Android KeyStore provider. Hands out a fixed
/// envelope key on enrollment and releases the same key at unlock, and
/// records how often each half was asked for it.
class _StubEnvelopeKeyProvider
    implements BiometricEnvelopeKeyProvider, BiometricEnvelopeKeyInvalidator {
  _StubEnvelopeKeyProvider.fixedSeed()
    : envelopeKey = SecretKey(List<int>.generate(32, (i) => i + 1));

  final SecretKey envelopeKey;

  /// Overrides what [releaseEnvelopeKey] answers.
  BiometricEnvelopeKeyResult? releaseResult;

  /// How many times the unlock half was invoked.
  int releaseCalls = 0;

  /// How many times the platform key was wiped.
  int deleteKeyCalls = 0;

  @override
  Future<BiometricEnvelopeKeyResult> acquireEnvelopeKey() async {
    return BiometricEnvelopeKeyResult.success(envelopeKey);
  }

  @override
  Future<BiometricEnvelopeKeyResult> releaseEnvelopeKey() async {
    releaseCalls++;
    return releaseResult ?? BiometricEnvelopeKeyResult.success(envelopeKey);
  }

  @override
  Future<void> deleteKey() async {
    deleteKeyCalls++;
  }
}

/// Biometric gate that reports capability and enrollment, and counts the
/// prompts it was asked to open.
class _AlwaysCapableAuthService implements BiometricAuthService {
  _AlwaysCapableAuthService({this.enrolled = true});

  /// Whether the platform reports an enrolled biometric factor.
  final bool enrolled;

  /// How many unlock prompts this gate was asked to open.
  int authenticateCalls = 0;

  @override
  Future<bool> authenticateForUnlock() async {
    authenticateCalls++;
    return true;
  }

  @override
  Future<BiometricAvailability> getAvailability() async {
    return BiometricAvailability(
      deviceSupported: true,
      canCheckBiometrics: true,
      availableBiometrics:
          enrolled ? const [BiometricType.fingerprint] : const [],
    );
  }
}

/// Biometric gate that always reports a refused prompt.
class _RejectingAuthService extends _AlwaysCapableAuthService {
  @override
  Future<bool> authenticateForUnlock() async {
    authenticateCalls++;
    return false;
  }
}

/// In-memory [SecureStorageService].
class _InMemoryStorage implements SecureStorageService {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> save(String key, String value) async {
    _values[key] = value;
  }
}