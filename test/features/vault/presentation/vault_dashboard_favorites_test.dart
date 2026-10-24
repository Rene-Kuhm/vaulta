// The dashboard owns the favorites filter: it must sit next to the
// existing filters, show only favorite entries, and be clearable without
// leaving the screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_repository.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_summary.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_dashboard_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  void setTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget testApp(Widget home) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );
  }

  Future<void> pumpDashboard(
    WidgetTester tester,
    VaultRepository repository,
  ) async {
    setTallViewport(tester);
    await tester.pumpWidget(
      testApp(VaultDashboardScreen(repository: repository)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> selectFilter(
    WidgetTester tester,
    String current,
    String next,
  ) async {
    await tester.tap(find.text(current).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(next).last);
    await tester.pumpAndSettle();
  }

  group('VaultDashboardScreen favorites filter', () {
    testWidgets('is listed next to the existing filters', (tester) async {
      await pumpDashboard(tester, _FakeVaultRepository(items: _seedItems()));

      await tester.tap(find.text('All entries').first);
      await tester.pumpAndSettle();

      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('Weak passwords only'), findsOneWidget);
      expect(find.text('Entries with notes'), findsOneWidget);
    });

    testWidgets('shows only favorite entries and clears back to all', (
      tester,
    ) async {
      await pumpDashboard(tester, _FakeVaultRepository(items: _seedItems()));

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Bank'), findsOneWidget);

      await selectFilter(tester, 'All entries', 'Favorites');

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Bank'), findsNothing);
      expect(find.text('Email'), findsNothing);

      await selectFilter(tester, 'Favorites', 'All entries');

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Bank'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
    });

    testWidgets('with no favorites the reset button clears the filter', (
      tester,
    ) async {
      await pumpDashboard(
        tester,
        _FakeVaultRepository(items: [_item('1', 'GitHub'), _item('2', 'Bank')]),
      );

      await selectFilter(tester, 'All entries', 'Favorites');

      expect(
        find.text('No entries match your current filters'),
        findsOneWidget,
      );

      await tester.tap(find.text('Reset filters'));
      await tester.pumpAndSettle();

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Bank'), findsOneWidget);
      expect(find.text('All entries'), findsOneWidget);
    });

    testWidgets('editing right after marking a favorite keeps it', (
      tester,
    ) async {
      // Regression: the editor used to be seeded from the entry the
      // dashboard had captured when opening the detail screen, so saving
      // an edit made right after the favorite toggle wrote the flag back
      // to false.
      final repository = _SavingVaultRepository(items: _seedItems());
      await pumpDashboard(tester, repository);

      await tester.tap(find.text('Bank'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.star_border_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_rounded));
      await tester.pumpAndSettle();

      // The editor shows the state the detail screen already has.
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      final saveButton = find.text('Save changes');
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(repository.saved.first.isFavorite, isTrue);
      expect(repository.saved.last.title, 'Bank');
      expect(repository.saved.last.isFavorite, isTrue);
      expect(
        repository.items.singleWhere((item) => item.id == '2').isFavorite,
        isTrue,
      );
    });

    testWidgets('marking a favorite from the detail screen persists it', (
      tester,
    ) async {
      final repository = _SavingVaultRepository(items: _seedItems());
      await pumpDashboard(tester, repository);

      await tester.tap(find.text('Bank'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.star_border_rounded));
      await tester.pumpAndSettle();

      expect(repository.saved.map((item) => item.isFavorite), [true]);
      expect(find.text('Favorite'), findsOneWidget);

      // Back to the dashboard: the favorites filter now finds the entry
      // that was just marked.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await selectFilter(tester, 'All entries', 'Favorites');

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Bank'), findsOneWidget);
      expect(find.text('Email'), findsNothing);
    });
  });
}

VaultItem _item(String id, String title, {bool isFavorite = false}) {
  return VaultItem(
    id: id,
    title: title,
    username: '$title-user',
    secret: 'StrongPass!2026',
    category: VaultCategory.personal,
    strengthScore: 80,
    lastUpdatedLabel: 'Updated now',
    isFavorite: isFavorite,
  );
}

List<VaultItem> _seedItems() {
  return [
    _item('1', 'GitHub', isFavorite: true),
    _item('2', 'Bank'),
    _item('3', 'Email'),
  ];
}

class _FakeVaultRepository implements VaultRepository {
  _FakeVaultRepository({required this.items});

  final List<VaultItem> items;

  @override
  Future<List<VaultItem>> fetchItems() async => items;

  @override
  Future<VaultSummary> fetchSummary() async => VaultSummary(
    totalItems: items.length,
    weakItems: 0,
    reusedItems: 0,
    securityScore: items.isEmpty ? 0 : 80,
    connectedDevices: 1,
    syncEnabled: false,
  );

  @override
  Future<VaultItem?> fetchItemById(String id) async {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<VaultItem> saveItem(VaultItem item) async => item;

  @override
  Future<void> deleteItem(String id) async {}
}

/// Repository that records every write and reflects it on the next read,
/// so the dashboard's re-read after a favorite toggle sees the change.
class _SavingVaultRepository implements VaultRepository {
  _SavingVaultRepository({required List<VaultItem> items})
    : _items = [...items];

  final List<VaultItem> _items;
  final List<VaultItem> saved = <VaultItem>[];

  /// Current repository contents, in insertion order.
  List<VaultItem> get items => List.unmodifiable(_items);

  @override
  Future<List<VaultItem>> fetchItems() async => List.unmodifiable(_items);

  @override
  Future<VaultSummary> fetchSummary() async => VaultSummary(
    totalItems: _items.length,
    weakItems: 0,
    reusedItems: 0,
    securityScore: 80,
    connectedDevices: 1,
    syncEnabled: false,
  );

  @override
  Future<VaultItem?> fetchItemById(String id) async {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<VaultItem> saveItem(VaultItem item) async {
    saved.add(item);
    final index = _items.indexWhere((candidate) => candidate.id == item.id);
    if (index == -1) {
      _items.add(item);
    } else {
      _items[index] = item;
    }
    return item;
  }

  @override
  Future<void> deleteItem(String id) async {
    _items.removeWhere((item) => item.id == id);
  }
}
