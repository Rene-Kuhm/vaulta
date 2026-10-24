import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_security_message.dart';
import 'package:gestor_contrasenas/features/security/presentation/vault_security_message_l10n.dart';
import 'package:gestor_contrasenas/l10n/app_localizations_en.dart';
import 'package:gestor_contrasenas/l10n/app_localizations_es.dart';

/// Reads a locale file the way `flutter gen-l10n` does: JSON of key -> text,
/// with `@key` entries holding metadata.
Map<String, String> loadArb(String path) {
  final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final entry in raw.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value as String,
  };
}

/// Words that are the same in both languages in this app's vocabulary, so an
/// identical sentence that only uses them is not a missing translation.
const _sharedWords = {'vault', 'vaulta', 'master', 'password', 'auto', 'lock'};

void main() {
  final enArb = loadArb('lib/l10n/app_en.arb');
  final esArb = loadArb('lib/l10n/app_es.arb');

  test('every message code has copy in English and in Spanish', () {
    // The failure this guards against is silent: `flutter gen-l10n` fills a
    // missing translation from the template locale, so a new code without
    // Spanish copy compiles, ships, and reads English to a Spanish user.
    final missing = <String>[];
    for (final code in VaultSecurityMessageCode.values) {
      final key = vaultSecurityMessageArbKey(code);
      if (!enArb.containsKey(key)) {
        missing.add('app_en.arb -> $key');
      }
      if (!esArb.containsKey(key)) {
        missing.add('app_es.arb -> $key');
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'add the missing ARB keys, or drop the code from '
          'VaultSecurityMessageCode',
    );
  });

  test('the Spanish copy is translated, not the English text copied over', () {
    final suspicious = <String>[];
    for (final code in VaultSecurityMessageCode.values) {
      final key = vaultSecurityMessageArbKey(code);
      final en = enArb[key];
      final es = esArb[key];
      if (en == null || es == null || en != es) {
        continue;
      }
      // Identical is only fine when the text carries no translatable word
      // (a bare `{reason}` template, for example).
      final words = en
          .toLowerCase()
          .split(RegExp('[^a-z]+'))
          .where((word) => word.isNotEmpty)
          .toSet();
      if (words.difference(_sharedWords).isNotEmpty) {
        suspicious.add(key);
      }
    }

    expect(suspicious, isEmpty);
  });

  test('every message code resolves in both locales', () {
    final en = AppLocalizationsEn();
    final es = AppLocalizationsEs();

    for (final code in VaultSecurityMessageCode.values) {
      final message = VaultSecurityMessage(code, detail: 'X');
      expect(
        vaultSecurityMessageText(en, message),
        isNotEmpty,
        reason: '$code has no English text',
      );
      expect(
        vaultSecurityMessageText(es, message),
        isNotEmpty,
        reason: '$code has no Spanish text',
      );
    }
  });

  test('a code is enough for a translated sentence the user can act on', () {
    final en = AppLocalizationsEn();
    final es = AppLocalizationsEs();
    const cannotOpen = VaultSecurityMessage(
      VaultSecurityMessageCode.vaultCannotBeOpened,
    );

    expect(
      vaultSecurityMessageText(en, cannotOpen),
      contains('cannot be opened'),
    );
    expect(
      vaultSecurityMessageText(es, cannotOpen),
      contains('no se puede abrir'),
    );
  });

  test('the ARB key follows the enum name by convention', () {
    expect(
      vaultSecurityMessageArbKey(VaultSecurityMessageCode.vaultLocked),
      'securityMessageVaultLocked',
    );
    expect(
      vaultSecurityMessageArbKey(VaultSecurityMessageCode.vaultCannotBeOpened),
      'securityMessageVaultCannotBeOpened',
    );
  });
}
