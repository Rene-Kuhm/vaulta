import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/features/backup/domain/vault_clear_text_export.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

import '../backup_test_support.dart';

/// Minimal RFC 4180 reader: returns one record per list of fields, so a
/// test can prove the writer produced a parseable file (a naive join
/// would not survive this).
List<List<String>> parseCsv(String source) {
  final records = <List<String>>[];
  var fields = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  var index = 0;

  while (index < source.length) {
    final char = source[index];
    if (quoted) {
      if (char == '"') {
        if (index + 1 < source.length && source[index + 1] == '"') {
          buffer.write('"');
          index += 2;
          continue;
        }
        quoted = false;
        index++;
        continue;
      }
      buffer.write(char);
      index++;
      continue;
    }
    if (char == '"') {
      quoted = true;
      index++;
      continue;
    }
    if (char == ',') {
      fields.add(buffer.toString());
      buffer.clear();
      index++;
      continue;
    }
    if (char == '\r' &&
        index + 1 < source.length &&
        source[index + 1] == '\n') {
      fields.add(buffer.toString());
      buffer.clear();
      records.add(fields);
      fields = <String>[];
      index += 2;
      continue;
    }
    buffer.write(char);
    index++;
  }
  if (buffer.isNotEmpty || fields.isNotEmpty) {
    fields.add(buffer.toString());
    records.add(fields);
  }
  return records;
}

void main() {
  const exporter = VaultClearTextExporter();
  final exportedAt = DateTime.utc(2026, 10, 21, 9, 15);

  /// Builds an item with every field set, including the awkward values
  /// a real vault contains.
  VaultItem richItem() => VaultItem(
    id: '9f6c2b1e-4a3d-4f5e-8a7b-0c1d2e3f4a5b',
    title: 'Bank "Premium", S.A.',
    username: 'rene@example.com',
    secret: 'p,a"s s\\word',
    category: VaultCategory.finance,
    strengthScore: 74,
    lastUpdatedLabel: 'Updated 3 days ago',
    website: 'https://bank.example.com/login?a=1&b=2',
    notes: 'Call center:\n+54 11 5555-1234\nRecovery code: A1-B2',
    updatedAt: DateTime.utc(2026, 10, 1, 18, 42, 7),
  );

  group('CSV export', () {
    test('keeps every field of a value that needs quoting', () {
      final records = parseCsv(exporter.csv([richItem()]));

      expect(records[0], [
        'title',
        'username',
        'password',
        'url',
        'notes',
        'category',
        'updated_at',
      ]);
      expect(records[1][3], 'https://bank.example.com/login?a=1&b=2');
      expect(records[1][4], richItem().notes);
      expect(records[1][5], 'finance');
    });

    test('writes a header and one escaped row per item', () {
      final csv = exporter.csv([
        testItem(
          id: 'a',
          title: 'GitHub',
          username: 'octocat',
          secret: 'gh-Secret!123',
          website: 'github.com',
          notes: 'work account',
          category: VaultCategory.work,
        ),
      ]);

      final lines = csv.split('\r\n');
      expect(
        lines.first,
        'title,username,password,url,notes,category,updated_at',
      );
      expect(
        lines[1],
        'GitHub,octocat,gh-Secret!123,github.com,work account,work,'
        '2026-10-01T00:00:00.000Z',
      );
      // RFC 4180 records are CRLF-terminated.
      expect(csv.endsWith('\r\n'), isTrue);
    });

    test('quotes fields containing a comma and doubles embedded quotes', () {
      final csv = exporter.csv([
        testItem(id: 'a', title: 'GitHub', secret: 'pa,ss"word'),
      ]);

      expect(csv, contains('"pa,ss""word"'));
      // The naive join would have broken the record into two fields.
      final records = parseCsv(csv);
      expect(records[1], hasLength(7));
      expect(records[1][2], 'pa,ss"word');
    });

    test('quotes fields containing a newline and keeps them intact', () {
      final csv = exporter.csv([richItem()]);

      expect(
        csv,
        contains('"Call center:\n+54 11 5555-1234\nRecovery code: A1-B2"'),
      );
      // Everything the user typed survives, including the empty-safe
      // surrounding quotes that make the record parseable.
      expect(csv, contains('"Bank ""Premium"", S.A."'));
    });

    test('does not quote values that need no quoting', () {
      expect(
        VaultClearTextExporter.escapeCsvField('plain value'),
        'plain value',
      );
      expect(
        VaultClearTextExporter.escapeCsvField('comma, inside'),
        '"comma, inside"',
      );
      expect(
        VaultClearTextExporter.escapeCsvField('quote " inside'),
        '"quote "" inside"',
      );
      expect(VaultClearTextExporter.escapeCsvField(''), '');
    });

    test('writes empty columns for missing optional fields', () {
      final csv = exporter.csv([testItem(id: 'a', title: 'Mail')]);
      // testItem always sets updatedAt, but website and notes are null.
      expect(
        csv.split('\r\n')[1],
        'Mail,rene@example.com,S3cret!value,,,'
        'personal,2026-10-01T00:00:00.000Z',
      );
    });
  });

  group('JSON export', () {
    test('round-trips every VaultItem field without loss', () {
      final items = [
        richItem(),
        testItem(id: 'b', title: 'Mail', secret: 'M4il!Secret'),
      ];

      final payload = exporter.json(
        items,
        exportedAt: exportedAt,
        appVersion: '1.0.21+22',
      );
      final decoded = jsonDecode(payload) as Map<String, dynamic>;

      expect(decoded['format'], VaultClearTextExporter.formatName);
      expect(decoded['version'], VaultClearTextExporter.currentVersion);
      expect(decoded['app_version'], '1.0.21+22');
      expect(decoded['exported_at'], exportedAt.toIso8601String());
      expect(decoded['item_count'], 2);

      final maps = (decoded['items'] as List).cast<Map<String, dynamic>>();
      expect(maps, hasLength(2));
      for (var index = 0; index < items.length; index++) {
        final restored = VaultItem.fromJson(maps[index]);
        final original = items[index];
        expect(restored.id, original.id);
        expect(restored.title, original.title);
        expect(restored.username, original.username);
        expect(restored.secret, original.secret);
        expect(restored.category, original.category);
        expect(restored.strengthScore, original.strengthScore);
        expect(restored.lastUpdatedLabel, original.lastUpdatedLabel);
        expect(restored.website, original.website);
        expect(restored.notes, original.notes);
        expect(restored.updatedAt, original.updatedAt);
      }
    });

    test('keeps null optionals null instead of inventing values', () {
      final payload = exporter.json(
        [testItem(id: 'a', title: 'Mail')],
        exportedAt: exportedAt,
        appVersion: '1.0.21+22',
      );
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      final items = decoded['items'] as List<dynamic>;
      final item = items.first as Map<String, dynamic>;
      expect(item['website'], isNull);
      expect(item['notes'], isNull);
    });
  });

  group('file names', () {
    test('uses the format extension and a sortable timestamp', () {
      final now = DateTime.utc(2026, 10, 21, 9, 5);
      expect(
        vaultClearTextFileName(now, VaultClearTextFormat.csv),
        endsWith('.csv'),
      );
      expect(
        vaultClearTextFileName(now, VaultClearTextFormat.json),
        endsWith('.json'),
      );
      expect(
        vaultClearTextFileName(now, VaultClearTextFormat.csv),
        contains('20261021'),
      );
    });
  });
}
