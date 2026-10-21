import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_sign_in_form.dart';

/// Whether this build was compiled with the sync backend configured.
///
/// Two compile-time values, both public by design: the anon key is meant to ship
/// in the client and RLS is what protects the rows. A build without them behaves
/// exactly like the app did before sync existed.
const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');

/// The public anon key this build was compiled with, or an empty string.
const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// True when both values are present, so a sign-in can even be attempted.
bool get syncConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

/// Gates [child] behind a Supabase sign-in, but only when sync is configured.
///
/// The reason this exists at all: the sync layer reads `auth.currentUser?.id`, and
/// with no signed-in user every RLS policy evaluates `auth.uid() = user_id` as
/// false. Without this gate the app would silently sync nothing.
///
/// Three behaviours, in order:
/// - sync not configured: [child] immediately, no Supabase contact at all;
/// - configured but Supabase not initialised: [child], because a build that cannot
///   reach its backend must not lock the user out of their own local vault;
/// - configured and initialised: the form until there is a session, then [child].
class SyncSignInGate extends StatefulWidget {
  /// Wraps [child]. [client] is injectable so the gate can be exercised without
  /// a live project; production reads [Supabase.instance].
  const SyncSignInGate({required this.child, this.client, super.key});

  /// The vault UI to show once a session exists.
  final Widget child;

  /// Optional client override, for tests.
  final SupabaseClient? client;

  @override
  State<SyncSignInGate> createState() => _SyncSignInGateState();
}

class _SyncSignInGateState extends State<SyncSignInGate> {
  SupabaseClient? _client;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _resolveClient();
  }

  void _resolveClient() {
    if (widget.client != null) {
      _client = widget.client;
      _ready = true;
      return;
    }
    if (!syncConfigured) {
      _ready = true;
      return;
    }
    try {
      _client = Supabase.instance.client;
    } on Object {
      // Configured but not initialised (the server was unreachable when the
      // lifecycle was built). Local access must keep working.
      _client = null;
    }
    _ready = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const SizedBox.shrink();
    }
    final client = _client;
    if (client == null) {
      return widget.child;
    }
    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // The stream never emits the current session on subscribe, so read it
        // directly; the stream is what tells us when it appears or goes away.
        final session = snapshot.data?.session ?? client.auth.currentSession;
        if (session != null) {
          return widget.child;
        }
        return SyncSignInForm(
          onSubmit: (email, password) => _signIn(client, email, password),
        );
      },
    );
  }

  Future<SignInFailure?> _signIn(
    SupabaseClient client,
    String email,
    String password,
  ) async {
    try {
      final response = await client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      return response.session == null ? SignInFailure.invalidCredentials : null;
    } on AuthException catch (error) {
      // GoTrue answers 400 invalid_credentials for a wrong pair and 400
      // email_not_confirmed for an unverified account; anything that is not an
      // explicit credential rejection is reported as unreachable rather than as
      // "wrong password", which would be a lie the user cannot act on.
      final code = error.code?.toLowerCase() ?? '';
      final looksLikeCredentials =
          code.contains('invalid') || error.statusCode == '400' && code.isEmpty;
      return looksLikeCredentials
          ? SignInFailure.invalidCredentials
          : SignInFailure.offline;
    }
  }
}
