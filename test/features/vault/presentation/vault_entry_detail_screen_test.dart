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

  late _RecordingClipboardService service;
  String? systemClipboard;
  late List<String?> systemWrites;

  setUp(() {
    systemClipboard = null;
    systemWrites = [];
    service = _RecordingClipboardService(onCopy: (t) => systemClipboard = t);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
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
    await pumpScreen(tester);
    await tapCopy(tester);

    expect(service.copies, ['StrongPass!2026']);
    expect(systemWrites, isEmpty);

    // Let the pending 30-second clear timer complete.
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('clears the clipboard after 30 s when unchanged', (tester) async {
    await pumpScreen(tester);
    await tapCopy(tester);

    await tester.pump(const Duration(seconds: 29));
    expect(systemWrites, isEmpty);

    await tester.pump(const Duration(seconds: 2));
    expect(systemWrites, ['']);
  });

  testWidgets(
    'does not clear the clipboard if the user copied something else',
    (tester) async {
      await pumpScreen(tester);
      await tapCopy(tester);

      systemClipboard = 'something else';
      await tester.pump(const Duration(seconds: 31));

      expect(systemWrites, isEmpty);
      expect(systemClipboard, 'something else');
    },
  );
}

class _RecordingClipboardService extends SensitiveClipboardService {
  _RecordingClipboardService({required this.onCopy}) : super(isAndroid: false);

  final void Function(String text) onCopy;
  final List<String> copies = [];

  @override
  Future<void> copySensitive(String text) async {
    copies.add(text);
    onCopy(text);
  }
}
