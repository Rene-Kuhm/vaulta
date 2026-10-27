import 'dart:convert';
import 'dart:typed_data';

import 'package:kdbx/kdbx.dart';
import 'package:uuid/uuid.dart';

import '../domain/vault_item.dart';
import 'vault_duplicate_detector.dart';
import 'vault_import_models.dart';

/// Parses password-manager export files (CSV or JSON) from several
/// common vendors and produces a [VaultImportPreview] the UI can
/// display for user confirmation.
///
/// Detection of the source format is best-effort: the parser uses
/// file name hints (for example, "bitwarden") and content shape
/// (JSON object/array vs CSV). The constructor accepts injectable
/// dependencies so tests can pin a deterministic [Uuid] and a
/// custom [VaultDuplicateDetector].
/// Parses password-manager export files (CSV or JSON) from several
/// common vendors and produces a [VaultImportPreview] the UI can
/// display for user confirmation.
///
/// Detection of the source format is best-effort: the parser uses
/// file name hints (for example, "bitwarden") and content shape
/// (JSON object/array vs CSV). The constructor accepts injectable
/// dependencies so tests can pin a deterministic [Uuid] and a
/// custom [VaultDuplicateDetector].
class VaultImportParser {
  /// Builds a parser. [uuid] defaults to a real [Uuid] and
  /// [duplicates] defaults to a stock [VaultDuplicateDetector].
  /// Tests pass deterministic versions of both.
  const VaultImportParser({Uuid? uuid, VaultDuplicateDetector? duplicates})
    : _uuid = uuid ?? const Uuid(),
      _duplicates = duplicates ?? const VaultDuplicateDetector();

  final Uuid _uuid;
  final VaultDuplicateDetector _duplicates;

  static const _kdbxExtension = '.kdbx';

  /// First four bytes of every KeePass 1.x/2.x database
  /// (`0x9AA2D903` little-endian). Enough to recognise a `.kdbx` file
  /// whose name was changed on the way to the picker.
  static const _kdbxMagic = <int>[0x03, 0xD9, 0xA2, 0x9A];

  /// Separator used to join the KeePass group hierarchy into a single
  /// path, matching how the import screen shows folders.
  static const _kdbxGroupSeparator = ' / ';

  /// Standard KeePass field holding an entry's free-form notes.
  static final _kdbxNotesKey = KdbxKey('Notes');

  static const _kdbxNeedsPasswordMessage =
      'Este archivo .kdbx esta protegido con una contrasena maestra. '
      'Escribila para poder importarlo.';
  static const _kdbxKeyFileOnlyMessage =
      'Las bases .kdbx que solo abren con archivo de llave todavia no se '
      'pueden importar. Agrega tambien la contrasena maestra del archivo.';
  static const _kdbxWrongCredentialsMessage =
      'La contrasena maestra o el archivo de llave no coinciden con esta base '
      '.kdbx. Revisalos y proba de nuevo.';
  static const _kdbxCorruptMessage =
      'No pudimos abrir el archivo .kdbx: esta danado o no es una base '
      'KeePass valida.';

  /// Parses [content] as a [fileName]-keyed export.
  ///
  /// Steps:
  /// 1. Detect the [VaultImportSource] from the file name and the
  ///    first non-whitespace character of the content.
  /// 2. Parse the body (CSV or JSON).
  /// 3. For each parsed candidate, ask the duplicate detector
  ///    whether it conflicts with any entry in [existingItems] or
  ///    with a previously-accepted candidate in the same preview.
  ///
  /// Returns a [VaultImportPreview] the UI can summarize.
  ///
  /// Throws a [VaultImportException] when [fileName] is a KeePass
  /// `.kdbx` database: that format is encrypted binary and must go
  /// through [parseBytes] with a master password instead of being
  /// decoded as text, so the call fails loudly instead of producing
  /// an empty preview.
  VaultImportPreview parse({
    required String fileName,
    required String content,
    required List<VaultItem> existingItems,
  }) {
    if (fileName.toLowerCase().endsWith(_kdbxExtension)) {
      throw const VaultImportException(_kdbxNeedsPasswordMessage);
    }
    final trimmed = content.trimLeft();
    final source = _detectSource(fileName, trimmed);
    final parsed =
        source == VaultImportSource.json ||
            source == VaultImportSource.bitwardenJson
        ? _parseJson(trimmed, source)
        : _parseCsv(content, source);

    return _withDuplicateDetection(parsed, existingItems);
  }

  /// Parses a picked file from its raw [bytes].
  ///
  /// This is the entry point the import screen uses: a KeePass
  /// `.kdbx` database is encrypted binary, so it cannot travel through
  /// [parse] as text. Every other format keeps the exact behaviour of
  /// [parse]: the bytes are decoded as UTF-8 and handed to the CSV or
  /// JSON parser unchanged.
  ///
  /// [masterPassword] and [keyFileBytes] are only used for `.kdbx`
  /// files. They are consumed in memory to derive the database key and
  /// are never persisted or logged. A missing password, a wrong
  /// password, an unsupported key combination, or a corrupt file
  /// throws a [VaultImportException] with user-facing copy.
  Future<VaultImportPreview> parseBytes({
    required String fileName,
    required Uint8List bytes,
    required List<VaultItem> existingItems,
    String? masterPassword,
    Uint8List? keyFileBytes,
  }) {
    if (isKdbxFile(fileName: fileName, bytes: bytes)) {
      return _parseKdbx(
        bytes: bytes,
        existingItems: existingItems,
        masterPassword: masterPassword,
        keyFileBytes: keyFileBytes,
      );
    }
    return Future<VaultImportPreview>.value(
      parse(
        fileName: fileName,
        content: utf8.decode(bytes, allowMalformed: true),
        existingItems: existingItems,
      ),
    );
  }

  /// `true` when [fileName] or the first bytes of [bytes] identify a
  /// KeePass `.kdbx` database, so the UI knows it has to ask for a
  /// master password before parsing.
  bool isKdbxFile({required String fileName, Uint8List? bytes}) {
    if (fileName.toLowerCase().endsWith(_kdbxExtension)) return true;
    if (bytes == null || bytes.length < _kdbxMagic.length) return false;
    for (var index = 0; index < _kdbxMagic.length; index++) {
      if (bytes[index] != _kdbxMagic[index]) return false;
    }
    return true;
  }

  VaultImportPreview _withDuplicateDetection(
    VaultImportPreview parsed,
    List<VaultItem> existingItems,
  ) {
    final candidates = <VaultImportCandidate>[];
    final knownItems = List<VaultItem>.of(existingItems);

    for (final candidate in parsed.candidates) {
      final match = _duplicates.findDuplicate(candidate.item, knownItems);
      if (match == null) {
        candidates.add(candidate);
        knownItems.add(candidate.item);
      } else {
        candidates.add(
          candidate.copyWith(isDuplicate: true, duplicateReason: match.reason),
        );
      }
    }

    return VaultImportPreview(
      source: parsed.source,
      candidates: candidates,
      rejected: parsed.rejected,
    );
  }

  Future<VaultImportPreview> _parseKdbx({
    required Uint8List bytes,
    required List<VaultItem> existingItems,
    String? masterPassword,
    Uint8List? keyFileBytes,
  }) async {
    final password = masterPassword ?? '';
    final hasKeyFile = keyFileBytes != null && keyFileBytes.isNotEmpty;
    if (password.isEmpty) {
      throw VaultImportException(
        hasKeyFile ? _kdbxKeyFileOnlyMessage : _kdbxNeedsPasswordMessage,
      );
    }

    final KdbxFile file;
    try {
      file = await KdbxFormat().read(
        bytes,
        Credentials.composite(
          ProtectedValue.fromString(password),
          hasKeyFile ? keyFileBytes : null,
        ),
      );
    } on KdbxInvalidKeyException {
      throw const VaultImportException(_kdbxWrongCredentialsMessage);
    } on KdbxException {
      throw const VaultImportException(_kdbxCorruptMessage);
    } catch (_) {
      // The package surfaces malformed input as plain errors from its
      // binary readers too, so anything else is treated as corruption.
      throw const VaultImportException(_kdbxCorruptMessage);
    }

    final candidates = <VaultImportCandidate>[];
    final rejected = <VaultImportIssue>[];
    final now = DateTime.now();
    var row = 0;

    void visit(KdbxGroup group, List<String> path) {
      for (final entry in group.entries) {
        if (entry.isInRecycleBin()) continue;
        row++;
        final candidate = _kdbxCandidate(
          entry: entry,
          groupPath: path.join(_kdbxGroupSeparator),
          rowNumber: row,
          now: now,
        );
        if (candidate == null) {
          rejected.add(
            VaultImportIssue(
              row: row,
              severity: VaultImportIssueSeverity.error,
              message: 'La entrada de KeePass no tiene datos para importar.',
            ),
          );
        } else {
          candidates.add(candidate);
        }
      }
      for (final child in group.groups) {
        visit(child, [...path, child.name.get()?.trim() ?? '']);
      }
    }

    visit(file.body.rootGroup, const []);

    return _withDuplicateDetection(
      VaultImportPreview(
        source: VaultImportSource.kdbx,
        candidates: candidates,
        rejected: rejected,
      ),
      existingItems,
    );
  }

  VaultImportCandidate? _kdbxCandidate({
    required KdbxEntry entry,
    required String groupPath,
    required int rowNumber,
    required DateTime now,
  }) {
    String read(KdbxKey key) {
      final value = entry.getString(key)?.getText()?.trim();
      return value ?? '';
    }

    final title = read(KdbxKeyCommon.TITLE);
    final username = read(KdbxKeyCommon.USER_NAME);
    // KeePass allows entries without a password (notes, TOTP-only,
    // recovery codes): they are valid and must survive the import.
    final secret = read(KdbxKeyCommon.PASSWORD);
    final website = read(KdbxKeyCommon.URL);
    final notes = read(_kdbxNotesKey);

    if (title.isEmpty &&
        username.isEmpty &&
        secret.isEmpty &&
        website.isEmpty &&
        notes.isEmpty) {
      return null;
    }

    final issues = <VaultImportIssue>[];
    // The group path is the closest thing KeePass has to a category.
    // When it does not map to one of ours it stays visible inside the
    // title so the user does not lose where the entry came from.
    final category = _categoryOrNull(groupPath);
    var displayTitle = title.isNotEmpty
        ? title
        : (website.isNotEmpty
              ? website
              : (username.isNotEmpty ? username : 'Entrada importada'));
    if (title.isEmpty) {
      issues.add(
        const VaultImportIssue(
          severity: VaultImportIssueSeverity.warning,
          message: 'No habia titulo; Vaulta uso el sitio o usuario.',
        ),
      );
    }
    if (category == null && groupPath.isNotEmpty) {
      displayTitle = '$displayTitle ($groupPath)';
    }

    return VaultImportCandidate(
      item: VaultItem(
        id: _uuid.v4(),
        title: displayTitle,
        username: username,
        secret: secret,
        category: category ?? VaultCategory.personal,
        strengthScore: estimatePasswordStrength(secret),
        lastUpdatedLabel: formatVaultUpdatedLabel(now),
        website: website.isEmpty ? null : website,
        notes: notes.isEmpty ? null : notes,
        updatedAt: now,
      ),
      source: VaultImportSource.kdbx,
      row: rowNumber,
      issues: issues,
    );
  }

  VaultImportSource _detectSource(String fileName, String content) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.json') ||
        content.startsWith('{') ||
        content.startsWith('[')) {
      return lower.contains('bitwarden')
          ? VaultImportSource.bitwardenJson
          : VaultImportSource.json;
    }
    if (lower.contains('notion')) return VaultImportSource.notionCsv;
    if (lower.contains('chrome')) return VaultImportSource.chromeCsv;
    if (lower.contains('bitwarden')) return VaultImportSource.bitwardenCsv;
    if (lower.contains('1password') || lower.contains('onepassword')) {
      return VaultImportSource.onePasswordCsv;
    }
    if (lower.contains('lastpass')) return VaultImportSource.lastPassCsv;
    if (lower.contains('keepass')) return VaultImportSource.keepassCsv;
    return VaultImportSource.genericCsv;
  }

  VaultImportPreview _parseCsv(String content, VaultImportSource source) {
    final rows = _readCsvRows(content);
    if (rows.isEmpty) {
      return VaultImportPreview(
        source: source,
        candidates: const [],
        rejected: const [
          VaultImportIssue(
            message: 'El archivo CSV esta vacio.',
            severity: VaultImportIssueSeverity.error,
          ),
        ],
      );
    }

    final header = rows.first.map(_normalizeHeader).toList(growable: false);
    final candidates = <VaultImportCandidate>[];
    final rejected = <VaultImportIssue>[];

    for (var index = 1; index < rows.length; index++) {
      final rawRow = rows[index];
      if (rawRow.every((cell) => cell.trim().isEmpty)) continue;
      final row = <String, String>{};
      for (var col = 0; col < header.length; col++) {
        row[header[col]] = col < rawRow.length ? rawRow[col].trim() : '';
      }
      final candidate = _candidateFromMap(
        row: row,
        source: source,
        rowNumber: index + 1,
      );
      if (candidate == null) {
        rejected.add(
          VaultImportIssue(
            row: index + 1,
            severity: VaultImportIssueSeverity.error,
            message: 'La fila no tiene titulo ni password reconocible.',
          ),
        );
      } else {
        candidates.add(candidate);
      }
    }

    return VaultImportPreview(
      source: source,
      candidates: candidates,
      rejected: rejected,
    );
  }

  VaultImportPreview _parseJson(String content, VaultImportSource source) {
    final candidates = <VaultImportCandidate>[];
    final rejected = <VaultImportIssue>[];
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } catch (error) {
      return VaultImportPreview(
        source: source,
        candidates: const [],
        rejected: [
          VaultImportIssue(
            severity: VaultImportIssueSeverity.error,
            message: 'No pudimos leer el JSON: $error',
          ),
        ],
      );
    }

    final records = _extractJsonRecords(decoded);
    for (var index = 0; index < records.length; index++) {
      final candidate = _candidateFromMap(
        row: records[index].map(
          (key, value) => MapEntry(_normalizeHeader(key), '$value'.trim()),
        ),
        source: source,
        rowNumber: index + 1,
      );
      if (candidate == null) {
        rejected.add(
          VaultImportIssue(
            row: index + 1,
            severity: VaultImportIssueSeverity.error,
            message: 'El registro JSON no tiene credenciales reconocibles.',
          ),
        );
      } else {
        candidates.add(candidate);
      }
    }

    return VaultImportPreview(
      source: source,
      candidates: candidates,
      rejected: rejected,
    );
  }

  List<Map<String, Object?>> _extractJsonRecords(Object? decoded) {
    if (decoded is List) {
      return decoded.whereType<Map>().map(_mapFromDynamic).toList();
    }
    if (decoded is Map) {
      final map = _mapFromDynamic(decoded);
      final items = map['items'] ?? map['entries'] ?? map['logins'];
      if (items is List) {
        return items.whereType<Map>().map((entry) {
          final result = _mapFromDynamic(entry);
          final login = result['login'];
          if (login is Map) {
            final loginMap = _mapFromDynamic(login);
            result.addAll(loginMap);
            final uris = loginMap['uris'];
            if (uris is List && uris.isNotEmpty) {
              final firstUri = uris.first;
              if (firstUri is Map && firstUri['uri'] != null) {
                result['uri'] = firstUri['uri'];
              }
            }
          }
          return result;
        }).toList();
      }
      return [map];
    }
    return const [];
  }

  Map<String, Object?> _mapFromDynamic(Map<dynamic, dynamic> map) {
    return map.map((key, value) => MapEntry('$key', value));
  }

  VaultImportCandidate? _candidateFromMap({
    required Map<String, String> row,
    required VaultImportSource source,
    required int rowNumber,
  }) {
    final title = _first(row, const [
      'title',
      'name',
      'nombre',
      'service',
      'servicio',
      'site',
      'sitio',
      'login_uri',
      'url',
    ]);
    final secret = _first(row, const [
      'password',
      'login_password',
      'login.password',
      'loginpassword',
      'password_value',
      'passwordvalue',
      'secret',
      'contrasena',
      'contraseña',
      'pass',
      'clave',
    ]);
    final username = _first(row, const [
      'username',
      'login_username',
      'login.username',
      'loginusername',
      'login_user',
      'login.user',
      'login_email',
      'login.email',
      'user',
      'email',
      'login',
      'usuario',
      'usuario_o_email',
      'user_name',
    ]);
    final website = _first(row, const [
      'url',
      'website',
      'uri',
      'login_uri',
      'login.uri',
      'loginurl',
      'login_url',
      'login.url',
      'sitio',
      'web',
    ]);
    final notes = _first(row, const [
      'notes',
      'note',
      'notas',
      'nota',
      'extra',
      'comments',
      'comentarios',
    ]);
    final categoryValue = _first(row, const [
      'category',
      'folder',
      'collection',
      'categoria',
      'categoría',
      'type',
    ]);
    // Bitwarden JSON exports carry `favorite`; the CSV paths simply have
    // no such column, which reads as an empty string and therefore as
    // "not a favorite".
    final favoriteValue = _first(row, const [
      'favorite',
      'favourite',
      'fav',
      'favorito',
      'favorita',
    ]);

    if (title.isEmpty && secret.isEmpty) return null;

    final issues = <VaultImportIssue>[];
    if (secret.isEmpty) {
      issues.add(
        const VaultImportIssue(
          severity: VaultImportIssueSeverity.error,
          message: 'Falta el password o secreto.',
        ),
      );
    }
    if (title.isEmpty) {
      issues.add(
        const VaultImportIssue(
          severity: VaultImportIssueSeverity.warning,
          message: 'No habia titulo; Vaulta uso el sitio o usuario.',
        ),
      );
    }

    final fallbackTitle = website.isNotEmpty
        ? website
        : (username.isNotEmpty ? username : 'Entrada importada');
    final now = DateTime.now();
    final item = VaultItem(
      id: _uuid.v4(),
      title: title.isEmpty ? fallbackTitle : title,
      username: username,
      secret: secret,
      category: _categoryFromImport(categoryValue),
      strengthScore: estimatePasswordStrength(secret),
      lastUpdatedLabel: formatVaultUpdatedLabel(now),
      website: website.isEmpty ? null : website,
      notes: notes.isEmpty ? null : notes,
      updatedAt: now,
      isFavorite: _isTruthy(favoriteValue),
    );

    return VaultImportCandidate(
      item: item,
      source: source,
      row: rowNumber,
      issues: issues,
    );
  }

  /// Interprets the spellings vendor exports use for a boolean column.
  /// Anything else, including an absent column, means `false`.
  bool _isTruthy(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'true' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'si' ||
        normalized == 'sí';
  }

  VaultCategory _categoryFromImport(String value) {
    return _categoryOrNull(value) ?? VaultCategory.personal;
  }

  /// Maps an arbitrary folder or group name to one of the app's
  /// categories, or `null` when nothing matches. The CSV/JSON path
  /// keeps its historical default of [VaultCategory.personal]; the
  /// `.kdbx` path uses the `null` to keep the group path in the title
  /// instead of silently flattening it.
  VaultCategory? _categoryOrNull(String value) {
    final normalized = value.toLowerCase().trim();
    if (normalized.contains('work') ||
        normalized.contains('trabajo') ||
        normalized.contains('business')) {
      return VaultCategory.work;
    }
    if (normalized.contains('bank') ||
        normalized.contains('finance') ||
        normalized.contains('finanza') ||
        normalized.contains('pago')) {
      return VaultCategory.finance;
    }
    if (normalized.contains('server') ||
        normalized.contains('infra') ||
        normalized.contains('dev') ||
        normalized.contains('ssh')) {
      return VaultCategory.infrastructure;
    }
    return null;
  }

  String _first(Map<String, String> row, List<String> keys) {
    for (final key in keys) {
      final value = row[_normalizeHeader(key)]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }

  String _normalizeHeader(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll('-', '_');
  }

  List<List<String>> _readCsvRows(String input) {
    final delimiter = _detectCsvDelimiter(input);
    final rows = <List<String>>[];
    final currentRow = <String>[];
    final current = StringBuffer();
    var inQuotes = false;
    var index = 0;

    while (index < input.length) {
      final char = input[index];
      if (char == '"') {
        final nextIsQuote = index + 1 < input.length && input[index + 1] == '"';
        if (inQuotes && nextIsQuote) {
          current.write('"');
          index += 2;
          continue;
        }
        inQuotes = !inQuotes;
      } else if (char == delimiter && !inQuotes) {
        currentRow.add(current.toString());
        current.clear();
      } else if ((char == '\n' || char == '\r') && !inQuotes) {
        if (char == '\r' &&
            index + 1 < input.length &&
            input[index + 1] == '\n') {
          index++;
        }
        currentRow.add(current.toString());
        current.clear();
        rows.add(List<String>.from(currentRow));
        currentRow.clear();
      } else {
        current.write(char);
      }
      index++;
    }

    if (current.isNotEmpty || currentRow.isNotEmpty) {
      currentRow.add(current.toString());
      rows.add(List<String>.from(currentRow));
    }
    return rows;
  }

  String _detectCsvDelimiter(String input) {
    final lines = input.split(RegExp(r'\r?\n'));
    final firstLine = lines.isEmpty ? '' : lines.first;
    final commaCount = ','.allMatches(firstLine).length;
    final semicolonCount = ';'.allMatches(firstLine).length;
    return semicolonCount > commaCount ? ';' : ',';
  }
}
