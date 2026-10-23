import 'package:supabase_flutter/supabase_flutter.dart';

/// Resolves the Supabase client for a build, initialising the SDK first.
///
/// Returns `null` when the build has no backend URL or anon key, so callers can
/// degrade to "no sync" without a conditional at every call site.
///
/// `Supabase.initialize` is idempotent (it returns the existing instance when
/// already initialised), so calling this more than once is safe and always
/// yields the same singleton client. The sequence matters: the client must be
/// read **after** initialisation — reading `Supabase.instance.client` first
/// throws, and a caller that swallows that throw ends up thinking sync is
/// disabled even though the backend is configured. That ordering bug is exactly
/// why this helper exists in one place instead of being repeated inline.
Future<SupabaseClient?> resolveSupabaseClient({
  required String url,
  required String anonKey,
}) async {
  if (url.isEmpty || anonKey.isEmpty) {
    return null;
  }
  await Supabase.initialize(url: url, anonKey: anonKey);
  return Supabase.instance.client;
}
