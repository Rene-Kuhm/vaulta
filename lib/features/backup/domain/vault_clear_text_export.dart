import 'dart:convert';

import '../../vault/domain/vault_item.dart';

/// Clear-text (unencrypted) export formats.
///
/// These formats exist so the user can leave Vaulta: they carry the
/// same secrets the vault holds, readable by any other password
/// manager. Nothing here encrypts, authenticates or signs anything;
/// the caller is responsible for warning the user and for writing the
/// file only after an explicit confirmation.
enum VaultClearTextFormat {
  /// Comma-separated values, importable by most password managers.
  csv('csv'),

  /// JSON with every field of [VaultItem], for lossless migration.
  json('json');

  const VaultClearTextFormat(this.fileExtension);

  /// File extension written for this format, without the dot.
  final String fileExtension;
}

/// Serializes vault items to the clear-text migration formats.
///
/// The CSV writer follows RFC 4180: fields are quoted only when they
/// contain a comma, a double quote, CR or LF, embedded quotes are
/// doubled, and records end with CRLF. The JSON writer emits every
/// [VaultItem] field through [VaultItem.toJson] inside a small
/// envelope, so [VaultItem.fromJson] restores an identical item.
///
/// This class is deliberately separate from `VaultBackupService`: the
/// encrypted `.vaulta` format is unchanged and remains the default.
class VaultClearTextExporter {
  /// Builds a stateless exporter.
  const VaultClearTextExporter();

  /// Value of the JSON envelope `format` field.
  static const formatName = 'vaulta-clear-text-export';

  /// Version of the JSON envelope written by this build.
  static const currentVersion = 1;

  /// Column order of the CSV export.
  static const csvHeader = <String>[
    'title',
    'username',
    'password',
    'url',
    'notes',
    'category',
    'updated_at',
  ];

  /// Renders [items] as CSV. The header is always written, even for an
  /// empty vault, so the file is still importable.
  String csv(List<VaultItem> items) {
    final buffer = StringBuffer()
      ..write(csvHeader.join(','))
      ..write('\r\n');
    for (final item in items) {
      final fields = <String>[
        item.title,
        item.username,
        item.secret,
        item.website ?? '',
        item.notes ?? '',
        item.category.name,
        item.updatedAt?.toIso8601String() ?? '',
      ];
      buffer
        ..write(fields.map(escapeCsvField).join(','))
        ..write('\r\n');
    }
    return buffer.toString();
  }

  /// Renders [items] as a JSON document carrying every field of every
  /// item plus export metadata. [exportedAt] is written in UTC and
  /// [appVersion] identifies the build that produced the file.
  String json(
    List<VaultItem> items, {
    required DateTime exportedAt,
    required String appVersion,
  }) {
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'format': formatName,
      'version': currentVersion,
      'app_version': appVersion,
      'exported_at': exportedAt.toUtc().toIso8601String(),
      'item_count': items.length,
      'items': [for (final item in items) item.toJson()],
    });
  }

  /// Escapes one CSV field per RFC 4180: quote it when it contains a
  /// comma, a double quote, CR or LF, and double every embedded quote.
  /// A naive `join(',')` would corrupt every value with such a
  /// character.
  ///
  /// Values are written verbatim, exactly as stored. A spreadsheet may
  /// interpret a leading `=`, `+`, `-` or `@` as a formula; Vaulta does
  /// not rewrite secrets with a prefix, because that would corrupt the
  /// value when the file is imported back into a password manager.
  static String escapeCsvField(String value) {
    final needsQuotes =
        value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');
    if (!needsQuotes) {
      return value;
    }
    return '"${value.replaceAll('"', '""')}"';
  }
}

/// Suggested file name for a clear-text export created at [now]:
/// `vaulta-export-YYYYMMDD-HHmm.<ext>`, in local time.
String vaultClearTextFileName(DateTime now, VaultClearTextFormat format) {
  String two(int value) => value.toString().padLeft(2, '0');
  final local = now.toLocal();
  return 'vaulta-export-${local.year}${two(local.month)}${two(local.day)}-'
      '${two(local.hour)}${two(local.minute)}.${format.fileExtension}';
}
