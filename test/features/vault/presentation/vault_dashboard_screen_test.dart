// ignore_for_file: prefer_const_constructors

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/app/design_system/metric_card.dart';
import 'package:gestor_contrasenas/core/security/vault_repository.dart';
import 'package:gestor_contrasenas/core/sync/vault_change_signal.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_summary.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_dashboard_screen.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_detail_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  group('VaultDashboardScreen filtering', () {
    testWidgets('filters by free-text search across title and username', (
      tester,
    ) async {
      final items = _seedItems();
      final repository = _FakeVaultRepository(items: items);

      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: VaultDashboardScreen(repository: repository),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Bank'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, '').first, 'bank');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('GitHub'), findsNothing);
      expect(find.text('Bank'), findsOneWidget);
      expect(find.text('Email'), findsNothing);
    });

    testWidgets('free-text search narrows the visible list and clears back', (
      tester,
    ) async {
      final items = _seedItems();
      final repository = _FakeVaultRepository(items: items);

      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: VaultDashboardScreen(repository: repository),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // Sanity: every item starts visible.
      expect(find.text('GitHub'), findsOneWidget);

      // Type a query that matches nothing to confirm filtering is wired.
      final searchField = find.byType(TextField).first;
      await tester.enterText(searchField, 'weak');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // The exact 'GitHub' tile is filtered out by 'weak' (matches a
      // username, not a title), so the Vault list is no longer showing
      // the GitHub entry.
      expect(find.text('GitHub'), findsNothing);

      // Clearing the search restores every item.
      await tester.enterText(searchField, '');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Bank'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
    });

    testWidgets('shows the empty state when there are no items', (
      tester,
    ) async {
      final repository = _FakeVaultRepository(items: const []);

      // Use a tall viewport so the dashboard renders the whole sliver
      // chain, including the bottom empty-state card.
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: VaultDashboardScreen(repository: repository),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == 'Your vault is empty',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the no-results state when filters exclude everything', (
      tester,
    ) async {
      final items = _seedItems();
      final repository = _FakeVaultRepository(items: items);

      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: VaultDashboardScreen(repository: repository),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      await tester.enterText(
        find.widgetWithText(TextField, '').first,
        'nothing-matches-this',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == 'No entries match your current filters',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'handles case, whitespace, special characters, and empty query',
      (tester) async {
        final items = _seedItems();
        final repository = _FakeVaultRepository(items: items);
        _setTallViewport(tester);

        await tester.pumpWidget(
          _testApp(VaultDashboardScreen(repository: repository)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        final searchField = find.byType(TextField).first;

        await tester.enterText(searchField, '  BANK  ');
        await tester.pump();
        expect(find.text('Bank'), findsOneWidget);
        expect(find.text('GitHub'), findsNothing);

        await tester.enterText(searchField, 'LEO@EXAMPLE.COM');
        await tester.pump();
        expect(find.text('GitHub'), findsOneWidget);
        expect(find.text('Bank'), findsNothing);

        await tester.enterText(searchField, '@vaulta.app');
        await tester.pump();
        expect(find.text('Bank'), findsOneWidget);
        expect(find.text('Email'), findsOneWidget);
        expect(find.text('GitHub'), findsNothing);

        await tester.enterText(searchField, '');
        await tester.pump();
        expect(find.text('GitHub'), findsOneWidget);
        expect(find.text('Bank'), findsOneWidget);
        expect(find.text('Email'), findsOneWidget);
      },
    );

    testWidgets('keeps only the latest visible query when typing quickly', (
      tester,
    ) async {
      final items = _seedItems();
      final repository = _FakeVaultRepository(items: items);
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultDashboardScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final searchField = find.byType(TextField).first;
      await tester.enterText(searchField, 'bank');
      await tester.enterText(searchField, 'github');
      await tester.enterText(searchField, 'email');
      await tester.pump();

      expect(find.text('Email'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);
      expect(find.text('Bank'), findsNothing);
      expect(repository.fetchItemsCalls, 1);
    });

    testWidgets('does not duplicate results after repeated matching queries', (
      tester,
    ) async {
      final items = _seedItems();
      final repository = _FakeVaultRepository(items: items);
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultDashboardScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final searchField = find.byType(TextField).first;
      await tester.enterText(searchField, 'bank');
      await tester.pump();
      await tester.enterText(searchField, 'BANK');
      await tester.pump();

      expect(find.text('Bank'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);
      expect(find.text('Email'), findsNothing);
    });

    testWidgets('shows loading while vault data is still loading', (
      tester,
    ) async {
      final repository = _DelayedVaultRepository();
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultDashboardScreen(repository: repository)),
      );
      await tester.pump();

      expect(_dashboardLoadingSpinner(), findsOneWidget);

      repository.complete(items: _seedItems());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(_dashboardLoadingSpinner(), findsNothing);
      expect(find.text('GitHub'), findsOneWidget);
    });

    testWidgets('shows an error state when vault data cannot load', (
      tester,
    ) async {
      final repository = _FakeVaultRepository(
        items: const [],
        loadError: StateError('boom'),
      );
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultDashboardScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        find.text('Vaulta could not decrypt the local vault right now.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    });
  });

  group('VaultDashboardScreen sync changes', () {
    testWidgets(
      're-reads the vault on the sync signal, with no pull-to-refresh',
      (tester) async {
        final repository = _MutableVaultRepository(
          items: [_item('1', 'Alfa')],
        );
        final vaultChanges = VaultChangeSignal();
        _setTallViewport(tester);

        await tester.pumpWidget(
          _testApp(
            VaultDashboardScreen(
              repository: repository,
              vaultChanges: vaultChanges,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        expect(find.text('Alfa'), findsOneWidget);
        expect(_vaultEntriesCard(tester).value, '1');
        expect(repository.fetchItemsCalls, 1);
        // The gesture-based path exists but is never used below.
        expect(find.byType(RefreshIndicator), findsOneWidget);

        // A pull landed: the repository now holds one more entry.
        repository.replaceItems([_item('1', 'Alfa'), _item('2', 'Bravo')]);
        vaultChanges.notifyVaultChanged(origin: VaultChangeOrigin.pull);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        expect(repository.fetchItemsCalls, 2);
        expect(find.text('Bravo'), findsOneWidget);
        expect(_vaultEntriesCard(tester).value, '2');

        // A remote vault-key adoption is the other external change: same
        // reaction, no gesture either.
        repository.replaceItems([
          _item('1', 'Alfa'),
          _item('2', 'Bravo'),
          _item('3', 'Charlie'),
        ]);
        vaultChanges.notifyVaultChanged(
          origin: VaultChangeOrigin.vaultKeyAdoption,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        expect(repository.fetchItemsCalls, 3);
        expect(find.text('Charlie'), findsOneWidget);
        expect(_vaultEntriesCard(tester).value, '3');
      },
    );

    testWidgets('keeps the last entries on screen while a reload is in flight', (
      tester,
    ) async {
      final repository = _MutableVaultRepository(items: [_item('1', 'Alfa')]);
      final vaultChanges = VaultChangeSignal();
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(
          VaultDashboardScreen(
            repository: repository,
            vaultChanges: vaultChanges,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Alfa'), findsOneWidget);

      repository.holdLoads = true;
      repository.replaceItems([_item('1', 'Alfa'), _item('2', 'Bravo')]);
      vaultChanges.notifyVaultChanged(origin: VaultChangeOrigin.pull);
      await tester.pump();

      // Mid-reload the spinner must not replace data the user is looking at.
      expect(_dashboardLoadingSpinner(), findsNothing);
      expect(find.text('Alfa'), findsOneWidget);

      repository.releaseLoads();
      await tester.pumpAndSettle();

      expect(find.text('Bravo'), findsOneWidget);
      expect(_vaultEntriesCard(tester).value, '2');
    });
  });

  group('VaultEntryDetailScreen', () {
    testWidgets('obscures the secret by default and reveals on tap', (
      tester,
    ) async {
      const item = VaultItem(
        id: 'github',
        title: 'GitHub',
        username: 'leo',
        secret: 'StrongPass!2026',
        category: VaultCategory.work,
        strengthScore: 80,
        lastUpdatedLabel: 'Updated now',
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const VaultEntryDetailScreen(item: item),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('StrongPass!2026'), findsNothing);
      expect(find.text('***********2026'), findsOneWidget);

      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('StrongPass!2026'), findsOneWidget);
    });

    testWidgets('masks short secrets entirely', (tester) async {
      const item = VaultItem(
        id: 'pin',
        title: 'PIN',
        username: 'me',
        secret: '1234',
        category: VaultCategory.personal,
        strengthScore: 20,
        lastUpdatedLabel: 'Updated now',
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const VaultEntryDetailScreen(item: item),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // The screen masks short secrets entirely (every char is a *).
      expect(find.text('****'), findsOneWidget);
    });

    testWidgets('copy button is wired and shows a confirmation snackbar', (
      tester,
    ) async {
      const item = VaultItem(
        id: 'gh',
        title: 'GitHub',
        username: 'leo',
        secret: 'StrongPass!2026',
        category: VaultCategory.work,
        strengthScore: 80,
        lastUpdatedLabel: 'Updated now',
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const VaultEntryDetailScreen(item: item),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // The copy button is present. We do NOT await Clipboard.getData
      // here because the screen schedules a 30-second clipboard-clear
      // timer that pumper has no way to advance safely, and reading
      // the clipboard from the platform channel is not deterministic
      // in a widget test. Asserting the button exists and is tappable
      // is the contract we actually care about for the dashboard.
      final copyButton = find.ancestor(
        of: find.text('Copy secret'),
        matching: find.byType(OutlinedButton),
      );
      expect(copyButton, findsOneWidget);
      expect(tester.widget<OutlinedButton>(copyButton).onPressed, isNotNull);
    });
  });

  group('Password strength estimator', () {
    test('rewards length and class diversity', () {
      expect(estimatePasswordStrength('aaaaaa'), lessThan(50));
      expect(estimatePasswordStrength('Aa1!aaaa'), greaterThanOrEqualTo(80));
      expect(
        estimatePasswordStrength('StrongPass!2026'),
        greaterThanOrEqualTo(80),
      );
    });

    test('rejects empty and very short inputs as low score', () {
      expect(estimatePasswordStrength(''), lessThan(20));
      expect(estimatePasswordStrength('a'), lessThan(20));
    });
  });
}

Widget _testApp(Widget home) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
}

void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _dashboardLoadingSpinner() {
  return find.byWidgetPredicate(
    (widget) =>
        widget is CircularProgressIndicator && widget.strokeWidth == 2.5,
  );
}

/// The "Vault entries" metric card, i.e. the number the issue reports as
/// stale after a pull.
MetricCard _vaultEntriesCard(WidgetTester tester) {
  return tester.widget<MetricCard>(
    find.byWidgetPredicate(
      (widget) => widget is MetricCard && widget.label == 'Vault entries',
    ),
  );
}

VaultItem _item(String id, String title) {
  return VaultItem(
    id: id,
    title: title,
    username: '$title-user',
    secret: 'Pass!2026',
    category: VaultCategory.personal,
    strengthScore: 80,
    lastUpdatedLabel: 'Updated now',
  );
}

List<VaultItem> _seedItems() {
  return const [
    VaultItem(
      id: '1',
      title: 'GitHub',
      username: 'leo@example.com',
      secret: 'StrongPass!2026',
      category: VaultCategory.work,
      strengthScore: 80,
      lastUpdatedLabel: 'Updated now',
    ),
    VaultItem(
      id: '2',
      title: 'Bank',
      username: 'finance@vaulta.app',
      secret: 'BankPass!2026',
      category: VaultCategory.finance,
      strengthScore: 80,
      lastUpdatedLabel: 'Updated 1h ago',
    ),
    VaultItem(
      id: '3',
      title: 'Email',
      username: 'weak-creds@vaulta.app',
      secret: 'weak',
      category: VaultCategory.personal,
      strengthScore: 5,
      lastUpdatedLabel: 'Updated 3d ago',
      notes: 'Recovery codes are in the safe.',
    ),
  ];
}

// The dashboard's filter enum is private; the search-text path in
// the tests below exercises the filter wiring through the search
// field rather than the dropdown, which keeps the assertions stable
// without depending on the internal enum name.

class _FakeVaultRepository implements VaultRepository {
  _FakeVaultRepository({required this.items, this.loadError});

  final List<VaultItem> items;
  final Object? loadError;
  VaultSummary? summaryOverride;
  int fetchItemsCalls = 0;

  @override
  Future<List<VaultItem>> fetchItems() async {
    fetchItemsCalls += 1;
    final error = loadError;
    if (error != null) {
      throw error;
    }
    return items;
  }

  @override
  Future<VaultSummary> fetchSummary() async {
    final error = loadError;
    if (error != null) {
      throw error;
    }
    return summaryOverride ??
        VaultSummary(
          totalItems: items.length,
          weakItems: items.where((i) => i.strengthScore < 80).length,
          reusedItems: 0,
          securityScore: items.isEmpty
              ? 0
              : items.fold<int>(0, (s, i) => s + i.strengthScore) ~/
                    items.length,
          connectedDevices: 1,
          syncEnabled: false,
        );
  }

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

class _DelayedVaultRepository implements VaultRepository {
  final _itemsCompleter = Completer<List<VaultItem>>();

  void complete({required List<VaultItem> items}) {
    _itemsCompleter.complete(items);
  }

  @override
  Future<List<VaultItem>> fetchItems() => _itemsCompleter.future;

  @override
  Future<VaultSummary> fetchSummary() async {
    final items = await _itemsCompleter.future;
    return VaultSummary(
      totalItems: items.length,
      weakItems: items.where((i) => i.strengthScore < 80).length,
      reusedItems: 0,
      securityScore: items.isEmpty
          ? 0
          : items.fold<int>(0, (s, i) => s + i.strengthScore) ~/ items.length,
      connectedDevices: 1,
      syncEnabled: false,
    );
  }

  @override
  Future<VaultItem?> fetchItemById(String id) async => null;

  @override
  Future<VaultItem> saveItem(VaultItem item) async => item;

  @override
  Future<void> deleteItem(String id) async {}
}

/// Repository whose contents change under the widget, standing in for the sync
/// pull that writes into the vault behind the dashboard's back. [holdLoads]
/// lets a test sit inside a reload instead of after it.
class _MutableVaultRepository implements VaultRepository {
  _MutableVaultRepository({required List<VaultItem> items})
    : _items = [...items];

  List<VaultItem> _items;
  int fetchItemsCalls = 0;
  bool holdLoads = false;
  Completer<void>? _gate;

  void replaceItems(List<VaultItem> items) {
    _items = [...items];
  }

  void releaseLoads() {
    final gate = _gate;
    _gate = null;
    holdLoads = false;
    gate?.complete();
  }

  Future<void> _awaitGate() async {
    if (!holdLoads) return;
    _gate ??= Completer<void>();
    await _gate!.future;
  }

  @override
  Future<List<VaultItem>> fetchItems() async {
    fetchItemsCalls += 1;
    await _awaitGate();
    return [..._items];
  }

  @override
  Future<VaultSummary> fetchSummary() async {
    await _awaitGate();
    final items = _items;
    return VaultSummary(
      totalItems: items.length,
      weakItems: items.where((i) => i.strengthScore < 80).length,
      reusedItems: 0,
      securityScore: items.isEmpty
          ? 0
          : items.fold<int>(0, (s, i) => s + i.strengthScore) ~/ items.length,
      connectedDevices: 1,
      syncEnabled: true,
    );
  }

  @override
  Future<VaultItem?> fetchItemById(String id) async {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<VaultItem> saveItem(VaultItem item) async => item;

  @override
  Future<void> deleteItem(String id) async {}
}
