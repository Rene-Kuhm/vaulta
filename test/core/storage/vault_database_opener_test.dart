import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:gestor_contrasenas/core/storage/vault_database_opener.dart';
import 'package:gestor_contrasenas/core/storage/vault_schema.dart';

/// ADR-007 gates that can be proven without the app: the file really is
/// encrypted, the pragma order is the one the spike found, and a wrong key or a
/// wrong order fails loudly instead of looking like an empty vault.
void main() {
  late Directory dir;
  late String path;
  late Uint8List key;

  const secretTitle = 'Banco Galicia - TITULO-SECRETO-123';
  const secretPayload = <int>[1, 2, 3, 4, 5, 6, 7, 8];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('vault_db_test');
    path = '${dir.path}/vault.db';
    final derived = await deriveVaultDatabaseKey(
      dek: SecretKey(List<int>.generate(32, (i) => i + 1)),
      salt: List<int>.filled(16, 7),
    );
    key = Uint8List.fromList(await derived.extractBytes());
  });

  tearDown(() => dir.deleteSync(recursive: true));

  List<int> readAll(String suffix) {
    final file = File('$path$suffix');
    return file.existsSync() ? file.readAsBytesSync() : <int>[];
  }

  bool containsBytes(List<int> haystack, List<int> needle) {
    if (needle.isEmpty || haystack.length < needle.length) return false;
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      var hit = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }

  test('creates the schema and records the version', () {
    final db = openVaultDatabase(path: path, key: key);
    ensureVaultSchema(db);
    expect(readVaultSchemaVersion(db), vaultStorageSchemaVersion);

    // Idempotent: running it again changes nothing.
    ensureVaultSchema(db);
    expect(readVaultSchemaVersion(db), vaultStorageSchemaVersion);
    db.close();
  });

  test('STRICT rejects a value that does not match the declared type', () {
    final db = openVaultDatabase(path: path, key: key);
    ensureVaultSchema(db);
    expect(
      () => db.execute(
        'INSERT INTO vault_items '
        '(record_id, key_id, key_version, payload, title_ct, category, updated_at) '
        "VALUES ('r1', 'k1', 'not-an-integer', x'00', x'00', 'work', 0)",
      ),
      throwsA(isA<SqliteException>()),
    );
    db.close();
  });

  test('an open database leaks no clear text in .db, -wal or -shm', () {
    final db = openVaultDatabase(path: path, key: key);
    ensureVaultSchema(db);
    db.execute(
      'INSERT INTO vault_items '
      '(record_id, key_id, key_version, payload, title_ct, category, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        'r1',
        'k1',
        4,
        Uint8List.fromList(secretPayload),
        Uint8List.fromList(secretTitle.codeUnits),
        'work',
        1700000000,
      ],
    );

    // Read while the connection is still open: this is the case the spike could
    // not cover, because it closed the database before scanning.
    final titleBytes = secretTitle.codeUnits;
    for (final suffix in ['', '-wal', '-shm']) {
      expect(
        containsBytes(readAll(suffix), titleBytes),
        isFalse,
        reason: 'the title appeared in clear in the $suffix file',
      );
    }
    db.close();
  });

  test('opening without the key fails instead of returning nothing', () {
    final db = openVaultDatabase(path: path, key: key);
    ensureVaultSchema(db);
    db.execute(
      'INSERT INTO vault_items '
      '(record_id, key_id, key_version, payload, title_ct, category, updated_at) '
      "VALUES ('r1', 'k1', 4, x'00', x'00', 'work', 0)",
    );
    db.close();

    final wrong = sqlite3.open(path);
    expect(
      () => wrong.select('SELECT count(*) FROM vault_items'),
      throwsA(isA<SqliteException>()),
    );
    wrong.close();
  });

  test('a key that differs by one byte cannot read the vault', () {
    final db = openVaultDatabase(path: path, key: key);
    ensureVaultSchema(db);
    db.execute(
      'INSERT INTO vault_items '
      '(record_id, key_id, key_version, payload, title_ct, category, updated_at) '
      "VALUES ('r1', 'k1', 4, x'00', x'00', 'work', 0)",
    );
    db.close();

    final tampered = Uint8List.fromList(key)..[0] ^= 0x01;
    expect(
      () {
        final db = openVaultDatabase(path: path, key: tampered);
        try {
          db.select('SELECT count(*) FROM vault_items');
        } finally {
          db.close();
        }
      },
      throwsA(isA<SqliteException>()),
    );
  });

  test('a schema version this build does not know is refused', () {
    final db = openVaultDatabase(path: path, key: key);
    ensureVaultSchema(db);
    db.execute(
      'UPDATE vault_meta SET value = ? WHERE key = ?',
      ['99', metaSchemaVersionKey],
    );
    expect(() => ensureVaultSchema(db), throwsA(isA<StateError>()));
    db.close();
  });

  test('the round trip reads back exactly what was written', () {
    final db = openVaultDatabase(path: path, key: key);
    ensureVaultSchema(db);
    db.execute(
      'INSERT INTO vault_items '
      '(record_id, key_id, key_version, payload, title_ct, category, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        'record-1',
        'key-1',
        4,
        Uint8List.fromList(secretPayload),
        Uint8List.fromList([9, 9, 9]),
        'finance',
        1700000001,
      ],
    );
    db.execute(
      'INSERT INTO vault_hosts (record_id, host) VALUES (?, ?)',
      ['record-1', 'banco.example'],
    );
    db.close();

    final reopened = openVaultDatabase(path: path, key: key);
    final rows = reopened.select('SELECT * FROM vault_items');
    expect(rows, hasLength(1));
    expect(rows.first['record_id'], 'record-1');
    expect(rows.first['payload'], secretPayload);
    expect(rows.first['category'], 'finance');
    final hosts = reopened.select('SELECT host FROM vault_hosts');
    expect(hosts.first['host'], 'banco.example');
    reopened.close();
  });
}
