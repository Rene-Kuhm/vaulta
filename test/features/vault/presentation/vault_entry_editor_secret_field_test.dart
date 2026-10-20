import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/secret_field_guard.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_editor_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

/// The secret field must not leak the revealed secret through the text
/// toolbar (plain Copy/Cut, Share, PROCESS_TEXT such as Translate) or
/// through Ctrl+C / Ctrl+X.
void main() {
  const secret = 'StrongPass2026';
  late List<String?> clipboardWrites;

  void mockPlatform(WidgetTester tester) {
    clipboardWrites = [];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          final args = call.arguments as Map<Object?, Object?>;
          clipboardWrites.add(args['text'] as String?);
          return null;
        case 'Clipboard.hasStrings':
          return <String, Object?>{'value': true};
        case 'Clipboard.getData':
          return <String, Object?>{'text': 'pasted'};
      }
      return null;
    });
    // Pretend another app registered a PROCESS_TEXT activity.
    messenger.setMockMethodCallHandler(SystemChannels.processText, (
      call,
    ) async {
      if (call.method == 'ProcessText.queryTextActions') {
        return <String, String>{'com.example.translate': 'Translate'};
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(SystemChannels.processText, null);
    });
  }

  /// Long-presses on the first characters of the field's text so a
  /// word is selected (pressing the center of a wide field lands past
  /// the end of the text and selects nothing).
  Future<void> openToolbar(WidgetTester tester, Finder field) async {
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    final rect = tester.getRect(editable);
    await tester.longPressAt(rect.centerLeft + const Offset(12, 0));
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(editable);
    expect(
      state.textEditingValue.selection.isCollapsed,
      isFalse,
      reason: 'the secret must be selected for the toolbar to offer copy',
    );
  }

  testWidgets('control: an unguarded field does show Copy, Share and '
      'Translate', (tester) async {
    mockPlatform(tester);
    final controller = TextEditingController(text: secret);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: controller)),
      ),
    );
    await tester.pump();

    await openToolbar(tester, find.byType(TextField));

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Translate'), findsOneWidget);
  });

  testWidgets(
    'revealed secret field toolbar offers no Copy/Cut/Share/Translate',
    (tester) async {
      mockPlatform(tester);
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: VaultEntryEditorScreen(),
        ),
      );
      await tester.pump();

      final field = find.widgetWithText(TextFormField, 'Password or secret');
      expect(field, findsOneWidget);
      await tester.enterText(field, secret);
      // Reveal the secret.
      await tester.tap(
        find.descendant(
          of: field,
          matching: find.byIcon(Icons.visibility_rounded),
        ),
      );
      await tester.pump();
      final editable = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(editable.obscureText, isFalse);

      await openToolbar(tester, field);

      // The whole secret is one word, so it is fully selected and
      // Select all is (correctly) not offered; Paste must remain.
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Cut'), findsNothing);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Translate'), findsNothing);
      expect(find.text('Look Up'), findsNothing);
      expect(find.text('Search Web'), findsNothing);
    },
  );

  Future<TextEditingController> pumpFieldAndPressCopyCut(
    WidgetTester tester, {
    required bool guarded,
  }) async {
    mockPlatform(tester);
    final controller = TextEditingController(text: secret);
    addTearDown(controller.dispose);
    final Widget field = TextField(
      controller: controller,
      autofocus: true,
      contextMenuBuilder: guarded ? secretFieldContextMenuBuilder : null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: guarded ? SecretFieldCopyBlocker(child: field) : field,
        ),
      ),
    );
    await tester.pump();
    controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: secret.length,
    );
    await tester.pump();

    for (final key in [LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyX]) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    return controller;
  }

  testWidgets('control: Ctrl+C / Ctrl+X copy from an unguarded field', (
    tester,
  ) async {
    final controller = await pumpFieldAndPressCopyCut(tester, guarded: false);

    expect(clipboardWrites, [secret, secret]);
    expect(controller.text, isEmpty);
  });

  testWidgets('Ctrl+C and Ctrl+X do not copy a revealed secret', (
    tester,
  ) async {
    final controller = await pumpFieldAndPressCopyCut(tester, guarded: true);

    expect(clipboardWrites, isEmpty);
    expect(controller.text, secret, reason: 'cut must not delete either');
  });
}
