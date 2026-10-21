import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/sensitive_clipboard_service.dart';
import 'package:gestor_contrasenas/features/totp/presentation/totp_code_panel.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_detail_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

/// RFC 6238 Appendix B seed, base32-encoded.
const _rfcSeed = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
const _rfcOtpUri =
    'otpauth://totp/GitHub:leo@example.com?secret=$_rfcSeed&issuer=GitHub';

Future<void> pumpDetailScreen(WidgetTester tester, {String? otpAuthUri}) async {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final item = VaultItem(
    id: 'gh',
    title: 'GitHub',
    username: 'leo',
    secret: 'StrongPass!2026',
    category: VaultCategory.work,
    strengthScore: 80,
    lastUpdatedLabel: 'Updated now',
    otpAuthUri: otpAuthUri,
  );

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: VaultEntryDetailScreen(
        item: item,
        clipboardService: SensitiveClipboardService(isAndroid: false),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders the TOTP panel when the entry carries an otpauth URI', (
    tester,
  ) async {
    await pumpDetailScreen(tester, otpAuthUri: _rfcOtpUri);

    expect(find.byType(TotpCodePanel), findsOneWidget);
    expect(find.text('One-time code'), findsOneWidget);
    expect(find.text('GitHub'), findsWidgets);
    expect(find.text('leo@example.com'), findsOneWidget);
    expect(find.text('Copy code'), findsOneWidget);
  });

  testWidgets('shows no TOTP panel for an entry without a secret', (
    tester,
  ) async {
    await pumpDetailScreen(tester);

    expect(find.byType(TotpCodePanel), findsNothing);
    expect(find.text('One-time code'), findsNothing);
    expect(find.text('Copy code'), findsNothing);
  });
}
