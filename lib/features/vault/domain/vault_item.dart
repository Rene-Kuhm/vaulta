import 'package:flutter/material.dart';

/// High-level grouping used to pick a default icon and accent color
/// for a [VaultItem].
enum VaultCategory {
  /// Work-related credentials (work tools, internal apps).
  work('Work'),

  /// Banking, payments, and other financial services.
  finance('Finance'),

  /// Personal accounts that do not fit the other categories.
  personal('Personal'),

  /// Infrastructure access (SSH keys, servers, cloud consoles).
  infrastructure('Infrastructure');

  const VaultCategory(this.label);

  /// English label used in the legacy UI surface.
  final String label;

  /// Resolves a category by its [Enum.name], falling back to
  /// [VaultCategory.personal] when [value] does not match any
  /// known category (for example, when reading a record that was
  /// written by an older version of the app).
  static VaultCategory fromName(String value) {
    return VaultCategory.values.firstWhere(
      (category) => category.name == value,
      orElse: () => VaultCategory.personal,
    );
  }
}

/// Upper bound on how many previous secrets a single entry keeps.
///
/// Ten covers a year of quarterly rotations (and a couple of years of
/// monthly ones) without growing the encrypted payload noticeably or
/// keeping a password the user rotated away from long ago. When the
/// bound is exceeded the oldest entry is dropped.
const int vaultPasswordHistoryLimit = 10;

/// One password this entry used to have, plus the instant it was
/// replaced.
///
/// Only the [secret] itself and [replacedAt] are stored: nothing here
/// identifies the user, and the whole payload is encrypted at rest, so
/// a previous password is as protected as the current one.
@immutable
class PasswordHistoryEntry {
  /// Creates a history entry. [secret] is the password that was in
  /// use before [replacedAt].
  const PasswordHistoryEntry({
    required this.secret,
    required this.replacedAt,
  });

  /// The password that was replaced.
  final String secret;

  /// When the password was replaced by a newer one.
  final DateTime replacedAt;

  /// Serializes the entry to a plain JSON map. The inverse is
  /// [PasswordHistoryEntry.fromJson].
  Map<String, dynamic> toJson() {
    return {
      'secret': secret,
      'replacedAt': replacedAt.toIso8601String(),
    };
  }

  /// Rebuilds a [PasswordHistoryEntry] from a JSON map produced by
  /// [toJson].
  factory PasswordHistoryEntry.fromJson(Map<String, dynamic> json) {
    return PasswordHistoryEntry(
      secret: json['secret'] as String,
      replacedAt: DateTime.parse(json['replacedAt'] as String),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PasswordHistoryEntry &&
        other.secret == secret &&
        other.replacedAt == replacedAt;
  }

  @override
  int get hashCode => Object.hash(secret, replacedAt);

  @override
  String toString() =>
      'PasswordHistoryEntry(secret: <redacted>, '
      'replacedAt: ${replacedAt.toIso8601String()})';
}

/// Computes the history that results from replacing [previousSecret]
/// with [nextSecret] at [replacedAt].
///
/// Nothing is recorded when [previousSecret] is empty (there was no
/// password to keep), when it equals [nextSecret] (the user saved
/// without rotating), or when it is already the newest entry (a
/// repeated save must not duplicate a secret). Otherwise the previous
/// secret is appended, and the list keeps at most
/// [vaultPasswordHistoryLimit] entries, dropping the oldest.
///
/// Entries are stored oldest first; [VaultItem.passwordHistoryNewestFirst]
/// exposes them in the order the detail screen presents them.
List<PasswordHistoryEntry> vaultPasswordHistoryAfterRotation(
  List<PasswordHistoryEntry> history, {
  required String previousSecret,
  required String nextSecret,
  required DateTime replacedAt,
}) {
  if (previousSecret.isEmpty || previousSecret == nextSecret) {
    return history;
  }
  if (history.isNotEmpty && history.last.secret == previousSecret) {
    return history;
  }

  final updated = <PasswordHistoryEntry>[
    ...history,
    PasswordHistoryEntry(secret: previousSecret, replacedAt: replacedAt),
  ];

  if (updated.length <= vaultPasswordHistoryLimit) {
    return updated;
  }
  return updated.sublist(updated.length - vaultPasswordHistoryLimit);
}

/// A single password vault entry. Immutable; edits are performed via
/// [copyWith] and persisted through the vault repository layer.
class VaultItem {
  /// Creates an entry. All the named fields are required and must
  /// be persisted as-is. [website], [notes], and [updatedAt] are
  /// optional because older app versions and external imports may
  /// not supply them.
  const VaultItem({
    required this.id,
    required this.title,
    required this.username,
    required this.secret,
    required this.category,
    required this.strengthScore,
    required this.lastUpdatedLabel,
    this.website,
    this.notes,
    this.updatedAt,
    this.otpAuthUri,
    this.passwordHistory = const <PasswordHistoryEntry>[],
  });

  /// Stable identifier (UUID v4) used to reference the entry across
  /// the repository, sync layer, and import preview.
  final String id;

  /// Display name for the entry (for example, "GitHub").
  final String title;

  /// Username, email, or login handle associated with the entry.
  final String username;

  /// The actual secret: a password, API token, or recovery code.
  final String secret;

  /// High-level grouping used for the icon and accent color.
  final VaultCategory category;

  /// Estimated strength of [secret] in the 5..100 range, produced by
  /// [estimatePasswordStrength].
  final int strengthScore;

  /// Pre-formatted "updated …" string for display in the dashboard
  /// and entry tile. Generated via [formatVaultUpdatedLabel] so the
  /// UI does not have to compute it on every build.
  final String lastUpdatedLabel;

  /// Origin website or URL, or `null` if the entry has none.
  final String? website;

  /// Free-form user notes, or `null` if the entry has none.
  final String? notes;

  /// Timestamp of the last edit, used to recompute
  /// [lastUpdatedLabel]. `null` only for entries created by older
  /// versions of the app.
  final DateTime? updatedAt;

  /// Optional `otpauth://totp/...` key URI that lets the detail
  /// screen render the entry's one-time code.
  ///
  /// `null` for the vast majority of entries. It is serialized only
  /// when present, so a payload written before this field existed
  /// keeps its exact shape, and the encrypted item format needs no
  /// version bump.
  final String? otpAuthUri;

  /// Passwords this entry used to have, oldest first.
  ///
  /// Empty for the vast majority of entries (a new entry, or one whose
  /// password was never rotated), and serialized only when non-empty,
  /// so a payload written before this field existed keeps its exact
  /// shape and the encrypted item format needs no version bump.
  final List<PasswordHistoryEntry> passwordHistory;

  /// [passwordHistory] in the order the detail screen shows it: the
  /// most recently replaced password first.
  List<PasswordHistoryEntry> get passwordHistoryNewestFirst =>
      passwordHistory.reversed.toList(growable: false);

  /// Material icon that represents [category] in the dashboard tile.
  IconData get icon => switch (category) {
    VaultCategory.work => Icons.design_services_rounded,
    VaultCategory.finance => Icons.account_balance_wallet_rounded,
    VaultCategory.personal => Icons.menu_book_rounded,
    VaultCategory.infrastructure => Icons.dns_rounded,
  };

  /// Accent color used in chips, banners, and the entry tile.
  Color get accentColor => switch (category) {
    VaultCategory.work => const Color(0xFF1C6E8C),
    VaultCategory.finance => const Color(0xFF2D936C),
    VaultCategory.personal => const Color(0xFFF2C14E),
    VaultCategory.infrastructure => const Color(0xFFD1495B),
  };

  /// Serializes the entry to a plain JSON map. The inverse is
  /// [fromJson]. Used by the encrypted backup export
  /// (`VaultBackupService`, ADR-006) for the payload items, and by
  /// tests.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'username': username,
      'secret': secret,
      'category': category.name,
      'strengthScore': strengthScore,
      'lastUpdatedLabel': lastUpdatedLabel,
      'website': website,
      'notes': notes,
      'updatedAt': updatedAt?.toIso8601String(),
      if (otpAuthUri != null) 'otpAuthUri': otpAuthUri,
      if (passwordHistory.isNotEmpty)
        'passwordHistory': passwordHistory
            .map((entry) => entry.toJson())
            .toList(growable: false),
    };
  }

  /// Rebuilds a [VaultItem] from a JSON map produced by [toJson].
  /// The `category` field is matched via [VaultCategory.fromName] and
  /// therefore falls back to [VaultCategory.personal] for unknown
  /// values.
  factory VaultItem.fromJson(Map<String, dynamic> json) {
    return VaultItem(
      id: json['id'] as String,
      title: json['title'] as String,
      username: json['username'] as String,
      secret: json['secret'] as String,
      category: VaultCategory.fromName(json['category'] as String),
      strengthScore: json['strengthScore'] as int,
      lastUpdatedLabel: json['lastUpdatedLabel'] as String,
      website: json['website'] as String?,
      notes: json['notes'] as String?,
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.parse(json['updatedAt'] as String),
      otpAuthUri: json['otpAuthUri'] as String?,
      passwordHistory: _passwordHistoryFromJson(json['passwordHistory']),
    );
  }

  static List<PasswordHistoryEntry> _passwordHistoryFromJson(Object? value) {
    if (value == null) {
      return const <PasswordHistoryEntry>[];
    }
    return (value as List<dynamic>)
        .map(
          (entry) =>
              PasswordHistoryEntry.fromJson(entry as Map<String, dynamic>),
        )
        .toList(growable: false);
  }

  /// Returns a copy of this entry with the given fields replaced.
  /// Used by the editor screen and by import preview confirmations.
  VaultItem copyWith({
    String? id,
    String? title,
    String? username,
    String? secret,
    VaultCategory? category,
    int? strengthScore,
    String? lastUpdatedLabel,
    String? website,
    String? notes,
    DateTime? updatedAt,
    String? otpAuthUri,
    List<PasswordHistoryEntry>? passwordHistory,
  }) {
    return VaultItem(
      id: id ?? this.id,
      title: title ?? this.title,
      username: username ?? this.username,
      secret: secret ?? this.secret,
      category: category ?? this.category,
      strengthScore: strengthScore ?? this.strengthScore,
      lastUpdatedLabel: lastUpdatedLabel ?? this.lastUpdatedLabel,
      website: website ?? this.website,
      notes: notes ?? this.notes,
      updatedAt: updatedAt ?? this.updatedAt,
      otpAuthUri: otpAuthUri ?? this.otpAuthUri,
      passwordHistory: passwordHistory ?? this.passwordHistory,
    );
  }
}

/// Computes a coarse strength score in the 5..100 range for [secret].
///
/// The heuristic rewards length (>=8 and >=12 characters), uppercase,
/// lowercase, digits, and symbols, then clamps the result so the
/// weakest possible password still scores above the minimum.
int estimatePasswordStrength(String secret) {
  var score = 0;
  final trimmed = secret.trim();

  if (trimmed.length >= 8) {
    score += 20;
  }
  if (trimmed.length >= 12) {
    score += 20;
  }
  if (RegExp(r'[A-Z]').hasMatch(trimmed)) {
    score += 15;
  }
  if (RegExp(r'[a-z]').hasMatch(trimmed)) {
    score += 15;
  }
  if (RegExp(r'\d').hasMatch(trimmed)) {
    score += 15;
  }
  if (RegExp(r'[^A-Za-z0-9]').hasMatch(trimmed)) {
    score += 15;
  }

  return score.clamp(5, 100);
}

/// Renders the "Updated …" label shown next to a vault entry.
///
/// Rounds down to minutes/hours/days and falls back to literal
/// "yesterday" for the 1-day window. [now] is injectable so tests can
/// pin a reference time.
String formatVaultUpdatedLabel(DateTime updatedAt, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final difference = reference.difference(updatedAt);

  if (difference.inMinutes < 1) {
    return 'Updated now';
  }
  if (difference.inHours < 1) {
    return 'Updated ${difference.inMinutes}m ago';
  }
  if (difference.inDays < 1) {
    return 'Updated ${difference.inHours}h ago';
  }
  if (difference.inDays == 1) {
    return 'Updated yesterday';
  }
  return 'Updated ${difference.inDays}d ago';
}
