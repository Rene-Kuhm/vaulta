import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../security/secure_storage_service.dart';

/// Release feed the in-app updater follows.
enum UpdateReleaseChannel {
  /// Latest stable GitHub release (`/releases/latest`), cut from a
  /// `vX.Y.Z` tag by `.github/workflows/release.yml`. Default.
  stable,

  /// Rolling `dev-latest` pre-release rebuilt on every push to
  /// master. Opt-in from Settings; still checksum- and
  /// signer-verified like the stable channel.
  dev;

  /// Value sent to the native channel and persisted in storage.
  String get wireName => name;

  /// Parses a persisted [wireName]. Anything unknown falls back to
  /// [stable] so a corrupted value never silently opts the user
  /// into dev builds.
  static UpdateReleaseChannel fromWireName(String? value) {
    return value == dev.wireName ? dev : stable;
  }
}

/// Why a downloaded update was refused before reaching the system
/// installer.
enum UpdateVerificationFailure {
  /// The release has no `SHA256SUMS` asset, or it does not list the
  /// APK. Without a published digest there is nothing to verify
  /// against, so the update is refused (fail closed).
  checksumMissing,

  /// The SHA-256 of the downloaded APK differs from the one listed
  /// in `SHA256SUMS` (corrupted or tampered download).
  checksumMismatch,

  /// The APK is not signed by the same certificate as the installed
  /// app, so Android would either reject it or it is not ours.
  signatureMismatch,
}

/// Thrown by [UpdateService] when a downloaded APK fails integrity
/// or authenticity checks. The UI maps [failure] to a localized
/// message; the APK has already been discarded when this is thrown.
class UpdateVerificationException implements Exception {
  /// Creates an exception for the given verification [failure].
  const UpdateVerificationException(this.failure);

  /// Which check failed.
  final UpdateVerificationFailure failure;

  @override
  String toString() => 'UpdateVerificationException(${failure.name})';
}

/// Information about a release the platform fetched from GitHub.
class UpdateInfo {
  /// Builds a fully populated [UpdateInfo] from a platform response.
  const UpdateInfo({
    required this.available,
    required this.tagName,
    required this.apkUrl,
    required this.changelog,
    required this.publishedAt,
    required this.releaseId,
    required this.currentVersion,
    this.remoteVersion = '',
    this.buildFingerprint = '',
    this.checksumsUrl = '',
    this.apkAssetName = '',
    this.channel = UpdateReleaseChannel.stable,
  });

  /// True when the platform found a release that the running build
  /// is older than.
  final bool available;

  /// Git tag (e.g. `v1.0.22`). Empty when not available.
  final String tagName;

  /// Signed APK URL. Empty when not available.
  final String apkUrl;

  /// Markdown changelog body. Empty when not available.
  final String changelog;

  /// ISO-8601 publish timestamp. Empty when not available.
  final String publishedAt;

  /// GitHub release id. Monotonically increases every time the
  /// `dev-latest` release is overwritten, so it is a reliable way to
  /// tell a brand-new build apart from one the user has already
  /// dismissed the SnackBar for.
  final int releaseId;

  /// Cleaned-up remote version string (e.g. `1.0.22`). Empty when
  /// not available or not parseable from the changelog.
  final String remoteVersion;

  /// The version the user is currently running.
  final String currentVersion;

  /// Build fingerprint (CI build hash). Used to dedupe prompts when
  /// the same build is re-published without a version bump.
  final String buildFingerprint;

  /// Download URL of the release's `SHA256SUMS` asset. Empty when the
  /// release does not publish one, in which case [UpdateService]
  /// refuses to install the APK.
  final String checksumsUrl;

  /// File name of the APK asset (e.g. `vaulta.apk`). This is the name
  /// looked up in `SHA256SUMS`.
  final String apkAssetName;

  /// Channel the release was fetched from.
  final UpdateReleaseChannel channel;

  /// Result the platform returned when no update is available.
  /// We still keep the optional metadata so the UI can explain why
  /// (no release yet, HTTP error, missing .apk asset).
  const UpdateInfo.notAvailable({
    required this.currentVersion,
    this.tagName = '',
    this.apkUrl = '',
    this.changelog = '',
    this.publishedAt = '',
    this.releaseId = 0,
    this.remoteVersion = '',
    this.buildFingerprint = '',
    this.checksumsUrl = '',
    this.apkAssetName = '',
    this.channel = UpdateReleaseChannel.stable,
  }) : available = false;
}

/// Bridge to the native [UpdateChannel] hosted in
/// `com.insyd.gestor_contrasenas.UpdateChannel`.
///
/// The native side does the heavy lifting (HTTP request to the
/// GitHub Releases API, APK download to filesDir, FileProvider
/// intent for the system installer) so this Dart wrapper is just a
/// thin facade that translates the MethodChannel payload into a
/// typed [UpdateInfo] and surfaces a friendlier exception for the
/// settings screen.
///
/// Releases come from `/releases/latest` (stable, default) or the
/// `dev-latest` pre-release when the user opts into
/// [UpdateReleaseChannel.dev]. Either way an APK only reaches the
/// system installer after [downloadApk] has checked its SHA-256
/// against the release's `SHA256SUMS` asset and the native side has
/// confirmed it is signed by the same certificate as the installed
/// app; any failure throws [UpdateVerificationException].
///
/// Update gating happens here, not on the native side: the channel
/// always returns the latest release metadata (when it can),
/// and we compare the returned `releaseId` against the value
/// persisted in [SecureStorageService] the last time the user
/// actually installed a build. If they match, the SnackBar stays
/// quiet — no more "update available" nag every single time the
/// app reopens.
class UpdateService {
  /// Builds an [UpdateService] bound to the GitHub [owner]/[repo]
  /// (e.g. `Rene-Kuhm`/`vaulta`) and an optional
  /// [storage] for install-state persistence plus an optional
  /// [channel] override for tests.
  UpdateService({
    required this.owner,
    required this.repo,
    SecureStorageService? storage,
    MethodChannel? channel,
    @visibleForTesting bool? isAndroid,
  }) : _storage = storage,
       _channel = channel ?? const MethodChannel('com.insyd.vaulta/update'),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  /// Secure storage key for the last releaseId the user installed.
  static const _lastSeenReleaseIdKey = 'vaulta_last_seen_release_id_v1';

  /// Secure storage key for the last build fingerprint the user was
  /// shown a SnackBar for.
  static const _lastSeenBuildFingerprintKey =
      'vaulta_last_seen_update_build_v1';

  /// Secure storage key for the selected [UpdateReleaseChannel].
  static const _releaseChannelKey = 'vaulta_update_channel_v1';

  /// GitHub owner (org or user) hosting the releases.
  final String owner;

  /// GitHub repo name. Together with [owner] it pins the channel.
  final String repo;
  final SecureStorageService? _storage;
  final MethodChannel _channel;
  final bool _isAndroid;

  /// SHA-256 digests of APKs that passed [downloadApk] verification,
  /// keyed by file path. [openInstallPrompt] refuses any path that is
  /// not in here, so the installer can never be launched for an
  /// unverified file.
  final Map<String, String> _verifiedSha256ByPath = {};

  /// Returns the release channel the user selected. Defaults to
  /// [UpdateReleaseChannel.stable] when nothing (or garbage) is
  /// stored, or when no storage is wired.
  Future<UpdateReleaseChannel> releaseChannel() async {
    final storage = _storage;
    if (storage == null) return UpdateReleaseChannel.stable;
    return UpdateReleaseChannel.fromWireName(
      await storage.read(_releaseChannelKey),
    );
  }

  /// Persists the release [channel] used by [checkForUpdate].
  Future<void> setReleaseChannel(UpdateReleaseChannel channel) async {
    final storage = _storage;
    if (storage == null) return;
    await storage.save(_releaseChannelKey, channel.wireName);
  }

  /// Returns the release id we last persisted as "installed by the
  /// user", or 0 if we have never recorded one. Exposed for the
  /// Settings screen so it can show the user *which* build they
  /// are currently running against.
  Future<int> lastSeenReleaseId() async {
    final storage = _storage;
    if (storage == null) return 0;
    final raw = await storage.read(_lastSeenReleaseIdKey);
    if (raw == null || raw.isEmpty) return 0;
    return int.tryParse(raw) ?? 0;
  }

  /// Persists the latest `releaseId` for diagnostics. We don't use
  /// this as an install signal because opening Android's installer
  /// does not guarantee the user accepted or that Android installed
  /// the APK.
  Future<void> markInstalled(int releaseId) async {
    final storage = _storage;
    if (storage == null) return;
    if (releaseId <= 0) return;
    await storage.save(_lastSeenReleaseIdKey, releaseId.toString());
  }

  /// Returns the last build fingerprint the user was prompted for,
  /// or empty string if we have never prompted them. Used by
  /// [AppShell] to decide whether to re-show the SnackBar after a
  /// session restart.
  Future<String> lastSeenBuildFingerprint() async {
    final storage = _storage;
    if (storage == null) return '';
    return await storage.read(_lastSeenBuildFingerprintKey) ?? '';
  }

  /// Records [info.buildFingerprint] as "already prompted" so the
  /// next [checkForUpdate] call does not re-show the SnackBar for
  /// the same build. Only called when the fingerprint is non-empty
  /// to avoid polluting the storage with empty placeholders.
  Future<void> markBuildPrompted(UpdateInfo info) async {
    final storage = _storage;
    if (storage == null) return;
    final fingerprint = info.buildFingerprint;
    if (fingerprint.isNotEmpty) {
      await storage.save(_lastSeenBuildFingerprintKey, fingerprint);
    }
  }

  /// Reads the running app's version (CFBundleShortVersionString on
  /// iOS, versionName on Android). Wrapped in a try/catch so the
  /// settings screen can render a fallback label if the platform
  /// channel is unavailable.
  Future<String> currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (error, stack) {
      debugPrint('[Vaulta/Update] PackageInfo failed: $error\n$stack');
      return 'unknown';
    }
  }

  /// Asks the platform to query the GitHub Releases API for the
  /// selected [releaseChannel] and returns a structured [UpdateInfo].
  ///
  /// If the platform reports an `available` release but the
  /// `releaseId` matches the one we already showed the user, we
  /// flip `available` back to false — the silent check fires on
  /// every dashboard open, and we never want a stale SnackBar.
  Future<UpdateInfo> checkForUpdate() async {
    final current = await currentVersion();
    if (!_isAndroid) {
      // OTA updates are only wired for Android in this build.
      return UpdateInfo.notAvailable(currentVersion: current);
    }
    final releaseChannel = await this.releaseChannel();
    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('checkForUpdate', {
            'owner': owner,
            'repo': repo,
            'currentVersion': current,
            'channel': releaseChannel.wireName,
          });
      if (raw == null) {
        return UpdateInfo.notAvailable(currentVersion: current);
      }
      final available = raw['available'] == true;
      final releaseId = (raw['releaseId'] as num?)?.toInt() ?? 0;
      final changelog = (raw['changelog'] as String?) ?? '';
      final remoteVersion =
          ((raw['remoteVersion'] as String?) ?? '').trim().isNotEmpty
          ? ((raw['remoteVersion'] as String?) ?? '').trim()
          : _remoteVersionFromChangelog(changelog);
      if (!available) {
        return UpdateInfo.notAvailable(
          currentVersion: current,
          tagName: (raw['tagName'] as String?) ?? '',
          publishedAt: (raw['publishedAt'] as String?) ?? '',
          releaseId: releaseId,
          remoteVersion: remoteVersion,
          channel: releaseChannel,
        );
      }
      final buildFingerprint = (raw['buildFingerprint'] as String?) ?? '';
      final checksumsUrl = (raw['checksumsUrl'] as String?) ?? '';
      final apkAssetName = (raw['assetName'] as String?) ?? '';
      if (remoteVersion.isNotEmpty &&
          !_isRemoteVersionNewer(remoteVersion, current)) {
        return UpdateInfo(
          available: false,
          tagName: (raw['tagName'] as String?) ?? '',
          apkUrl: (raw['apkUrl'] as String?) ?? '',
          changelog: changelog,
          publishedAt: (raw['publishedAt'] as String?) ?? '',
          releaseId: releaseId,
          remoteVersion: remoteVersion,
          currentVersion: current,
          buildFingerprint: buildFingerprint,
          checksumsUrl: checksumsUrl,
          apkAssetName: apkAssetName,
          channel: releaseChannel,
        );
      }
      return UpdateInfo(
        available: true,
        tagName: (raw['tagName'] as String?) ?? '',
        apkUrl: (raw['apkUrl'] as String?) ?? '',
        changelog: changelog,
        publishedAt: (raw['publishedAt'] as String?) ?? '',
        releaseId: releaseId,
        remoteVersion: remoteVersion,
        currentVersion: current,
        buildFingerprint: buildFingerprint,
        checksumsUrl: checksumsUrl,
        apkAssetName: apkAssetName,
        channel: releaseChannel,
      );
    } on PlatformException catch (error, stack) {
      debugPrint(
        '[Vaulta/Update] check failed: ${error.code} '
        '${error.message}\n$stack',
      );
      throw StateError(
        'No pudimos comprobar actualizaciones '
        '(${error.code}: ${error.message ?? 'sin detalle'}).',
      );
    }
  }

  String _remoteVersionFromChangelog(String changelog) {
    return remoteVersionFromChangelogForTest(changelog);
  }

  bool _isRemoteVersionNewer(String remote, String current) {
    return isRemoteVersionNewerForTest(remote, current);
  }

  /// Downloads and verifies the APK, returning the absolute path of
  /// the cached file in the app's private files directory.
  ///
  /// Order matters and every step fails closed:
  /// 1. fetch `SHA256SUMS` and find the digest for
  ///    [UpdateInfo.apkAssetName] (missing: refuse before
  ///    downloading anything large);
  /// 2. download the APK;
  /// 3. compare its SHA-256 with the published digest;
  /// 4. ask the native side to compare the APK signing certificate
  ///    with the installed app's.
  ///
  /// On any failure the downloaded file is discarded and an
  /// [UpdateVerificationException] is thrown.
  Future<String> downloadApk(UpdateInfo info) async {
    if (!_isAndroid) {
      throw UnsupportedError('OTA updates are only wired for Android.');
    }
    if (info.checksumsUrl.isEmpty || info.apkAssetName.isEmpty) {
      throw const UpdateVerificationException(
        UpdateVerificationFailure.checksumMissing,
      );
    }
    final sums = await _channel.invokeMethod<String>('downloadChecksums', {
      'url': info.checksumsUrl,
    });
    final expected = sha256ForAsset(sums ?? '', info.apkAssetName);
    if (expected == null) {
      throw const UpdateVerificationException(
        UpdateVerificationFailure.checksumMissing,
      );
    }
    final path = await _channel.invokeMethod<String>('downloadApk', {
      'apkUrl': info.apkUrl,
    });
    if (path == null || path.isEmpty) {
      throw StateError('Downloaded APK path was empty.');
    }
    final actual = await _channel.invokeMethod<String>('sha256File', {
      'filePath': path,
    });
    if (actual == null || actual.toLowerCase() != expected) {
      await _discard(path);
      throw const UpdateVerificationException(
        UpdateVerificationFailure.checksumMismatch,
      );
    }
    final sameSigner = await _channel.invokeMethod<bool>('verifyApkSigner', {
      'filePath': path,
    });
    if (sameSigner != true) {
      await _discard(path);
      throw const UpdateVerificationException(
        UpdateVerificationFailure.signatureMismatch,
      );
    }
    _verifiedSha256ByPath[path] = expected;
    return path;
  }

  Future<void> _discard(String path) async {
    _verifiedSha256ByPath.remove(path);
    try {
      await _channel.invokeMethod<void>('discardDownload', {'filePath': path});
    } on PlatformException catch (error) {
      debugPrint('[Vaulta/Update] discard failed: ${error.code}');
    }
  }

  /// Fires ACTION_VIEW on the system installer for an APK previously
  /// returned by [downloadApk]. Returns true if the installer
  /// activity was launched.
  ///
  /// Throws [UpdateVerificationException] for a path that did not go
  /// through [downloadApk] verification. The expected digest is also
  /// sent to the native side, which re-hashes the file and re-checks
  /// the signer right before launching the installer.
  Future<bool> openInstallPrompt(String filePath) async {
    if (!_isAndroid) {
      throw UnsupportedError('OTA updates are only wired for Android.');
    }
    final expected = _verifiedSha256ByPath[filePath];
    if (expected == null) {
      throw const UpdateVerificationException(
        UpdateVerificationFailure.checksumMissing,
      );
    }
    final ok = await _channel.invokeMethod<bool>('openInstallPrompt', {
      'filePath': filePath,
      'expectedSha256': expected,
    });
    return ok ?? false;
  }
}

/// Returns the lowercase SHA-256 listed for [fileName] in a
/// `sha256sum`-format [sums] file (`<64 hex>  <name>` or
/// `<64 hex> *<name>` per line), or null when the file is not listed,
/// a line for it is malformed, or it is listed twice with different
/// digests. Null always means "refuse the update".
String? sha256ForAsset(String sums, String fileName) {
  final line = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$');
  String? found;
  for (final raw in sums.split('\n')) {
    final entry = raw.trimRight();
    if (entry.isEmpty || entry.startsWith('#')) continue;
    final match = line.firstMatch(entry);
    if (match == null) {
      if (entry.endsWith(fileName)) return null;
      continue;
    }
    if (match.group(2) != fileName) continue;
    final digest = match.group(1)!.toLowerCase();
    if (found != null && found != digest) return null;
    found = digest;
  }
  return found;
}

/// Extracts a version string (e.g. `1.0.22`) from a changelog body.
/// Looks for either a `Vaulta version:` or a generic `Version:`
/// line. Test-only because production code goes through the native
/// channel which already returns the version.
@visibleForTesting
String remoteVersionFromChangelogForTest(String changelog) {
  final match = RegExp(
    r'(?:Vaulta\s+version|Version):\s*([0-9A-Za-z.+-]+)',
    caseSensitive: false,
  ).firstMatch(changelog);
  return match?.group(1)?.trim() ?? '';
}

/// Returns true when [remote] is a newer semver than [current],
/// using a simple major.minor.patch+buildNumber compare. Test-only.
@visibleForTesting
bool isRemoteVersionNewerForTest(String remote, String current) {
  final remoteParts = parseVersionForTest(remote);
  final currentParts = parseVersionForTest(current);
  if (remoteParts == null || currentParts == null) {
    return remote != current;
  }
  for (var i = 0; i < 3; i++) {
    final diff = remoteParts.nameParts[i] - currentParts.nameParts[i];
    if (diff != 0) return diff > 0;
  }
  return remoteParts.buildNumber > currentParts.buildNumber;
}

/// Parses `name+buildNumber` into a structure that the version
/// comparator can walk. Test-only.
@visibleForTesting
({List<int> nameParts, int buildNumber})? parseVersionForTest(String value) {
  final pieces = value.trim().split('+');
  if (pieces.isEmpty) return null;
  final nameParts = pieces.first.split('.').map(int.tryParse).toList();
  if (nameParts.length != 3 || nameParts.any((part) => part == null)) {
    return null;
  }
  final buildNumber = pieces.length > 1 ? int.tryParse(pieces[1]) : 0;
  if (buildNumber == null) return null;
  return (nameParts: nameParts.cast<int>(), buildNumber: buildNumber);
}
