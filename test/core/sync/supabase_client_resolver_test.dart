import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/core/sync/supabase_client_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The regression this pins: reading `Supabase.instance.client` before
/// `Supabase.initialize` throws, and a caller that swallowed that throw (the old
/// `SyncSignInGate`) silently disabled sync on a fully configured build. The
/// resolver must initialise first, every time, and be idempotent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `Supabase.initialize` awaits the auth storage, which in tests is the
  // SharedPreferences mock; without it the call throws MissingPluginException.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Whether the current test initialised the singleton, so tearDown only
  // disposes when there is something to dispose (and never trips the
  // `Supabase.instance` assert on an uninitialised instance).
  var initialized = false;

  tearDown(() async {
    if (initialized) {
      await Supabase.instance.dispose();
      initialized = false;
    }
  });

  test(
    'returns null and never initialises when the build has no backend',
    () async {
      expect(await resolveSupabaseClient(url: '', publishableKey: 'x'), isNull);
      expect(
        await resolveSupabaseClient(url: 'https://x', publishableKey: ''),
        isNull,
      );

      // Supabase was never touched: the client was not resolved.
      expect(initialized, isFalse);
    },
  );

  test('initialises before resolving the client, and is idempotent', () async {
    final client = await resolveSupabaseClient(
      url: 'https://example.supabase.co',
      publishableKey: 'publishable-key',
    );
    initialized = true;

    expect(client, isNotNull);
    expect(Supabase.instance.isInitialized, isTrue);
    expect(Supabase.instance.client, same(client));

    final again = await resolveSupabaseClient(
      url: 'https://example.supabase.co',
      publishableKey: 'publishable-key',
    );
    expect(
      again,
      same(client),
      reason: 're-initialising must reuse the singleton, not throw or fork',
    );
  });

  // Neither supabase_flutter 2.12 nor 2.18 validates the key format at
  // initialisation: a syntactically malformed key is forwarded as-is and the
  // SDK behaves exactly as it did before the bump. The resolver must not grow
  // its own validation — only the empty guard above decides whether a client
  // is built.
  test('forwards a malformed key to the SDK unchanged, like before', () async {
    final client = await resolveSupabaseClient(
      url: 'https://example.supabase.co',
      publishableKey: 'not-a-valid-key',
    );
    initialized = true;

    expect(client, isNotNull);
    expect(Supabase.instance.isInitialized, isTrue);
  });
}
