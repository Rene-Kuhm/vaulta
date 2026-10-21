// Tests for the autofill answer path (ADR-008 §3, §4, §6).
//
// The rules pinned here are the ones a wrong implementation would break
// silently: an exact host match is offered with its username and secret, a
// miss offers the search marker and *no* item, a locked vault offers
// nothing, the answer is capped, and the handler asks the host index for
// the host instead of decrypting the whole vault.

import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/vault_repository.dart';
import 'package:gestor_contrasenas/core/storage/vault_host.dart';
import 'package:gestor_contrasenas/features/autofill/autofill_fill_handler.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_summary.dart';

void main() {
  group('AutofillFillHandler', () {
    test('answers an exact host match with that item username and secret',
        () async {
      final repository = _RecordingVaultRepository([
        _item(
          id: 'bank',
          title: 'Banco',
          username: 'rene@bank.example',
          secret: 'bank-secret',
          website: 'https://bank.example/login',
        ),
        _item(
          id: 'mail',
          title: 'Mail',
          username: 'rene@mail.example',
          secret: 'mail-secret',
          website: 'https://mail.example',
        ),
      ]);
      final handler = AutofillFillHandler(lookup: _indexedLookup(repository));

      final answer = await handler.query(
        const AutofillQuery(
          packageName: 'com.android.chrome',
          host: 'bank.example',
        ),
      );

      expect(answer.status, AutofillAnswerStatus.matched);
      expect(answer.candidates, hasLength(1));
      expect(answer.candidates.single.label, 'Banco');
      expect(answer.candidates.single.username, 'rene@bank.example');
      expect(answer.candidates.single.secret, 'bank-secret');
    });

    test('returns only the search marker when no item is indexed for the host',
        () async {
      final repository = _RecordingVaultRepository([
        _item(
          id: 'bank',
          title: 'Banco',
          username: 'rene@bank.example',
          secret: 'bank-secret',
          website: 'https://bank.example',
        ),
      ]);
      final handler = AutofillFillHandler(lookup: _indexedLookup(repository));

      final answer = await handler.query(
        const AutofillQuery(
          packageName: 'com.example.shop',
          host: 'shop.example',
        ),
      );

      expect(answer.status, AutofillAnswerStatus.searchOnly);
      expect(answer.candidates, isEmpty);
      // Nothing is guessed: not even the item that is one character away.
      expect(
        answer.candidates.map((candidate) => candidate.secret),
        isNot(contains('bank-secret')),
      );
    });

    test('a similar host is not a match (no substring, no fuzzy)', () async {
      final repository = _RecordingVaultRepository([
        _item(
          id: 'bank',
          title: 'Banco',
          username: 'rene@bank.example',
          secret: 'bank-secret',
          website: 'https://bank.example',
        ),
      ]);
      // The blob storage has no host index, so this exercises the exact-match
      // scan the adapter falls back to. Every one of these is a near miss.
      final handler = AutofillFillHandler(
        lookup: VaultRepositoryAutofillLookup(
          repository: repository,
          isUnlocked: () => true,
        ),
      );

      for (final host in <String?>[
        'bank.example.evil',
        'notbank.example',
        'www.bank.example.evil',
        'example',
      ]) {
        final answer = await handler.query(
          AutofillQuery(packageName: 'com.evil', host: host),
        );
        expect(
          answer.status,
          AutofillAnswerStatus.searchOnly,
          reason: '$host must not match bank.example',
        );
        expect(answer.candidates, isEmpty, reason: '$host must offer nothing');
      }

      // The exact host still matches, so the scan is not matching nothing.
      final exact = await handler.query(
        const AutofillQuery(packageName: 'com.android.chrome', host: 'bank.example'),
      );
      expect(exact.status, AutofillAnswerStatus.matched);
      expect(exact.candidates.single.secret, 'bank-secret');
    });

    test('answers an empty list while the vault is locked', () async {
      final repository = _RecordingVaultRepository([
        _item(
          id: 'bank',
          title: 'Banco',
          username: 'rene@bank.example',
          secret: 'bank-secret',
          website: 'https://bank.example',
        ),
      ]);
      final handler = AutofillFillHandler(
        lookup: VaultRepositoryAutofillLookup(
          repository: repository,
          isUnlocked: () => false,
          findByHost: repository.findByHost,
        ),
      );

      final answer = await handler.query(
        const AutofillQuery(
          packageName: 'com.android.chrome',
          host: 'bank.example',
        ),
      );

      expect(answer.status, AutofillAnswerStatus.locked);
      expect(answer.candidates, isEmpty);
      // A locked vault is not even asked: no host reaches the repository.
      expect(repository.requestedHosts, isEmpty);
    });

    test('never returns more candidates than the cap', () async {
      final repository = _RecordingVaultRepository([
        for (var i = 0; i < 12; i++)
          _item(
            id: 'bank-$i',
            title: 'Banco $i',
            username: 'rene$i@bank.example',
            secret: 'secret-$i',
            website: 'https://bank.example',
          ),
      ]);
      final handler = AutofillFillHandler(lookup: _indexedLookup(repository));

      final answer = await handler.query(
        const AutofillQuery(
          packageName: 'com.android.chrome',
          host: 'bank.example',
        ),
      );

      expect(answer.status, AutofillAnswerStatus.matched);
      expect(
        answer.candidates,
        hasLength(AutofillFillHandler.defaultMaxCandidates),
      );
      expect(answer.candidates, hasLength(10));
    });

    test('asks for the host instead of decrypting every item', () async {
      final repository = _RecordingVaultRepository([
        _item(
          id: 'bank',
          title: 'Banco',
          username: 'rene@bank.example',
          secret: 'bank-secret',
          website: 'https://bank.example',
        ),
      ]);
      final handler = AutofillFillHandler(lookup: _indexedLookup(repository));

      await handler.query(
        const AutofillQuery(
          packageName: 'com.android.chrome',
          host: 'bank.example',
        ),
      );

      // One indexed lookup for the requested host...
      expect(repository.requestedHosts, ['bank.example']);
      // ...and no full read of the vault, which is the cost that matters
      // (ADR-008 §5) and the reason this port is narrower than VaultRepository.
      expect(repository.fetchItemsCalls, 0);
    });

    test('normalizes the requested host before asking for it', () async {
      final repository = _RecordingVaultRepository([
        _item(
          id: 'bank',
          title: 'Banco',
          username: 'rene@bank.example',
          secret: 'bank-secret',
          website: 'https://bank.example',
        ),
      ]);
      final handler = AutofillFillHandler(lookup: _indexedLookup(repository));

      final answer = await handler.query(
        const AutofillQuery(
          packageName: 'com.android.chrome',
          host: 'HTTPS://www.Bank.Example/login?user=1',
        ),
      );

      expect(repository.requestedHosts, ['bank.example']);
      expect(answer.status, AutofillAnswerStatus.matched);
    });
  });
}

AutofillVaultLookup _indexedLookup(_RecordingVaultRepository repository) {
  return VaultRepositoryAutofillLookup(
    repository: repository,
    isUnlocked: () => true,
    findByHost: repository.findByHost,
  );
}

VaultItem _item({
  required String id,
  required String title,
  required String username,
  required String secret,
  String? website,
}) {
  return VaultItem(
    id: id,
    title: title,
    username: username,
    secret: secret,
    category: VaultCategory.personal,
    strengthScore: 80,
    lastUpdatedLabel: 'Updated now',
    website: website,
  );
}

/// Repository that records what the autofill path asked it for, so a test can
/// tell an indexed host lookup from a full vault read.
class _RecordingVaultRepository implements VaultRepository {
  _RecordingVaultRepository(this.items);

  final List<VaultItem> items;
  final List<String> requestedHosts = <String>[];
  int fetchItemsCalls = 0;

  Future<List<VaultItem>> findByHost(String host) async {
    requestedHosts.add(host);
    return [
      for (final item in items)
        if (vaultHostOfWebsite(item.website) == host) item,
    ];
  }

  @override
  Future<List<VaultItem>> fetchItems() async {
    fetchItemsCalls++;
    return items;
  }

  @override
  Future<VaultItem?> fetchItemById(String id) async {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<VaultSummary> fetchSummary() async {
    return VaultSummary(
      totalItems: items.length,
      weakItems: 0,
      reusedItems: 0,
      securityScore: 100,
      connectedDevices: 0,
      syncEnabled: false,
    );
  }

  @override
  Future<VaultItem> saveItem(VaultItem item) async => item;

  @override
  Future<void> deleteItem(String id) async {}
}
