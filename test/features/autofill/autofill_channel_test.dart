// Tests for the autofill MethodChannel contract (ADR-008 §3).
//
// The Kotlin side of the bridge speaks exactly this protocol, so these tests
// pin the wire shape: `query` answers a status plus the candidates to build
// datasets from, and `status` answers whether a query could return anything at
// all. A change here without a change on the Kotlin side is a broken bridge.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/features/autofill/autofill_channel.dart';
import 'package:gestor_contrasenas/features/autofill/autofill_fill_handler.dart';
import 'package:gestor_contrasenas/features/vault/domain/vault_item.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AutofillChannel', () {
    test('registers on the channel the Android service calls', () async {
      // The value is duplicated from the Kotlin constant on purpose: the test
      // is the place where the two halves have to agree.
      expect(autofillChannelName, 'com.insyd.gestor_contrasenas/autofill');
    });

    test('query answers the matched candidate with username and secret',
        () async {
      _register(
        lookup: _FakeLookup(
          isUnlocked: true,
          items: [_bankItem()],
        ),
      );

      final answer = await _call('query', {
        'host': 'bank.example',
        'packageName': 'com.android.chrome',
      });

      expect(answer, isA<Map<Object?, Object?>>());
      final map = answer! as Map<Object?, Object?>;
      expect(map['status'], 'matched');
      final candidates = map['candidates']! as List<Object?>;
      expect(candidates, hasLength(1));
      final candidate = candidates.single as Map<Object?, Object?>;
      expect(candidate['label'], 'Banco');
      expect(candidate['username'], 'rene@bank.example');
      expect(candidate['secret'], 'bank-secret');
    });

    test('query answers the search marker and no item when nothing matches',
        () async {
      _register(
        lookup: _FakeLookup(
          isUnlocked: true,
          items: [_bankItem()],
        ),
      );

      final answer = await _call('query', {
        'host': 'shop.example',
        'packageName': 'com.example.shop',
      });

      final map = answer! as Map<Object?, Object?>;
      expect(map['status'], 'searchOnly');
      expect(map['candidates'], isEmpty);
    });

    test('query answers locked with no candidates while the vault is locked',
        () async {
      final lookup = _FakeLookup(
        isUnlocked: false,
        items: [_bankItem()],
      );
      _register(lookup: lookup);

      final answer = await _call('query', {
        'host': 'bank.example',
        'packageName': 'com.android.chrome',
      });

      final map = answer! as Map<Object?, Object?>;
      expect(map['status'], 'locked');
      expect(map['candidates'], isEmpty);
      expect(lookup.requestedHosts, isEmpty);
    });

    test('status reports whether a query could return data', () async {
      _register(
        lookup: _FakeLookup(isUnlocked: true, items: const []),
      );
      expect(await _call('status'), 'unlocked');

      _register(
        lookup: _FakeLookup(isUnlocked: false, items: const []),
      );
      expect(await _call('status'), 'locked');
    });

    test('query fails closed when the answer throws', () async {
      _register(lookup: _ThrowingLookup());

      final answer = await _call('query', {
        'host': 'bank.example',
        'packageName': 'com.android.chrome',
      });

      final map = answer! as Map<Object?, Object?>;
      expect(map['status'], 'locked');
      expect(map['candidates'], isEmpty);
    });

    test('an unknown method is not implemented', () async {
      _register(lookup: _FakeLookup(isUnlocked: true, items: const []));

      // The framework turns an unhandled Dart method into a null reply, which
      // is what the Kotlin side sees as `notImplemented`; a reply here would
      // mean the channel answered something it does not implement.
      expect(await _call('save'), isNull);
    });
  });
}

void _register({required AutofillVaultLookup lookup}) {
  AutofillChannel(handler: AutofillFillHandler(lookup: lookup)).register();
}

/// Delivers one method call to the registered Dart handler, as the engine would.
Future<Object?> _call(String method, [Object? arguments]) async {
  const codec = StandardMethodCodec();
  final reply = await TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        autofillChannelName,
        codec.encodeMethodCall(MethodCall(method, arguments)),
        null,
      );
  if (reply == null) return null;
  return codec.decodeEnvelope(reply);
}

VaultItem _bankItem() {
  return const VaultItem(
    id: 'bank',
    title: 'Banco',
    username: 'rene@bank.example',
    secret: 'bank-secret',
    category: VaultCategory.finance,
    strengthScore: 90,
    lastUpdatedLabel: 'Updated now',
    website: 'https://bank.example',
  );
}

class _FakeLookup implements AutofillVaultLookup {
  _FakeLookup({required this.isUnlocked, required this.items});

  @override
  final bool isUnlocked;

  final List<VaultItem> items;
  final List<String> requestedHosts = <String>[];

  @override
  Future<List<VaultItem>> findByHost(String host) async {
    requestedHosts.add(host);
    return [
      for (final item in items)
        if (item.website == 'https://$host') item,
    ];
  }
}

class _ThrowingLookup implements AutofillVaultLookup {
  @override
  bool get isUnlocked => true;

  @override
  Future<List<VaultItem>> findByHost(String host) async {
    throw StateError('vault read failed');
  }
}
