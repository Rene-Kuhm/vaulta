import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/sensitive_clipboard_service.dart';
import 'package:gestor_contrasenas/features/totp/presentation/totp_code_panel.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

/// RFC 6238 Appendix B seed "12345678901234567890", base32-encoded, so
/// every expectation below traces back to a published vector.
const _secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
const _sixDigitUri =
    'otpauth://totp/GitHub:leo@example.com?secret=$_secret&issuer=GitHub';
const _eightDigitUri =
    'otpauth://totp/ACME%20Co%3Ajohn.doe%40email.com?secret=$_secret'
    '&issuer=ACME%20Co&digits=8';

void main() {
  // T=59 s is the RFC 6238 vector: eight digits 94287082, six digits
  // 287082.
  final pinnedAt = DateTime.fromMillisecondsSinceEpoch(59000, isUtc: true);

  Future<void> pumpPanel(
    WidgetTester tester, {
    required String uri,
    SensitiveClipboardService? clipboardService,
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TotpCodePanel(
            uri: uri,
            clipboardService: clipboardService,
            clock: clock ?? () => pinnedAt,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows the issuer, the grouped six-digit code and the '
      'seconds remaining', (tester) async {
    await pumpPanel(tester, uri: _sixDigitUri);

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('leo@example.com'), findsOneWidget);
    expect(find.text('287 082'), findsOneWidget);
    // T=59 s is 29 seconds into the time step, so one second is left.
    expect(find.text('1s remaining'), findsOneWidget);
  });

  testWidgets('groups an eight-digit code as two blocks of four', (
    tester,
  ) async {
    await pumpPanel(tester, uri: _eightDigitUri);

    expect(find.text('ACME Co'), findsOneWidget);
    expect(find.text('john.doe@email.com'), findsOneWidget);
    // T=59 s falls in the second 30 s window, so the counter step is 1.
    expect(find.text('9428 7082'), findsOneWidget);
  });

  testWidgets('counts down as the clock advances', (tester) async {
    var now = pinnedAt;
    await pumpPanel(tester, uri: _sixDigitUri, clock: () => now);

    expect(find.text('1s remaining'), findsOneWidget);
    expect(find.text('287 082'), findsOneWidget);

    // One second later a new time step starts: the code rotates and
    // the countdown restarts at the full period.
    now = pinnedAt.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('30s remaining'), findsOneWidget);
    expect(find.text('287 082'), findsNothing);
    expect(find.text('359 152'), findsOneWidget);

    now = pinnedAt.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('25s remaining'), findsOneWidget);
  });

  testWidgets('copies the bare digits through the sensitive clipboard', (
    tester,
  ) async {
    final service = _RecordingClipboardService();
    await pumpPanel(tester, uri: _sixDigitUri, clipboardService: service);

    await tester.tap(find.text('Copy code'));
    await tester.pump();

    expect(service.copies, ['287082']);
  });

  testWidgets('reports an unreadable secret instead of showing a code', (
    tester,
  ) async {
    await pumpPanel(tester, uri: 'otpauth://hotp/alice?secret=$_secret');

    expect(
      find.text("This entry's one-time code could not be read."),
      findsOneWidget,
    );
    expect(find.text('Copy code'), findsNothing);
    expect(find.textContaining(RegExp(r'^\d')), findsNothing);
  });

  testWidgets('renders the panel inside the app theme without errors', (
    tester,
  ) async {
    await pumpPanel(tester, uri: _sixDigitUri);

    expect(tester.takeException(), isNull);
    expect(find.byType(TotpCodePanel), findsOneWidget);
  });
}

class _RecordingClipboardService extends SensitiveClipboardService {
  _RecordingClipboardService() : super(isAndroid: false);

  final List<String> copies = [];

  @override
  Future<void> copySensitive(String text, {VoidCallback? onAutoCleared}) async {
    copies.add(text);
  }
}
