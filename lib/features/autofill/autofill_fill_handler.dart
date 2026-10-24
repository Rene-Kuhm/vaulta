import 'package:flutter/foundation.dart';

import '../../core/security/vault_repository.dart';
import '../../core/storage/vault_host.dart';
import '../vault/domain/vault_item.dart';

/// The status of one autofill answer (ADR-008 §3).
///
/// The three values are the three answers the Android service can act on, and
/// there is deliberately no fourth: "no match" is not an error, it is
/// [searchOnly].
enum AutofillAnswerStatus {
  /// No session is open, so there is nothing to offer. The service keeps the
  /// authentication intent from the locked contract.
  locked('locked'),

  /// At least one item is indexed for the requested host. Only this status
  /// carries candidates.
  matched('matched'),

  /// The vault is open but no item is indexed for the requested host. The
  /// service offers a single "search in Vaulta" marker and no item, because
  /// guessing is how an autofill menu ends up offering the wrong credential
  /// next to a bank login.
  searchOnly('searchOnly');

  const AutofillAnswerStatus(this.wireName);

  /// The value sent over the MethodChannel. Stable: the Kotlin side switches
  /// on these exact strings.
  final String wireName;
}

/// One credential the fill UI may offer, already shaped for the bridge.
///
/// [label] is the item title, [username] and [secret] are the values to fill.
/// Nothing here is ever logged (ADR-008 §6): the only surface a candidate may
/// reach is the dataset the user taps.
@immutable
class AutofillCandidate {
  /// Creates a candidate from one vault item.
  const AutofillCandidate({
    required this.label,
    required this.username,
    required this.secret,
  });

  /// Item title, shown in the fill UI's dataset row.
  final String label;

  /// Value to fill into the username field.
  final String username;

  /// Value to fill into the password field.
  final String secret;

  /// Wire form for the MethodChannel.
  Map<String, Object?> toJson() => {
    'label': label,
    'username': username,
    'secret': secret,
  };
}

/// The answer to one fill query.
@immutable
class AutofillAnswer {
  /// Creates an answer with explicit [status] and [candidates].
  ///
  /// Prefer the named constructors: they keep the invariant that only a
  /// [AutofillAnswerStatus.matched] answer has candidates.
  const AutofillAnswer({required this.status, required this.candidates});

  /// A closed vault: no data to offer, so no candidates.
  const AutofillAnswer.locked()
    : status = AutofillAnswerStatus.locked,
      candidates = const <AutofillCandidate>[];

  /// An open vault with no item indexed for the host: search marker only.
  const AutofillAnswer.searchOnly()
    : status = AutofillAnswerStatus.searchOnly,
      candidates = const <AutofillCandidate>[];

  /// An open vault with [candidates] indexed for the host.
  const AutofillAnswer.matched(this.candidates)
    : status = AutofillAnswerStatus.matched;

  /// Which of the three answers this is.
  final AutofillAnswerStatus status;

  /// Credentials to build datasets from. Empty unless [status] is
  /// [AutofillAnswerStatus.matched].
  final List<AutofillCandidate> candidates;

  /// Wire form for the MethodChannel.
  Map<String, Object?> toJson() => {
    'status': status.wireName,
    'candidates': [for (final candidate in candidates) candidate.toJson()],
  };
}

/// One query, as the Android service sends it.
///
/// [host] is the requested web domain when the platform reported one (a
/// browser page, a web view); `null` otherwise. [packageName] is the requesting
/// app, carried for diagnostics only: package matching is a later slice, so it
/// never influences the answer.
@immutable
class AutofillQuery {
  /// Creates a query. [packageName] is required because the service always
  /// knows it; [host] is optional because the platform may not have one.
  const AutofillQuery({required this.packageName, this.host});

  /// Package of the app being filled.
  final String packageName;

  /// Requested web domain, or `null` when the request has none.
  final String? host;
}

/// The only two things autofill needs from the vault, and why it is not
/// [VaultRepository].
///
/// Answering a fill request must not be able to read the whole vault: on the
/// encrypted-database storage the host is an index lookup, and a port that
/// exposed [VaultRepository.fetchItems] would make the decrypt-everything path
/// one autocomplete away (ADR-008 §5). What a fill needs is a session state and
/// one host lookup, so that is the whole surface.
abstract interface class AutofillVaultLookup {
  /// `true` while a session exists, i.e. while an answer may carry data.
  bool get isUnlocked;

  /// Items whose indexed host is exactly [host].
  Future<List<VaultItem>> findByHost(String host);
}

/// [AutofillVaultLookup] over the vault the app already has.
///
/// [findByHost] is the indexed lookup when the storage has one
/// (`SqliteVaultRepository.findByHost`, the `vault_hosts` index ADR-007 builds).
/// The blob storage has no index, so without it the adapter falls back to one
/// full read and an exact-host comparison. That fallback is the cost ADR-008 §5
/// accepts for a first version gated behind the experimental storage flag; the
/// comparison is still exact, so the fallback can miss but never guess.
class VaultRepositoryAutofillLookup implements AutofillVaultLookup {
  /// Builds the lookup. [isUnlocked] reads the live session; [findByHost] is
  /// the indexed lookup, or `null` on storages without a host index.
  VaultRepositoryAutofillLookup({
    required VaultRepository repository,
    required bool Function() isUnlocked,
    Future<List<VaultItem>> Function(String host)? findByHost,
  }) : _repository = repository,
       _isUnlocked = isUnlocked,
       _findByHost = findByHost;

  final VaultRepository _repository;
  final bool Function() _isUnlocked;
  final Future<List<VaultItem>> Function(String host)? _findByHost;

  @override
  bool get isUnlocked => _isUnlocked();

  @override
  Future<List<VaultItem>> findByHost(String host) {
    final indexed = _findByHost;
    if (indexed != null) return indexed(host);
    return _scanByHost(host);
  }

  Future<List<VaultItem>> _scanByHost(String host) async {
    final items = await _repository.fetchItems();
    return [
      for (final item in items)
        if (vaultHostOfWebsite(item.website) == host) item,
    ];
  }
}

/// Turns one fill query into the answer the Android service builds datasets
/// from (ADR-008 §3).
///
/// The order is the decision and it is the whole class:
///
///   1. no session → [AutofillAnswer.locked], nothing is read;
///   2. no host → [AutofillAnswer.searchOnly];
///   3. exact host match through [AutofillVaultLookup.findByHost] → those
///      candidates, capped at [maxCandidates];
///   4. no match → [AutofillAnswer.searchOnly], never a guess.
///
/// No fuzzy, substring or best-guess matching happens here, and nothing is
/// cached: every query reads the session state and the index again, so a lock
/// that lands between two queries is answered as locked immediately.
class AutofillFillHandler {
  /// Builds the handler over [lookup], answering at most [maxCandidates]
  /// candidates per query.
  AutofillFillHandler({
    required AutofillVaultLookup lookup,
    this.maxCandidates = AutofillFillHandler.defaultMaxCandidates,
  }) : _lookup = lookup;

  /// The cap a fill answer carries by default: ten credentials is more than
  /// the system's fill UI shows without scrolling, and a smaller list is a
  /// smaller surface for the wrong one to be tapped.
  static const int defaultMaxCandidates = 10;

  /// Upper bound on how many candidates one answer may carry.
  final int maxCandidates;

  final AutofillVaultLookup _lookup;

  /// Whether a query could return data right now, used by the channel's
  /// `status` method.
  bool get isUnlocked => _lookup.isUnlocked;

  /// Answers [query] from the vault. Never throws for a locked session: a
  /// locked vault is an empty answer, not a failure.
  Future<AutofillAnswer> query(AutofillQuery query) async {
    if (!_lookup.isUnlocked) return const AutofillAnswer.locked();

    final host = vaultHostOfWebsite(query.host);
    if (host == null) return const AutofillAnswer.searchOnly();

    final items = await _lookup.findByHost(host);
    if (items.isEmpty) return const AutofillAnswer.searchOnly();

    return AutofillAnswer.matched([
      for (final item in items.take(maxCandidates))
        AutofillCandidate(
          label: item.title,
          username: item.username,
          secret: item.secret,
        ),
    ]);
  }
}
