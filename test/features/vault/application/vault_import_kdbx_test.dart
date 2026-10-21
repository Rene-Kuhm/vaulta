import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/features/vault/application/vault_import_models.dart';
import 'package:gestor_contrasenas/features/vault/application/vault_import_parser.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

import 'kdbx_test_fixtures.dart';

void main() {
  late Uint8List v4Bytes;
  late Uint8List v3Bytes;
  late Uint8List keyFileBytes;

  setUpAll(() async {
    v4Bytes = await buildKdbxFixture();
    v3Bytes = await buildKdbxFixture(v3: true);
    keyFileBytes = await buildKdbxFixture(keyFileBytes: kdbxFixtureKeyFile);
  });

  group('VaultImportParser kdbx', () {
    test('imports a KDBX 4.x database with its entries and groups', () async {
      final preview = await const VaultImportParser().parseBytes(
        fileName: 'passwords.kdbx',
        bytes: v4Bytes,
        existingItems: const [],
        masterPassword: kdbxFixturePassword,
      );

      expect(preview.source, VaultImportSource.kdbx);
      expect(preview.rejectedCount, 0);
      expect(preview.importableCount, 3);
      expect(preview.candidates.map((c) => c.row), [1, 2, 3]);

      final gitLab = preview.candidates.first.item;
      expect(gitLab.title, 'GitLab');
      expect(gitLab.username, 'deploy@vaulta.app');
      expect(gitLab.secret, 'Deploy!2026');
      expect(gitLab.website, 'https://gitlab.com');
      expect(gitLab.notes, 'Deploy key');
      // "Work" is the group path and maps to a category.
      expect(gitLab.category, VaultCategory.work);
      expect(preview.candidates.first.canImport, isTrue);

      // An entry with no password is a valid KeePass entry and must
      // survive the import instead of being rejected.
      final recovery = preview.candidates[1];
      expect(recovery.item.title, 'Recovery codes');
      expect(recovery.item.secret, isEmpty);
      expect(recovery.item.notes, 'Impresos en la caja fuerte');
      expect(recovery.canImport, isTrue);
      expect(recovery.issues, isEmpty);
    });

    test('keeps the group path in the title when no category maps', () async {
      final preview = await const VaultImportParser().parseBytes(
        fileName: 'passwords.kdbx',
        bytes: v4Bytes,
        existingItems: const [],
        masterPassword: kdbxFixturePassword,
      );

      final netflix = preview.candidates.last.item;
      expect(netflix.title, 'Netflix (Family)');
      expect(netflix.category, VaultCategory.personal);
    });

    test('imports a KDBX 3.1 database', () async {
      final preview = await const VaultImportParser().parseBytes(
        fileName: 'keepass2.kdbx',
        bytes: v3Bytes,
        existingItems: const [],
        masterPassword: kdbxFixturePassword,
      );

      expect(preview.source, VaultImportSource.kdbx);
      expect(preview.importableCount, 3);
      expect(preview.candidates.first.item.title, 'GitLab');
      expect(preview.candidates.first.item.secret, 'Deploy!2026');
      expect(preview.candidates.first.item.category, VaultCategory.work);
    });

    test('imports a database opened with a password and a key file', () async {
      final preview = await const VaultImportParser().parseBytes(
        fileName: 'passwords.kdbx',
        bytes: keyFileBytes,
        existingItems: const [],
        masterPassword: kdbxFixturePassword,
        keyFileBytes: kdbxFixtureKeyFile,
      );

      expect(preview.importableCount, 3);
      expect(preview.candidates.first.item.title, 'GitLab');
    });

    test('a wrong master password fails loudly instead of importing nothing',
        () async {
      await expectLater(
        const VaultImportParser().parseBytes(
          fileName: 'passwords.kdbx',
          bytes: v4Bytes,
          existingItems: const [],
          masterPassword: 'not-the-password',
        ),
        throwsA(
          isA<VaultImportException>().having(
            (error) => error.message,
            'message',
            contains('no coinciden'),
          ),
        ),
      );
    });

    test('a missing master password asks for one', () async {
      await expectLater(
        const VaultImportParser().parseBytes(
          fileName: 'passwords.kdbx',
          bytes: v4Bytes,
          existingItems: const [],
        ),
        throwsA(
          isA<VaultImportException>().having(
            (error) => error.message,
            'message',
            contains('contrasena maestra'),
          ),
        ),
      );
    });

    test('a key-file-only database is rejected with a clear message',
        () async {
      await expectLater(
        const VaultImportParser().parseBytes(
          fileName: 'passwords.kdbx',
          bytes: keyFileBytes,
          existingItems: const [],
          keyFileBytes: kdbxFixtureKeyFile,
        ),
        throwsA(
          isA<VaultImportException>().having(
            (error) => error.message,
            'message',
            contains('archivo de llave'),
          ),
        ),
      );
    });

    test('a key file that does not match the database fails loudly', () async {
      await expectLater(
        const VaultImportParser().parseBytes(
          fileName: 'passwords.kdbx',
          bytes: keyFileBytes,
          existingItems: const [],
          masterPassword: kdbxFixturePassword,
          keyFileBytes: Uint8List.fromList(List<int>.filled(32, 0xFF)),
        ),
        throwsA(isA<VaultImportException>()),
      );
    });

    test('a corrupt file fails loudly instead of importing nothing', () async {
      final corrupt = Uint8List.fromList([
        0x03, 0xD9, 0xA2, 0x9A, // valid KeePass signature
        ...List<int>.filled(196, 0x00),
      ]);

      await expectLater(
        const VaultImportParser().parseBytes(
          fileName: 'corrupt.kdbx',
          bytes: corrupt,
          existingItems: const [],
          masterPassword: kdbxFixturePassword,
        ),
        throwsA(
          isA<VaultImportException>().having(
            (error) => error.message,
            'message',
            contains('danado'),
          ),
        ),
      );
    });

    test('detects a database by its signature when the name lies', () async {
      const parser = VaultImportParser();
      expect(parser.isKdbxFile(fileName: 'passwords.kdbx'), isTrue);
      expect(
        parser.isKdbxFile(fileName: 'export.csv', bytes: v4Bytes),
        isTrue,
      );
      expect(
        parser.isKdbxFile(fileName: 'export.csv', bytes: Uint8List(0)),
        isFalse,
      );

      final preview = await parser.parseBytes(
        fileName: 'export.csv',
        bytes: v4Bytes,
        existingItems: const [],
        masterPassword: kdbxFixturePassword,
      );
      expect(preview.source, VaultImportSource.kdbx);
      expect(preview.importableCount, 3);
    });

    test('skips entries the user deleted into the recycle bin', () async {
      final withBin = await buildKdbxFixture(withRecycleBin: true);

      final preview = await const VaultImportParser().parseBytes(
        fileName: 'passwords.kdbx',
        bytes: withBin,
        existingItems: const [],
        masterPassword: kdbxFixturePassword,
      );

      expect(preview.importableCount, 3);
      expect(
        preview.candidates.map((candidate) => candidate.item.title),
        isNot(contains('Borrada')),
      );
    });

    test('marks entries already in the vault as duplicates', () async {
      const existing = VaultItem(
        id: 'existing',
        title: 'GitLab',
        username: 'deploy@vaulta.app',
        secret: 'old',
        category: VaultCategory.work,
        strengthScore: 80,
        lastUpdatedLabel: 'Updated now',
        website: 'https://gitlab.com',
      );

      final preview = await const VaultImportParser().parseBytes(
        fileName: 'passwords.kdbx',
        bytes: v4Bytes,
        existingItems: const [existing],
        masterPassword: kdbxFixturePassword,
      );

      expect(preview.duplicateCount, 1);
      expect(preview.candidates.first.isDuplicate, isTrue);
      expect(preview.importableCount, 2);
    });

    test('the text parser refuses a .kdbx file instead of returning nothing',
        () {
      expect(
        () => const VaultImportParser().parse(
          fileName: 'passwords.kdbx',
          content: 'mojibake',
          existingItems: const [],
        ),
        throwsA(
          isA<VaultImportException>().having(
            (error) => error.message,
            'message',
            contains('contrasena maestra'),
          ),
        ),
      );
    });
  });

  group('VaultImportParser text formats through parseBytes', () {
    test('keeps CSV imports identical to the text parser', () async {
      const csv = 'title,username,password,url,category\n'
          'GitHub,leo@example.com,StrongPass!2026,https://github.com,Work';

      const parser = VaultImportParser();
      final fromText = parser.parse(
        fileName: 'passwords.csv',
        content: csv,
        existingItems: const [],
      );
      final fromBytes = await parser.parseBytes(
        fileName: 'passwords.csv',
        bytes: Uint8List.fromList(csv.codeUnits),
        existingItems: const [],
      );

      expect(fromBytes.source, VaultImportSource.genericCsv);
      expect(fromBytes.importableCount, fromText.importableCount);
      expect(fromBytes.candidates.single.item.title, 'GitHub');
      expect(fromBytes.candidates.single.item.category, VaultCategory.work);
    });

    test('keeps JSON imports identical to the text parser', () async {
      const json = '''
{
  "items": [
    {
      "name": "GitLab",
      "folder": "Infrastructure",
      "notes": "Deploy key",
      "login": {
        "username": "deploy@vaulta.app",
        "password": "Deploy!2026",
        "uris": [{"uri": "https://gitlab.com"}]
      }
    }
  ]
}
''';

      final preview = await const VaultImportParser().parseBytes(
        fileName: 'bitwarden_export.json',
        bytes: Uint8List.fromList(json.codeUnits),
        existingItems: const [],
      );

      expect(preview.source, VaultImportSource.bitwardenJson);
      expect(preview.importableCount, 1);
      expect(preview.candidates.single.item.title, 'GitLab');
      expect(preview.candidates.single.item.category, VaultCategory.infrastructure);
    });

    // Pins the regression surface of the shared parser: a KeePass CSV
    // export keeps the exact mapping it had before the `.kdbx` work.
    // Its "Account"/"Web Site" headers still do not match the app's
    // column aliases, so the row keeps its secret and falls back to the
    // generic title, which is pre-existing behaviour and not changed by
    // this feature.
    test('keeps the KeePass CSV export mapping unchanged', () async {
      const csv = '"Account","Login Name","Password","Web Site","Comments"\n'
          '"GitHub","leo@example.com","StrongPass!2026",'
          '"https://github.com","Token"';

      final preview = await const VaultImportParser().parseBytes(
        fileName: 'keepass_export.csv',
        bytes: Uint8List.fromList(csv.codeUnits),
        existingItems: const [],
      );

      expect(preview.source, VaultImportSource.keepassCsv);
      expect(preview.importableCount, 1);
      expect(preview.candidates.single.item.secret, 'StrongPass!2026');
      expect(preview.candidates.single.item.title, 'Entrada importada');
    });
  });
}
