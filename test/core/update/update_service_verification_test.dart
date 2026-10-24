// Verified in-app updates: channel selection, SHA256SUMS lookup and
// the fail-closed download -> verify -> install pipeline, driven
// through a mocked `com.insyd.vaulta/update` MethodChannel.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/secure_storage_service.dart';
import 'package:gestor_contrasenas/core/update/update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _channel = MethodChannel('com.insyd.vaulta/update');
const _apkPath = '/data/user/0/app/files/updates/vaulta.apk';
const _goodSha =
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
const _badSha =
    '0000000000000000000000000000000000000000000000000000000000000000';

Map<Object?, Object?> _args(MethodCall call) => call.arguments as Map;

class _MemoryStorage implements SecureStorageService {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> save(String key, String value) async => values[key] = value;
}

/// Records every native call and answers with configurable values.
class _FakeNative {
  final List<MethodCall> calls = [];
  String? sums = '$_goodSha  vaulta.apk\n';
  String apkSha = _goodSha;
  bool sameSigner = true;
  bool installLaunched = true;
  Map<String, Object?> release = {
    'available': true,
    'tagName': 'v1.1.0',
    'apkUrl': 'https://github.com/o/r/releases/download/v1.1.0/vaulta.apk',
    'checksumsUrl':
        'https://github.com/o/r/releases/download/v1.1.0/SHA256SUMS',
    'assetName': 'vaulta.apk',
    'changelog': 'Version: 1.1.0+23',
    'remoteVersion': '1.1.0+23',
    'releaseId': 42,
    'buildFingerprint': '42:1:t:1',
  };

  List<String> get methods => calls.map((c) => c.method).toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'checkForUpdate':
        return release;
      case 'downloadChecksums':
        return sums;
      case 'downloadApk':
        return _apkPath;
      case 'sha256File':
        return apkSha;
      case 'verifyApkSigner':
        return sameSigner;
      case 'discardDownload':
        return true;
      case 'openInstallPrompt':
        return installLaunched;
    }
    throw MissingPluginException(call.method);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNative native;
  late _MemoryStorage storage;
  late UpdateService service;

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Vaulta',
      packageName: 'com.insyd.gestor_contrasenas',
      version: '1.0.21',
      buildNumber: '22',
      buildSignature: '',
    );
    native = _FakeNative();
    storage = _MemoryStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, native.handle);
    service = UpdateService(
      owner: 'o',
      repo: 'r',
      storage: storage,
      isAndroid: true,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<UpdateInfo> check() => service.checkForUpdate();

  group('release channel selection', () {
    test('defaults to stable and sends it to the native side', () async {
      expect(await service.releaseChannel(), UpdateReleaseChannel.stable);
      final info = await check();
      expect(_args(native.calls.single)['channel'], 'stable');
      expect(info.channel, UpdateReleaseChannel.stable);
      expect(info.checksumsUrl, endsWith('/SHA256SUMS'));
      expect(info.apkAssetName, 'vaulta.apk');
    });

    test('dev opt-in is persisted and used for the next check', () async {
      await service.setReleaseChannel(UpdateReleaseChannel.dev);
      final again = UpdateService(
        owner: 'o',
        repo: 'r',
        storage: storage,
        isAndroid: true,
      );
      expect(await again.releaseChannel(), UpdateReleaseChannel.dev);
      final info = await again.checkForUpdate();
      expect(_args(native.calls.single)['channel'], 'dev');
      expect(info.channel, UpdateReleaseChannel.dev);
    });

    test('a corrupted stored value falls back to stable', () async {
      storage.values['vaulta_update_channel_v1'] = 'nightly';
      expect(await service.releaseChannel(), UpdateReleaseChannel.stable);
    });

    test('without storage the channel is always stable', () async {
      final noStorage = UpdateService(owner: 'o', repo: 'r', isAndroid: true);
      await noStorage.setReleaseChannel(UpdateReleaseChannel.dev);
      expect(await noStorage.releaseChannel(), UpdateReleaseChannel.stable);
    });
  });

  group('checksum verification', () {
    test('matching checksum and signer: downloads, verifies, installs '
        'with the expected digest', () async {
      final info = await check();
      final path = await service.downloadApk(info);
      expect(path, _apkPath);
      expect(await service.openInstallPrompt(path), isTrue);

      expect(native.methods, [
        'checkForUpdate',
        'downloadChecksums',
        'downloadApk',
        'sha256File',
        'verifyApkSigner',
        'openInstallPrompt',
      ]);
      expect(_args(native.calls.last)['expectedSha256'], _goodSha);
    });

    test('accepts uppercase digests and binary-mode (*) entries', () async {
      native.sums =
          '# generated by release.yml\n'
          '${_goodSha.toUpperCase()} *vaulta.apk\r\n'
          '$_badSha  vaulta-windows-bundle.zip\n';
      final info = await check();
      expect(await service.downloadApk(info), _apkPath);
    });

    test(
      'mismatched checksum is refused, discarded, never installed',
      () async {
        native.apkSha = _badSha;
        final info = await check();
        await expectLater(
          service.downloadApk(info),
          throwsA(
            isA<UpdateVerificationException>().having(
              (e) => e.failure,
              'failure',
              UpdateVerificationFailure.checksumMismatch,
            ),
          ),
        );
        expect(native.methods, contains('discardDownload'));
        expect(native.methods, isNot(contains('verifyApkSigner')));
        await expectLater(
          service.openInstallPrompt(_apkPath),
          throwsA(isA<UpdateVerificationException>()),
        );
        expect(native.methods, isNot(contains('openInstallPrompt')));
      },
    );

    test('release without SHA256SUMS is refused before downloading', () async {
      native.release = {...native.release, 'checksumsUrl': ''};
      final info = await check();
      await expectLater(
        service.downloadApk(info),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.failure,
            'failure',
            UpdateVerificationFailure.checksumMissing,
          ),
        ),
      );
      expect(native.methods, ['checkForUpdate']);
    });

    test('SHA256SUMS that does not list the APK is refused', () async {
      native.sums = '$_goodSha  vaulta-windows-bundle.zip\n';
      final info = await check();
      await expectLater(
        service.downloadApk(info),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.failure,
            'failure',
            UpdateVerificationFailure.checksumMissing,
          ),
        ),
      );
      expect(native.methods, isNot(contains('downloadApk')));
    });

    test('empty SHA256SUMS body is refused', () async {
      native.sums = null;
      final info = await check();
      await expectLater(
        service.downloadApk(info),
        throwsA(isA<UpdateVerificationException>()),
      );
      expect(native.methods, isNot(contains('downloadApk')));
    });

    test('signer mismatch is refused, discarded, never installed', () async {
      native.sameSigner = false;
      final info = await check();
      await expectLater(
        service.downloadApk(info),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.failure,
            'failure',
            UpdateVerificationFailure.signatureMismatch,
          ),
        ),
      );
      expect(native.methods, contains('discardDownload'));
      expect(native.methods, isNot(contains('openInstallPrompt')));
    });

    test('openInstallPrompt refuses a path that was never verified', () async {
      await expectLater(
        service.openInstallPrompt(_apkPath),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.failure,
            'failure',
            UpdateVerificationFailure.checksumMissing,
          ),
        ),
      );
      expect(native.calls, isEmpty);
    });
  });

  group('sha256ForAsset', () {
    test('returns the lowercase digest for an exact file name', () {
      expect(sha256ForAsset('$_goodSha  vaulta.apk', 'vaulta.apk'), _goodSha);
    });

    test('does not match a different file with the same suffix', () {
      expect(sha256ForAsset('$_goodSha  evil-vaulta.apk', 'vaulta.apk'), null);
    });

    test('conflicting duplicate entries are refused', () {
      expect(
        sha256ForAsset(
          '$_goodSha  vaulta.apk\n$_badSha  vaulta.apk',
          'vaulta.apk',
        ),
        isNull,
      );
    });

    test('a malformed line for the asset is refused', () {
      expect(sha256ForAsset('abc123  vaulta.apk', 'vaulta.apk'), isNull);
    });
  });
}
