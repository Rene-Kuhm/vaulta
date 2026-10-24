import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// Why a sign-in attempt did not produce a session.
///
/// Two outcomes only, because the screen can act on exactly two: the credentials
/// are wrong, or the server could not be reached. Anything else is a bug and is
/// surfaced through [onUnexpected] rather than guessed at here.
enum SignInFailure {
  /// The server rejected the email/password pair.
  invalidCredentials,

  /// The request never produced an answer.
  offline,
}

/// Result of one sign-in attempt: `null` means a session was created.
typedef SignInSubmit =
    Future<SignInFailure?> Function(String email, String password);

/// Email and password form used before the vault UI when sync is configured.
///
/// Deliberately knows nothing about Supabase: it takes a callback and renders the
/// three states a person can be in — typing, waiting, failed. That keeps the
/// mapping from SDK errors to messages in the gate, and makes this widget testable
/// without a network or a fake client.
class SyncSignInForm extends StatefulWidget {
  /// Builds the form. [onSubmit] performs the attempt and reports its outcome.
  const SyncSignInForm({required this.onSubmit, this.onUnexpected, super.key});

  /// Performs one sign-in attempt.
  final SignInSubmit onSubmit;

  /// Called when the attempt threw something the form cannot classify.
  final void Function(Object error)? onUnexpected;

  @override
  State<SyncSignInForm> createState() => _SyncSignInFormState();
}

class _SyncSignInFormState extends State<SyncSignInForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  SignInFailure? _failure;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      // No request for input that cannot succeed: the server would answer the
      // same thing and the round trip only tells the user we were listening.
      setState(() => _failure = SignInFailure.invalidCredentials);
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final failure = await widget.onSubmit(email, password);
      if (!mounted) return;
      setState(() {
        _failure = failure;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      widget.onUnexpected?.call(error);
      setState(() {
        _failure = SignInFailure.offline;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final failureText = switch (_failure) {
      SignInFailure.invalidCredentials => l10n.syncSignInInvalid,
      SignInFailure.offline => l10n.syncSignInOffline,
      null => null,
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.syncSignInTitle,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(l10n.syncSignInBody, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 28),
                  TextField(
                    key: const Key('syncSignIn.email'),
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.email],
                    decoration: InputDecoration(labelText: l10n.syncEmailLabel),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('syncSignIn.password'),
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: l10n.syncPasswordLabel,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (failureText != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      failureText,
                      key: const Key('syncSignIn.error'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('syncSignIn.submit'),
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.syncSignInAction),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
