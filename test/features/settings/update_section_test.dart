// ignore_for_file: prefer_const_constructors

// Widget test that exercises the UpdateSection "Check for updates"
// button end-to-end. Verifies the button changes the visible state
// (spinner, success banner, or error banner) so a "silent no-op" can
// never reach a real device again.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/update/update_service.dart';
import 'package:gestor_contrasenas/features/settings/presentation/update_section.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  testWidgets('Check for updates button enters checking state immediately '
      'after tap, then resolves to updateAvailable when the service '
      'returns available=true', (tester) async {
    final pending = Completer<UpdateInfo>();
    final service = _StubUpdateService(checkResult: pending.future);

    await tester.pumpWidget(
      _testApp(SingleChildScrollView(child: UpdateSection(service: service))),
    );

    // Initial state: the button label must be exactly the action we
    // expect, never null or a spinner.
    expect(find.text('Check for updates'), findsOneWidget);

    // Tap. The synchronous setState must flip us into checking
    // *before* the async gap closes, so the spinner must appear
    // in the same frame the tap is dispatched.
    await tester.tap(find.text('Check for updates'));
    await tester.pump();

    // While the future is pending, the button should be a busy
    // button with a CircularProgressIndicator and no tap handler.
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('Checking...'), findsOneWidget);
    expect(service.checkForUpdateCallCount, 1);

    // Now resolve the future and drain the second setState.
    pending.complete(
      UpdateInfo(
        available: true,
        tagName: 'dev-latest',
        apkUrl: 'https://example.com/app-release.apk',
        changelog: 'test changelog',
        publishedAt: '2026-06-09T18:00:00Z',
        releaseId: 12345,
        currentVersion: '1.0.4+5',
        buildFingerprint: '12345:99:2026-06-09T18:00:00Z:123456',
      ),
    );
    await tester.pumpAndSettle();

    // After resolving with available=true we must show the
    // changelog panel, not silently fall back to up-to-date.
    expect(find.text('New version dev-latest'), findsOneWidget);
    expect(find.text('test changelog'), findsOneWidget);
  });

  testWidgets('button resolves to upToDate banner when service returns '
      'available=false', (tester) async {
    final service = _StubUpdateService(
      checkResult: Future.value(
        UpdateInfo.notAvailable(currentVersion: '1.0.4+5'),
      ),
    );

    await tester.pumpWidget(
      _testApp(SingleChildScrollView(child: UpdateSection(service: service))),
    );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    // The "up to date" banner is the only way a no-op button
    // tap becomes a clear, non-misleading signal.
    expect(find.textContaining('Up to date'), findsOneWidget);
  });

  testWidgets('button resolves to error banner when the service throws', (
    tester,
  ) async {
    final service = _ThrowingUpdateService(
      error: StateError('native channel not registered'),
    );

    await tester.pumpWidget(
      _testApp(SingleChildScrollView(child: UpdateSection(service: service))),
    );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('We could not check for updates'), findsOneWidget);
    expect(
      find.textContaining('native channel not registered'),
      findsOneWidget,
    );
  });

  testWidgets(
    'download flow does not mark build prompted when installer fails to open',
    (tester) async {
      final service = _StubUpdateService(
        checkResult: Future.value(
          const UpdateInfo(
            available: true,
            tagName: 'dev-latest',
            apkUrl: 'https://example.com/app-release.apk',
            changelog: 'test changelog',
            publishedAt: '2026-06-09T18:00:00Z',
            releaseId: 12345,
            currentVersion: '1.0.4+5',
            buildFingerprint: '12345:99:2026-06-09T18:00:00Z:123456',
          ),
        ),
        installPromptResult: false,
      );

      await tester.pumpWidget(
        _testApp(SingleChildScrollView(child: UpdateSection(service: service))),
      );

      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download and install'));
      await tester.pumpAndSettle();

      expect(service.downloadCallCount, 1);
      expect(service.openInstallPromptCallCount, 1);
      expect(service.markBuildPromptedCallCount, 0);
      expect(
        find.textContaining('could not open the system installer'),
        findsOneWidget,
      );
    },
  );

  for (final (failure, expected) in [
    (
      UpdateVerificationFailure.checksumMissing,
      'does not publish a SHA-256 checksum',
    ),
    (
      UpdateVerificationFailure.checksumMismatch,
      'does not match the published SHA-256 checksum',
    ),
    (
      UpdateVerificationFailure.signatureMismatch,
      'not signed with the same certificate',
    ),
  ]) {
    testWidgets('verification failure ${failure.name} shows a localized '
        'refusal and never opens the installer', (tester) async {
      final service = _StubUpdateService(
        checkResult: Future.value(
          const UpdateInfo(
            available: true,
            tagName: 'v1.1.0',
            apkUrl: 'https://example.com/vaulta.apk',
            changelog: 'notes',
            publishedAt: '2026-10-19T00:00:00Z',
            releaseId: 7,
            currentVersion: '1.0.4+5',
          ),
        ),
        downloadError: UpdateVerificationException(failure),
      );

      await tester.pumpWidget(
        _testApp(SingleChildScrollView(child: UpdateSection(service: service))),
      );
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download and install'));
      await tester.pumpAndSettle();

      expect(find.textContaining(expected), findsOneWidget);
      expect(service.openInstallPromptCallCount, 0);
      expect(service.markBuildPromptedCallCount, 0);
    });
  }

  testWidgets('dev channel switch defaults to off and persists the choice', (
    tester,
  ) async {
    final service = _StubUpdateService(
      checkResult: Future.value(
        UpdateInfo.notAvailable(currentVersion: '1.0.4+5'),
      ),
    );

    await tester.pumpWidget(
      _testApp(SingleChildScrollView(child: UpdateSection(service: service))),
    );
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(SwitchListTile, 'Dev channel');
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(service.channel, UpdateReleaseChannel.dev);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
  });
}

Widget _testApp(Widget body) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(body: body),
  );
}

class _StubUpdateService implements UpdateService {
  _StubUpdateService({
    required this.checkResult,
    this.installPromptResult = true,
    this.downloadError,
  });

  final Future<UpdateInfo> checkResult;
  final bool installPromptResult;
  final Object? downloadError;
  UpdateReleaseChannel channel = UpdateReleaseChannel.stable;
  int checkForUpdateCallCount = 0;
  int downloadCallCount = 0;
  int openInstallPromptCallCount = 0;
  int markBuildPromptedCallCount = 0;

  @override
  String get owner => 'Rene-Kuhm';

  @override
  String get repo => 'vaulta';

  @override
  Future<UpdateInfo> checkForUpdate() async {
    checkForUpdateCallCount++;
    return checkResult;
  }

  @override
  Future<String> currentVersion() async => '1.0.4+5';

  @override
  Future<String> downloadApk(UpdateInfo info) async {
    downloadCallCount++;
    final error = downloadError;
    if (error != null) throw error;
    return '/tmp/app-release.apk';
  }

  @override
  Future<UpdateReleaseChannel> releaseChannel() async => channel;

  @override
  Future<void> setReleaseChannel(UpdateReleaseChannel value) async {
    channel = value;
  }

  @override
  Future<String> lastSeenBuildFingerprint() async => '';

  @override
  Future<int> lastSeenReleaseId() async => 0;

  @override
  Future<void> markInstalled(int releaseId) async {}

  @override
  Future<void> markBuildPrompted(UpdateInfo info) async {
    markBuildPromptedCallCount++;
  }

  @override
  Future<bool> openInstallPrompt(String filePath) async {
    openInstallPromptCallCount++;
    return installPromptResult;
  }
}

class _ThrowingUpdateService implements UpdateService {
  _ThrowingUpdateService({required this.error});

  final Object error;

  @override
  String get owner => 'Rene-Kuhm';

  @override
  String get repo => 'vaulta';

  @override
  Future<UpdateInfo> checkForUpdate() async {
    throw error;
  }

  @override
  Future<String> currentVersion() async => '1.0.4+5';

  @override
  Future<String> downloadApk(UpdateInfo info) async => '/tmp/app-release.apk';

  @override
  Future<UpdateReleaseChannel> releaseChannel() async =>
      UpdateReleaseChannel.stable;

  @override
  Future<void> setReleaseChannel(UpdateReleaseChannel channel) async {}

  @override
  Future<String> lastSeenBuildFingerprint() async => '';

  @override
  Future<int> lastSeenReleaseId() async => 0;

  @override
  Future<void> markInstalled(int releaseId) async {}

  @override
  Future<void> markBuildPrompted(UpdateInfo info) async {}

  @override
  Future<bool> openInstallPrompt(String filePath) async => true;
}
