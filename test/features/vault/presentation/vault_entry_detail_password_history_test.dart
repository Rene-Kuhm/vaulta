import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/sensitive_clipboard_service.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_detail_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

/// Rotating a password is only useful if the old one can still be read
/// and copied, so the detail screen owns that surface.
void main() {
  const currentSecret = 'CurrentPass!2026';

  final history = [
    PasswordHistoryEntry(
      secret: 'AlphaOldPass',
      replacedAt: DateTime.utc(2024, 3, 4, 10, 22),
    ),
    PasswordHistoryEntry(
      secret: 'BravoOldKey',
      replacedAt: DateTime.utc(2025, 7, 8, 9, 5),
    ),
  ];

  VaultItem itemWith(List<PasswordHistoryEntry> passwordHistory) {
    return VaultItem(
      id: 'gh',
      title: 'GitHub',
      username: 'leo',
      secret: currentSecret,
      category: VaultCategory.work,
      strengthScore: 80,
      lastUpdatedLabel: 'Updated now',
      passwordHistory: passwordHistory,
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    required VaultItem item,
    SensitiveClipboardService? clipboardService,
  }) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: VaultEntryDetailScreen(
          item: item,
          clipboardService: clipboardService,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expandHistory(WidgetTester tester) async {
    await tester.tap(find.text('Previous passwords'));
    await tester.pumpAndSettle();
  }

  testWidgets('hides the section entirely when the item has no history', (
    tester,
  ) async {
    await pumpScreen(tester, item: itemWith(const <PasswordHistoryEntry>[]));

    expect(find.text('Previous passwords'), findsNothing);
    expect(find.byTooltip('Copy previous password'), findsNothing);
  });

  testWidgets('lists previous passwords newest first, each with its date', (
    tester,
  ) async {
    await pumpScreen(tester, item: itemWith(history));

    // Collapsed by default.
    expect(find.text('Previous passwords'), findsOneWidget);
    expect(find.byTooltip('Copy previous password'), findsNothing);

    await expandHistory(tester);

    expect(find.byTooltip('Copy previous password'), findsNWidgets(2));

    final newest = tester.getTopLeft(find.textContaining('2025'));
    final oldest = tester.getTopLeft(find.textContaining('2024'));
    expect(newest.dy, lessThan(oldest.dy));

    // Only the last four characters of an old secret are shown by default.
    expect(find.text('BravoOldKey'), findsNothing);
    expect(find.text('*******dKey'), findsOneWidget);
    expect(find.text('********Pass'), findsOneWidget);
  });

  testWidgets('copies a previous password through the sensitive clipboard '
      'service', (tester) async {
    final service = _RecordingClipboardService();
    await pumpScreen(
      tester,
      item: itemWith(history),
      clipboardService: service,
    );
    await expandHistory(tester);

    // First copy action belongs to the newest entry.
    await tester.tap(find.byTooltip('Copy previous password').first);
    await tester.pump();

    expect(service.copies, ['BravoOldKey']);
  });

  testWidgets('reveals a previous password on request', (tester) async {
    await pumpScreen(tester, item: itemWith(history));
    await expandHistory(tester);

    await tester.tap(find.byTooltip('Show previous password').first);
    await tester.pumpAndSettle();

    expect(find.text('BravoOldKey'), findsOneWidget);
    expect(find.byTooltip('Hide previous password'), findsOneWidget);
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
