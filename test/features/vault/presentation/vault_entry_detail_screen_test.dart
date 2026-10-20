import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/sensitive_clipboard_service.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_detail_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  const item = VaultItem(
    id: 'gh',
    title: 'GitHub',
    username: 'leo',
    secret: 'StrongPass!2026',
    category: VaultCategory.work,
    strengthScore: 80,
    lastUpdatedLabel: 'Updated now',
  );

  String? systemClipboard;
  late List<String?> systemWrites;

  setUp(() {
    systemClipboard = null;
    systemWrites = [];
  });

  Future<void> pumpScreen(
    WidgetTester tester,
    SensitiveClipboardService service,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            final args = call.arguments as Map<Object?, Object?>;
            systemClipboard = args['text'] as String?;
            systemWrites.add(systemClipboard);
            return null;
          case 'Clipboard.getData':
            return <String, Object?>{'text': systemClipboard};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: VaultEntryDetailScreen(item: item, clipboardService: service),
      ),
    );
    await tester.pump();
  }

  Future<void> tapCopy(WidgetTester tester) async {
    await tester.tap(find.text('Copy secret'));
    await tester.pump();
  }

  testWidgets('copies the secret through the sensitive clipboard service', (
    tester,
  ) async {
    final service = _RecordingClipboardService();
    await pumpScreen(tester, service);
    await tapCopy(tester);

    expect(service.copies, ['StrongPass!2026']);
    expect(systemWrites, isEmpty);
  });

  testWidgets('clears the clipboard after 30 s when unchanged', (tester) async {
    await pumpScreen(tester, SensitiveClipboardService(isAndroid: false));
    await tapCopy(tester);
    expect(systemWrites, ['StrongPass!2026']);

    await tester.pump(const Duration(seconds: 29));
    expect(systemWrites, ['StrongPass!2026']);

    await tester.pump(const Duration(seconds: 2));
    expect(systemWrites, ['StrongPass!2026', '']);
    // The "copied" snackbar is still queued ahead; let it time out.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Clipboard cleared.'), findsOneWidget);
  });

  testWidgets(
    'does not clear the clipboard if the user copied something else',
    (tester) async {
      await pumpScreen(tester, SensitiveClipboardService(isAndroid: false));
      await tapCopy(tester);

      systemClipboard = 'something else';
      await tester.pump(const Duration(seconds: 31));

      expect(systemWrites, ['StrongPass!2026']);
      expect(systemClipboard, 'something else');
    },
  );

  testWidgets('revealed secret is not selectable, so it has no text '
      'toolbar (no plain Copy, Share or PROCESS_TEXT)', (tester) async {
    await pumpScreen(tester, _RecordingClipboardService());

    await tester.tap(find.text('Show'));
    await tester.pump();
    expect(find.text('StrongPass!2026'), findsOneWidget);

    expect(
      find.ancestor(
        of: find.text('StrongPass!2026'),
        matching: find.byType(SelectableText),
      ),
      findsNothing,
    );
    expect(find.byType(SelectableText), findsNothing);

    await tester.longPress(find.text('StrongPass!2026'));
    await tester.pump();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Share'), findsNothing);
    expect(systemWrites, isEmpty);
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
