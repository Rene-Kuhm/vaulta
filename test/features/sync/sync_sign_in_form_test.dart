import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_contrasenas/features/sync/presentation/sync_sign_in_form.dart';
import 'package:gestor_contrasenas/l10n/app_localizations.dart';

/// The form is the part of sign-in that can go wrong in ways the user must see:
/// wrong password, unreachable server, or a submit that never answers. None of
/// those need Supabase to be exercised, which is the point of keeping the SDK out
/// of this widget.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );

  testWidgets('shows the title, the explanation and both fields', (tester) async {
    await tester.pumpWidget(
      wrap(SyncSignInForm(onSubmit: (_, _) async => null)),
    );

    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.byKey(const Key('syncSignIn.submit')), findsOneWidget);
    expect(find.byKey(const Key('syncSignIn.error')), findsNothing);
    // The body explains that the vault stays local; if that sentence ever leaves
    // the screen, the feature is asking for an account without saying why.
    final l10n = AppLocalizations.of(tester.element(find.byType(TextField).first))!;
    expect(find.text(l10n.syncSignInBody), findsOneWidget);
  });

  testWidgets('an empty form fails locally and never calls the network', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      wrap(SyncSignInForm(onSubmit: (_, _) async { calls++; return null; })),
    );

    await tester.tap(find.byKey(const Key('syncSignIn.submit')));
    await tester.pumpAndSettle();

    expect(calls, 0, reason: 'input that cannot succeed must not be sent');
    expect(find.byKey(const Key('syncSignIn.error')), findsOneWidget);
  });

  testWidgets('a rejected pair shows the credentials message', (tester) async {
    await tester.pumpWidget(
      wrap(SyncSignInForm(onSubmit: (_, _) async => SignInFailure.invalidCredentials)),
    );

    await tester.enterText(find.byKey(const Key('syncSignIn.email')), 'a@b.c');
    await tester.enterText(find.byKey(const Key('syncSignIn.password')), 'secreto');
    await tester.tap(find.byKey(const Key('syncSignIn.submit')));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(tester.element(find.byType(TextField).first))!;
    expect(find.text(l10n.syncSignInInvalid), findsOneWidget);
  });

  testWidgets('an unreachable server says so instead of blaming the password', (tester) async {
    await tester.pumpWidget(
      wrap(SyncSignInForm(onSubmit: (_, _) async => SignInFailure.offline)),
    );

    await tester.enterText(find.byKey(const Key('syncSignIn.email')), 'a@b.c');
    await tester.enterText(find.byKey(const Key('syncSignIn.password')), 'secreto');
    await tester.tap(find.byKey(const Key('syncSignIn.submit')));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(tester.element(find.byType(TextField).first))!;
    expect(find.text(l10n.syncSignInOffline), findsOneWidget);
    expect(find.text(l10n.syncSignInInvalid), findsNothing);
  });

  testWidgets('a successful attempt sends the trimmed email and shows no error', (tester) async {
    String? sentEmail;
    String? sentPassword;
    await tester.pumpWidget(
      wrap(SyncSignInForm(onSubmit: (email, password) async {
        sentEmail = email;
        sentPassword = password;
        return null;
      })),
    );

    await tester.enterText(find.byKey(const Key('syncSignIn.email')), '  a@b.c  ');
    await tester.enterText(find.byKey(const Key('syncSignIn.password')), 'secreto');
    await tester.tap(find.byKey(const Key('syncSignIn.submit')));
    await tester.pumpAndSettle();

    expect(sentEmail, 'a@b.c');
    expect(sentPassword, 'secreto');
    expect(find.byKey(const Key('syncSignIn.error')), findsNothing);
  });

  testWidgets('while the attempt is in flight the button is disabled', (tester) async {
    final completer = Completer<SignInFailure?>();
    await tester.pumpWidget(
      wrap(SyncSignInForm(onSubmit: (_, _) => completer.future)),
    );

    await tester.enterText(find.byKey(const Key('syncSignIn.email')), 'a@b.c');
    await tester.enterText(find.byKey(const Key('syncSignIn.password')), 'secreto');
    await tester.tap(find.byKey(const Key('syncSignIn.submit')));
    await tester.pump();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('syncSignIn.submit')),
    );
    expect(button.onPressed, isNull, reason: 'a second tap must not start a second request');

    completer.complete(null);
    await tester.pumpAndSettle();
  });
}
