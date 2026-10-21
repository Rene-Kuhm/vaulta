import '../domain/vault_item.dart';

/// Known import formats that [VaultImportParser] can detect and parse.
enum VaultImportSource {
  /// Plain CSV with no vendor-specific layout.
  genericCsv('CSV generico'),

  /// CSV exported from Notion databases.
  notionCsv('Notion CSV'),

  /// CSV exported from Chrome's built-in password manager.
  chromeCsv('Chrome CSV'),

  /// Unencrypted Bitwarden CSV export.
  bitwardenCsv('Bitwarden CSV'),

  /// Bitwarden JSON export.
  bitwardenJson('Bitwarden JSON'),

  /// CSV exported from 1Password.
  onePasswordCsv('1Password CSV'),

  /// CSV exported from LastPass.
  lastPassCsv('LastPass CSV'),

  /// CSV exported from KeePass.
  keepassCsv('KeePass CSV'),

  /// Encrypted KeePass database (.kdbx), opened with the master password
  /// and optionally a key file.
  kdbx('KeePass KDBX'),

  /// Generic JSON object or array of credentials.
  json('JSON');

  const VaultImportSource(this.label);

  /// Human-readable label for the source (Spanish UI copy).
  final String label;
}

/// Raised when an import file cannot be decoded at all, for example a
/// KeePass `.kdbx` database whose master password is wrong or whose
/// bytes are corrupt.
///
/// The preview shows [message] as-is, so it must be user-facing
/// Spanish copy that says what to fix instead of leaving an empty
/// candidate list on screen.
class VaultImportException implements Exception {
  /// Creates an exception carrying a user-facing [message].
  const VaultImportException(this.message);

  /// Spanish explanation of why the file could not be imported.
  final String message;

  @override
  String toString() => message;
}

/// Severity level for a [VaultImportIssue] surfaced during a preview.
enum VaultImportIssueSeverity {
  /// The row was kept but the user should review the issue.
  warning,

  /// The row cannot be imported safely.
  error,
}

/// Single validation issue found while parsing an imported row.
/// Single validation issue found while parsing an imported row.
class VaultImportIssue {
  /// Creates a single import issue. [row] is `null` for file-level
  /// issues that do not correspond to a specific row.
  const VaultImportIssue({
    required this.message,
    required this.severity,
    this.row,
  });

  /// Human-readable description (Spanish UI copy).
  final String message;

  /// How serious the issue is.
  final VaultImportIssueSeverity severity;

  /// 1-based row number from the source file, or `null` if it does not
  /// apply (for example, a file-level decoding error).
  final int? row;
}

/// One candidate [VaultItem] extracted from an import file, plus the
/// metadata needed to decide whether the user should confirm it.
/// One candidate [VaultItem] extracted from an import file, plus the
/// metadata needed to decide whether the user should confirm it.
class VaultImportCandidate {
  /// Creates a candidate. [isDuplicate] and [duplicateReason] are
  /// set by the duplicate detector; the parser only fills in
  /// [item], [source], [row], and any [issues].
  const VaultImportCandidate({
    required this.item,
    required this.source,
    required this.row,
    this.issues = const [],
    this.isDuplicate = false,
    this.duplicateReason,
  });

  /// The vault item that would be created if the user confirms.
  final VaultItem item;

  /// The import source this candidate was parsed from.
  final VaultImportSource source;

  /// 1-based row number from the source file.
  final int row;

  /// Validation issues found while parsing this row. Empty means the
  /// row is well-formed.
  final List<VaultImportIssue> issues;

  /// `true` if [VaultDuplicateDetector] flagged the candidate as a
  /// duplicate of an existing vault entry.
  final bool isDuplicate;

  /// Spanish explanation of why the candidate is a duplicate, or
  /// `null` when [isDuplicate] is `false`.
  final String? duplicateReason;

  /// `true` if the user can safely import this candidate: it is not a
  /// duplicate and it has no [VaultImportIssueSeverity.error] issues.
  bool get canImport =>
      !isDuplicate &&
      issues.every((issue) => issue.severity != VaultImportIssueSeverity.error);

  /// Returns a copy of this candidate with the given fields replaced.
  VaultImportCandidate copyWith({
    VaultItem? item,
    VaultImportSource? source,
    int? row,
    List<VaultImportIssue>? issues,
    bool? isDuplicate,
    String? duplicateReason,
  }) {
    return VaultImportCandidate(
      item: item ?? this.item,
      source: source ?? this.source,
      row: row ?? this.row,
      issues: issues ?? this.issues,
      isDuplicate: isDuplicate ?? this.isDuplicate,
      duplicateReason: duplicateReason ?? this.duplicateReason,
    );
  }
}

/// The full result of running [VaultImportParser.parse]: every parsed
/// candidate plus the issues that could not even produce a candidate.
/// The full result of running [VaultImportParser.parse]: every parsed
/// candidate plus the issues that could not even produce a candidate.
class VaultImportPreview {
  /// Creates a preview. [candidates] and [rejected] are independent
  /// lists: a rejected issue did not produce a candidate, so it does
  /// not appear in [candidates].
  const VaultImportPreview({
    required this.source,
    required this.candidates,
    required this.rejected,
  });

  /// Source format that was detected for the imported file.
  final VaultImportSource source;

  /// Parsed candidates, each tagged with any issues or duplicate
  /// markers from the validation pass.
  final List<VaultImportCandidate> candidates;

  /// File-level or row-level issues that prevented producing a
  /// candidate at all.
  final List<VaultImportIssue> rejected;

  /// Number of [candidates] whose [VaultImportCandidate.canImport]
  /// is `true`.
  int get importableCount =>
      candidates.where((candidate) => candidate.canImport).length;

  /// Number of [candidates] flagged as duplicates.
  int get duplicateCount =>
      candidates.where((candidate) => candidate.isDuplicate).length;

  /// Number of [rejected] issues.
  int get rejectedCount => rejected.length;
}

/// Summary of what happened when the user confirmed an import.
/// Summary of what happened when the user confirmed an import.
class VaultImportResult {
  /// Creates a result. [imported] is the number of candidates
  /// persisted as new vault entries; [skippedDuplicates] is the
  /// number of candidates the user chose to skip.
  const VaultImportResult({
    required this.imported,
    required this.skippedDuplicates,
  });

  /// Number of candidates that were persisted as new vault entries.
  final int imported;

  /// Number of duplicates the user chose to skip instead of importing.
  final int skippedDuplicates;
}
