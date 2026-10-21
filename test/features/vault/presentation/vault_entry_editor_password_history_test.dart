import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_editor_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

/// Saving an edit through the editor is what rotates a password, so the
/// editor owns the rule that records the previous secret.
void main() {
  VaultItem itemWith({
    String secret = 'OldPass!2025',
    List<PasswordHistoryEntry> passwordHistory = const <PasswordHistoryEntry>[],
  }) {
    return VaultItem(
      id: 'gh',
      title: 'GitHub',
      username: 'leo',
      secret: secret,
      category: VaultCategory.work,
      strengthScore: 80,
      lastUpdatedLabel: 'Updated now',
      passwordHistory: passwordHistory,
    );
  }

  late VaultItem? saved;

  /// Pumps a host screen that pushes the editor and keeps whatever the
  /// editor pops.
  Future<void> openEditor(WidgetTester tester, VaultItem? initialItem) async {
    saved = null;
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await Navigator.of(context).push<VaultItem>(
                  MaterialPageRoute(
                    builder: (_) =>
                        VaultEntryEditorScreen(initialItem: initialItem),
                  ),
                );
              },
              child: const Text('open-editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-editor'));
    await tester.pumpAndSettle();
  }

  Finder fieldWithLabel(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(TextFormField));

  Future<void> save(WidgetTester tester) async {
    final button = find.text('Save changes');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('records the previous secret with a timestamp when the secret '
      'changes', (tester) async {
    final before = DateTime.now();
    await openEditor(tester, itemWith());

    await tester.enterText(
      fieldWithLabel('Password or secret'),
      'NewPass!2026',
    );
    await save(tester);
    final after = DateTime.now();

    expect(saved, isNotNull);
    expect(saved!.secret, 'NewPass!2026');
    expect(saved!.passwordHistory, hasLength(1));
    expect(saved!.passwordHistory.single.secret, 'OldPass!2025');
    expect(saved!.passwordHistory.single.replacedAt.isBefore(before), isFalse);
    expect(saved!.passwordHistory.single.replacedAt.isAfter(after), isFalse);
  });

  testWidgets('records nothing when the secret is saved unchanged', (
    tester,
  ) async {
    await openEditor(tester, itemWith());

    await save(tester);

    expect(saved, isNotNull);
    expect(saved!.secret, 'OldPass!2025');
    expect(saved!.passwordHistory, isEmpty);
  });

  testWidgets('appends to an existing history instead of replacing it', (
    tester,
  ) async {
    await openEditor(
      tester,
      itemWith(
        passwordHistory: [
          PasswordHistoryEntry(
            secret: 'OlderPass!2024',
            replacedAt: DateTime.utc(2024, 1, 1),
          ),
        ],
      ),
    );

    await tester.enterText(
      fieldWithLabel('Password or secret'),
      'NewPass!2026',
    );
    await save(tester);

    expect(saved!.passwordHistory.map((entry) => entry.secret), [
      'OlderPass!2024',
      'OldPass!2025',
    ]);
  });

  testWidgets('a new entry starts with no history', (tester) async {
    await openEditor(tester, null);

    await tester.enterText(fieldWithLabel('Title'), 'GitHub');
    await tester.enterText(fieldWithLabel('Username or email'), 'leo');
    await tester.enterText(
      fieldWithLabel('Password or secret'),
      'BrandNew!2026',
    );

    final button = find.text('Create entry');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.passwordHistory, isEmpty);
  });

  testWidgets('the previous password is not shown as an editable field', (
    tester,
  ) async {
    await openEditor(
      tester,
      itemWith(
        passwordHistory: [
          PasswordHistoryEntry(
            secret: 'RetiredSecret!2023',
            replacedAt: DateTime.utc(2023, 6, 1),
          ),
        ],
      ),
    );

    // The history is never rendered by the editor...
    expect(find.text('RetiredSecret!2023'), findsNothing);
    expect(find.textContaining('RetiredSecret'), findsNothing);

    // ...and only the current secret is held by an editable field.
    final editableValues = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller?.text)
        .toList();
    expect(
      editableValues.where((value) => value == 'OldPass!2025'),
      hasLength(1),
    );
    expect(editableValues, isNot(contains('RetiredSecret!2023')));
  });
}
