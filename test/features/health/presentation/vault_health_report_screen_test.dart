// ignore_for_file: prefer_const_constructors

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_repository.dart';
import 'package:gestor_contrasenas/features/health/presentation/vault_health_report_screen.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_summary.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_dashboard_screen.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_entry_detail_screen.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

void main() {
  group('VaultHealthReportScreen', () {
    testWidgets('renders the counts reported by the repository', (
      tester,
    ) async {
      final repository = _FakeVaultRepository(
        summary: const VaultSummary(
          totalItems: 4,
          weakItems: 3,
          reusedItems: 2,
          securityScore: 60,
          connectedDevices: 1,
          syncEnabled: false,
        ),
        items: [
          _item(id: 'gh', title: 'GitHub', strength: 35, secret: 'shared'),
          _item(id: 'gl', title: 'GitLab', strength: 45, secret: 'shared'),
          _item(id: 'bank', title: 'Bank', strength: 92, secret: 'bank-only'),
          _item(id: 'mail', title: 'Email', strength: 70, secret: 'mail-only'),
        ],
      );
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultHealthReportScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // Total entries, weak entries, reused entries, and the score come
      // from VaultSummary, so these are the numbers the dashboard shows.
      expect(find.text('4'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('60'), findsOneWidget);

      // Every metric carries a plain-language explanation.
      expect(find.textContaining('easiest to guess'), findsOneWidget);
      expect(find.textContaining('unlocks several accounts'), findsOneWidget);
      expect(find.textContaining('Average strength'), findsOneWidget);
    });

    testWidgets('lists only the entries below the weak threshold', (
      tester,
    ) async {
      final repository = _FakeVaultRepository(
        summary: const VaultSummary(
          totalItems: 3,
          weakItems: 1,
          reusedItems: 0,
          securityScore: 86,
          connectedDevices: 1,
          syncEnabled: false,
        ),
        items: [
          _item(id: 'low', title: 'Below threshold', strength: 79),
          _item(id: 'at', title: 'At threshold', strength: 80),
          _item(id: 'high', title: 'Above threshold', strength: 100),
        ],
      );
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultHealthReportScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('Below threshold'), findsOneWidget);
      expect(find.text('At threshold'), findsNothing);
      expect(find.text('Above threshold'), findsNothing);
    });

    testWidgets('lists only the secrets shared by two or more entries', (
      tester,
    ) async {
      final repository = _FakeVaultRepository(
        summary: const VaultSummary(
          totalItems: 3,
          weakItems: 0,
          reusedItems: 2,
          securityScore: 90,
          connectedDevices: 1,
          syncEnabled: false,
        ),
        items: [
          _item(id: 'a', title: 'Shared A', strength: 95, secret: 'dup'),
          _item(id: 'b', title: 'Shared B', strength: 95, secret: 'dup'),
          _item(id: 'c', title: 'Single secret', strength: 95, secret: 'solo'),
        ],
      );
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultHealthReportScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('Shared A'), findsOneWidget);
      expect(find.text('Shared B'), findsOneWidget);
      expect(find.text('Single secret'), findsNothing);
      expect(find.text('2 entries share this secret'), findsOneWidget);
    });

    testWidgets('says the vault is healthy when there is nothing to report', (
      tester,
    ) async {
      final repository = _FakeVaultRepository(
        summary: const VaultSummary(
          totalItems: 2,
          weakItems: 0,
          reusedItems: 0,
          securityScore: 90,
          connectedDevices: 1,
          syncEnabled: false,
        ),
        items: [
          _item(id: 'a', title: 'Strong A', strength: 95, secret: 'one'),
          _item(id: 'b', title: 'Strong B', strength: 88, secret: 'two'),
        ],
      );
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultHealthReportScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('Your vault is healthy'), findsOneWidget);
      expect(find.text('Weak passwords to rotate'), findsNothing);
      expect(find.text('Shared secrets'), findsNothing);
    });

    testWidgets('opens the entry detail from both lists', (tester) async {
      final repository = _FakeVaultRepository(
        summary: const VaultSummary(
          totalItems: 2,
          weakItems: 2,
          reusedItems: 2,
          securityScore: 40,
          connectedDevices: 1,
          syncEnabled: false,
        ),
        items: [
          _item(id: 'a', title: 'Shared A', strength: 40, secret: 'dup'),
          _item(id: 'b', title: 'Shared B', strength: 45, secret: 'dup'),
        ],
      );
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultHealthReportScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      // The weak list is the first occurrence of the shared tile.
      await tester.tap(find.text('Shared A').first);
      await tester.pumpAndSettle();
      expect(find.byType(VaultEntryDetailScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      // The shared-secret group renders its own tappable tiles.
      await tester.tap(find.text('Shared B').last);
      await tester.pumpAndSettle();
      expect(find.byType(VaultEntryDetailScreen), findsOneWidget);
    });

    testWidgets('lays out without overflow at phone size', (tester) async {
      final repository = _FakeVaultRepository(
        summary: const VaultSummary(
          totalItems: 3,
          weakItems: 2,
          reusedItems: 2,
          securityScore: 59,
          connectedDevices: 1,
          syncEnabled: false,
        ),
        items: [
          _item(id: 'a', title: 'GitHub', strength: 40, secret: 'dup'),
          _item(id: 'b', title: 'GitLab', strength: 45, secret: 'dup'),
          _item(id: 'c', title: 'Bank', strength: 92, secret: 'solo'),
        ],
      );
      // A real phone viewport: the tall viewport used by the other
      // tests would hide a horizontal overflow inside a metric row or
      // the shared-secret badge.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _testApp(VaultHealthReportScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);

      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
      expect(find.text('2 entries share this secret'), findsOneWidget);
    });

    testWidgets('surfaces a retry action when the vault cannot be read', (
      tester,
    ) async {
      final repository = _FakeVaultRepository(
        summary: const VaultSummary(
          totalItems: 0,
          weakItems: 0,
          reusedItems: 0,
          securityScore: 0,
          connectedDevices: 0,
          syncEnabled: false,
        ),
        items: const [],
        loadError: StateError('boom'),
      );
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultHealthReportScreen(repository: repository)),
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

  group('Dashboard entry point', () {
    testWidgets('the dashboard opens the health report', (tester) async {
      final repository = _FakeVaultRepository(
        summary: const VaultSummary(
          totalItems: 1,
          weakItems: 1,
          reusedItems: 0,
          securityScore: 40,
          connectedDevices: 1,
          syncEnabled: false,
        ),
        items: [_item(id: 'a', title: 'Only entry', strength: 40)],
      );
      _setTallViewport(tester);

      await tester.pumpWidget(
        _testApp(VaultDashboardScreen(repository: repository)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final entryPoint = find.text('Vault health report');
      expect(entryPoint, findsOneWidget);

      await tester.tap(entryPoint);
      await tester.pumpAndSettle();

      expect(find.byType(VaultHealthReportScreen), findsOneWidget);
    });
  });
}

void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _testApp(Widget home) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
}

VaultItem _item({
  required String id,
  required String title,
  required int strength,
  String? secret,
}) {
  return VaultItem(
    id: id,
    title: title,
    username: '$id@vaulta.app',
    secret: secret ?? 'secret-$id',
    category: VaultCategory.personal,
    strengthScore: strength,
    lastUpdatedLabel: 'Updated now',
  );
}

class _FakeVaultRepository implements VaultRepository {
  _FakeVaultRepository({
    required this.items,
    required this.summary,
    this.loadError,
  });

  final List<VaultItem> items;
  final VaultSummary summary;
  final Object? loadError;

  @override
  Future<VaultSummary> fetchSummary() async {
    if (loadError != null) throw loadError!;
    return summary;
  }

  @override
  Future<List<VaultItem>> fetchItems() async {
    if (loadError != null) throw loadError!;
    return items;
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
