import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/security/vault_repository.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_summary.dart';
import 'package:gestor_contrasenas/features/vault/presentation/vault_import_screen.dart';

import '../application/kdbx_test_fixtures.dart';

void main() {
  late Uint8List kdbxBytes;

  setUpAll(() async {
    kdbxBytes = await buildKdbxFixture();
  });

  testWidgets(
    'a .kdbx pick asks for the master password and previews its entries',
    (tester) async {
      await _pumpScreen(
        tester,
        picker: _FakeFilePicker(_pickedFile('passwords.kdbx', kdbxBytes)),
      );

      await tester.tap(find.text('Elegir archivo'));
      await _settle(tester);

      // The encrypted database cannot be previewed without the
      // password, so the dialog comes first.
      expect(find.text('Base KeePass .kdbx'), findsOneWidget);
      expect(
        find.byKey(const Key('import.kdbx.masterPassword')),
        findsOneWidget,
      );
      expect(find.text('Vista previa'), findsNothing);

      // A wrong password fails with a clear message instead of an
      // empty preview.
      await tester.enterText(
        find.byKey(const Key('import.kdbx.masterPassword')),
        'not-the-password',
      );
      await tester.tap(find.byKey(const Key('import.kdbx.confirm')));
      await _settle(tester);

      expect(find.textContaining('no coinciden'), findsOneWidget);
      expect(find.text('Vista previa'), findsNothing);

      // The right password produces the same preview shape as the CSV
      // and JSON imports.
      await tester.tap(find.text('Elegir archivo'));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const Key('import.kdbx.masterPassword')),
        kdbxFixturePassword,
      );
      await tester.tap(find.byKey(const Key('import.kdbx.confirm')));
      await _settle(tester);
      await _scrollToPreview(tester);

      expect(find.text('Vista previa'), findsOneWidget);
      expect(find.textContaining('3 listas para importar'), findsOneWidget);
      expect(find.text('Importar (3)'), findsOneWidget);
      expect(find.text('GitLab'), findsOneWidget);
    },
  );

  testWidgets('cancelling the .kdbx password dialog imports nothing', (
    tester,
  ) async {
    await _pumpScreen(
      tester,
      picker: _FakeFilePicker(_pickedFile('passwords.kdbx', kdbxBytes)),
    );

    await tester.tap(find.text('Elegir archivo'));
    await _settle(tester);
    await tester.tap(find.text('Cancelar'));
    await _settle(tester);

    expect(find.text('Base KeePass .kdbx'), findsNothing);
    expect(find.text('Vista previa'), findsNothing);
    expect(find.text('Elegir archivo'), findsOneWidget);
  });

  testWidgets('CSV files still skip the password dialog', (tester) async {
    await _pumpScreen(
      tester,
      picker: _FakeFilePicker(
        _pickedFile(
          'passwords.csv',
          Uint8List.fromList(
            'title,username,password,url,category\n'
                    'GitHub,leo@example.com,StrongPass!2026,'
                    'https://github.com,Work'
                .codeUnits,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Elegir archivo'));
    await _settle(tester);
    await _scrollToPreview(tester);

    expect(find.text('Base KeePass .kdbx'), findsNothing);
    expect(find.text('Vista previa'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _FakeFilePicker picker,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: VaultImportScreen(
        repository: _ImportTestRepository(),
        existingItems: const [],
        pickFiles: picker.call,
      ),
    ),
  );
}

/// Pumps a few frames without waiting for the tree to go quiet: the
/// screen keeps an indeterminate progress indicator on the pick button
/// while the password dialog is open, so `pumpAndSettle` never returns.
Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _scrollToPreview(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -900));
  await _settle(tester);
}

FilePickerResult _pickedFile(String name, Uint8List bytes) {
  return FilePickerResult([
    PlatformFile(name: name, size: bytes.length, bytes: bytes),
  ]);
}

/// File picker stub that answers with the same result every time, so a
/// test can drive the import flow without the platform dialog.
class _FakeFilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;

  Future<FilePickerResult?> call({
    required FileType type,
    List<String>? allowedExtensions,
  }) async {
    return result;
  }
}

class _ImportTestRepository implements VaultRepository {
  final List<VaultItem> savedItems = [];

  @override
  Future<void> deleteItem(String id) async {}

  @override
  Future<VaultItem?> fetchItemById(String id) async => null;

  @override
  Future<List<VaultItem>> fetchItems() async => const [];

  @override
  Future<VaultSummary> fetchSummary() async {
    return const VaultSummary(
      totalItems: 0,
      weakItems: 0,
      reusedItems: 0,
      securityScore: 0,
      connectedDevices: 1,
      syncEnabled: false,
    );
  }

  @override
  Future<VaultItem> saveItem(VaultItem item) async {
    savedItems.add(item);
    return item;
  }
}
