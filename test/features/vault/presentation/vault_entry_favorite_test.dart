// Favorites are user-visible state, so the editor and the detail screen
// must show it and let the user flip it. The dashboard persists what
// they hand back; the screens themselves own the visible state.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_detail_screen.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_editor_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  VaultItem itemWith({bool isFavorite = false}) {
    return VaultItem(
      id: 'gh',
      title: 'GitHub',
      username: 'leo@example.com',
      secret: 'StrongPass!2026',
      category: VaultCategory.work,
      strengthScore: 80,
      lastUpdatedLabel: 'Updated now',
      isFavorite: isFavorite,
    );
  }

  Widget testApp(Widget home) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );
  }

  void setTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('VaultEntryEditorScreen favorites', () {
    late VaultItem? saved;

    /// Pumps a host screen that pushes the editor and keeps whatever the
    /// editor pops.
    Future<void> openEditor(WidgetTester tester, VaultItem? initialItem) async {
      saved = null;
      setTallViewport(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
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

    Future<void> save(WidgetTester tester) async {
      final button = find.text('Save changes');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    Finder favoriteSwitch() => find.byType(Switch);

    testWidgets('shows a stored favorite as switched on', (tester) async {
      await openEditor(tester, itemWith(isFavorite: true));

      expect(tester.widget<Switch>(favoriteSwitch()).value, isTrue);
      expect(find.text('Favorite entry'), findsOneWidget);
    });

    testWidgets('shows a non-favorite as switched off', (tester) async {
      await openEditor(tester, itemWith());

      expect(tester.widget<Switch>(favoriteSwitch()).value, isFalse);
    });

    testWidgets('marks an entry as favorite when saved', (tester) async {
      await openEditor(tester, itemWith());

      await tester.ensureVisible(favoriteSwitch());
      await tester.tap(favoriteSwitch());
      await tester.pumpAndSettle();
      await save(tester);

      expect(saved, isNotNull);
      expect(saved!.isFavorite, isTrue);
      // Nothing else about the entry changed.
      expect(saved!.title, 'GitHub');
      expect(saved!.secret, 'StrongPass!2026');
    });

    testWidgets('unmarks a favorite and keeps every other field', (
      tester,
    ) async {
      await openEditor(tester, itemWith(isFavorite: true));

      await tester.ensureVisible(favoriteSwitch());
      await tester.tap(favoriteSwitch());
      await tester.pumpAndSettle();
      await save(tester);

      expect(saved!.isFavorite, isFalse);
      expect(saved!.title, 'GitHub');
      expect(saved!.username, 'leo@example.com');
    });

    testWidgets('a new entry starts not favorite and can be created as one', (
      tester,
    ) async {
      await openEditor(tester, null);

      expect(tester.widget<Switch>(favoriteSwitch()).value, isFalse);

      const fieldLabels = ['Title', 'Username or email', 'Password or secret'];
      final values = ['GitHub', 'leo', 'BrandNew!2026'];
      for (var index = 0; index < fieldLabels.length; index++) {
        await tester.enterText(
          find.ancestor(
            of: find.text(fieldLabels[index]),
            matching: find.byType(TextFormField),
          ),
          values[index],
        );
      }
      await tester.ensureVisible(favoriteSwitch());
      await tester.tap(favoriteSwitch());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create entry'));
      await tester.pumpAndSettle();

      expect(saved!.isFavorite, isTrue);
    });
  });

  group('VaultEntryDetailScreen favorites', () {
    testWidgets(
      'shows a favorite pill and marks/unmarks through the callback',
      (tester) async {
        final requested = <bool>[];
        setTallViewport(tester);

        await tester.pumpWidget(
          testApp(
            VaultEntryDetailScreen(
              item: itemWith(),
              onToggleFavorite: (isFavorite) async {
                requested.add(isFavorite);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Favorite'), findsNothing);
        expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);
        expect(find.byTooltip('Mark as favorite'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.star_border_rounded));
        await tester.pumpAndSettle();

        expect(requested, [true]);
        expect(find.text('Favorite'), findsOneWidget);
        expect(find.byIcon(Icons.star_rounded), findsOneWidget);
        expect(find.byTooltip('Remove from favorites'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.star_rounded));
        await tester.pumpAndSettle();

        expect(requested, [true, false]);
        expect(find.text('Favorite'), findsNothing);
        expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);
      },
    );

    testWidgets('renders the favorite state of the item it is given', (
      tester,
    ) async {
      setTallViewport(tester);

      await tester.pumpWidget(
        testApp(const VaultEntryDetailScreen(item: _favoriteItem)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Favorite'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });

    testWidgets('disables the favorite action without a callback', (
      tester,
    ) async {
      setTallViewport(tester);

      await tester.pumpWidget(
        testApp(VaultEntryDetailScreen(item: itemWith())),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.star_border_rounded),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });
}

const _favoriteItem = VaultItem(
  id: 'gh',
  title: 'GitHub',
  username: 'leo@example.com',
  secret: 'StrongPass!2026',
  category: VaultCategory.work,
  strengthScore: 80,
  lastUpdatedLabel: 'Updated now',
  isFavorite: true,
);
