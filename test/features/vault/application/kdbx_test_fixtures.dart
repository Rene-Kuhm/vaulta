// ignore_for_file: implementation_imports

// The public `kdbx` API does not export `KdbxHeader`, and creating a
// KDBX 3.1 fixture needs `KdbxHeader.createV3()`. Nothing under lib/
// imports implementation paths; only this fixture builder does, so the
// v3.1 branch of the importer is exercised against a real database
// written by the same library instead of a hand-rolled binary.
//
// The same builder is used by the parser tests and by the import screen
// flow test, so both prove the round trip against real KeePass bytes.

import 'dart:typed_data';

import 'package:kdbx/kdbx.dart';
import 'package:kdbx/src/kdbx_header.dart';

/// Master password of every fixture database.
const kdbxFixturePassword = 'VaultaMaster!2026';

/// Key file bytes for the password-plus-key-file fixtures.
///
/// Starts with `0xFF`, which is not valid UTF-8, so the package treats
/// the bytes as an opaque key file and hashes them instead of trying to
/// read them as hex or XML.
final kdbxFixtureKeyFile = Uint8List.fromList(
  List<int>.generate(32, (index) => 0xFF - index),
);

/// Builds a real KeePass database with the `kdbx` package so the
/// importer is tested against the exact bytes the library writes.
///
/// The layout mirrors a typical database: a `Work` group with two
/// entries (one of them without a password) and a `Family` group whose
/// name matches none of the app's categories.
Future<Uint8List> buildKdbxFixture({
  String password = kdbxFixturePassword,
  Uint8List? keyFileBytes,
  bool v3 = false,
  bool withRecycleBin = false,
}) async {
  final file = KdbxFormat().create(
    Credentials.composite(ProtectedValue.fromString(password), keyFileBytes),
    'Vaulta Import Test',
    header: v3 ? KdbxHeader.createV3() : null,
  );
  final root = file.body.rootGroup;

  final work = KdbxGroup.create(ctx: file.ctx, parent: root, name: 'Work');
  root.addGroup(work);

  final gitLab = KdbxEntry.create(file, work);
  work.addEntry(gitLab);
  gitLab.setString(KdbxKeyCommon.TITLE, PlainValue('GitLab'));
  gitLab.setString(KdbxKeyCommon.USER_NAME, PlainValue('deploy@vaulta.app'));
  gitLab.setString(
    KdbxKeyCommon.PASSWORD,
    ProtectedValue.fromString('Deploy!2026'),
  );
  gitLab.setString(KdbxKeyCommon.URL, PlainValue('https://gitlab.com'));
  gitLab.setString(KdbxKey('Notes'), PlainValue('Deploy key'));

  final recovery = KdbxEntry.create(file, work);
  work.addEntry(recovery);
  recovery.setString(KdbxKeyCommon.TITLE, PlainValue('Recovery codes'));
  recovery.setString(KdbxKeyCommon.USER_NAME, PlainValue('leo@vaulta.app'));
  recovery.setString(KdbxKey('Notes'), PlainValue('Impresos en la caja fuerte'));

  final family = KdbxGroup.create(ctx: file.ctx, parent: root, name: 'Family');
  root.addGroup(family);

  final netflix = KdbxEntry.create(file, family);
  family.addEntry(netflix);
  netflix.setString(KdbxKeyCommon.TITLE, PlainValue('Netflix'));
  netflix.setString(KdbxKeyCommon.USER_NAME, PlainValue('leo@vaulta.app'));
  netflix.setString(
    KdbxKeyCommon.PASSWORD,
    ProtectedValue.fromString('Series!2026'),
  );

  if (withRecycleBin) {
    // KeePass keeps deleted entries in a group referenced from the
    // metadata; a real database has one and the importer must not
    // resurrect what the user deleted.
    final bin = KdbxGroup.create(ctx: file.ctx, parent: root, name: 'Recycle Bin');
    root.addGroup(bin);
    final deleted = KdbxEntry.create(file, bin);
    bin.addEntry(deleted);
    deleted.setString(KdbxKeyCommon.TITLE, PlainValue('Borrada'));
    deleted.setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString('Deleted!2026'),
    );
    file.body.meta.recycleBinUUID.set(bin.uuid);
  }

  return file.save();
}
