import 'package:flutter/services.dart';

import 'autofill_fill_handler.dart';

/// The MethodChannel the Android `AutofillService` calls to ask the app for
/// data (ADR-008 §3, §4).
///
/// There is exactly one copy of this name on each side: here, and
/// `VaultaAutofillBridge.CHANNEL_NAME` in Kotlin. The service runs in this
/// app's process, so it talks to this, the app's only Flutter engine — there is
/// no second engine, no second Dart heap and therefore no cache to keep in
/// sync with the session.
const String autofillChannelName = 'com.insyd.gestor_contrasenas/autofill';

/// Exposes [AutofillFillHandler] to the Android autofill service.
///
/// Two methods, both answered from the live vault on every call:
///
///   * `query` — `{host: String?, packageName: String}` answered with
///     `{status: 'locked'|'matched'|'searchOnly', candidates: [{label,
///     username, secret}]}`.
///   * `status` — `'locked'` or `'unlocked'`, for the unlock flow that needs to
///     know whether a query could return anything before showing a prompt.
///
/// Nothing here is stored, and nothing here is logged: a candidate carries a
/// title, a username and a secret, so the safe amount of logging is none
/// (ADR-008 §6).
class AutofillChannel {
  /// Wires [handler] to the channel. [channel] exists for tests; production
  /// uses the real platform channel behind the single engine.
  AutofillChannel({
    required AutofillFillHandler handler,
    MethodChannel? channel,
  }) : _handler = handler,
       _channel = channel ?? const MethodChannel(autofillChannelName);

  final AutofillFillHandler _handler;
  final MethodChannel _channel;

  /// Installs the handler on the engine's messenger.
  ///
  /// Called once from the app bootstrap, where the app's other platform
  /// bridges are built. Calling it twice would replace this handler with an
  /// equivalent one, not duplicate the channel, because a MethodChannel is a
  /// name on the one messenger.
  void register() {
    _channel.setMethodCallHandler(onMethodCall);
  }

  /// Removes the handler. Used when the engine goes away in tests; the app
  /// itself keeps the handler for the life of the process on purpose, so a
  /// fill request that arrives while the app is in the background still finds
  /// it.
  void unregister() {
    _channel.setMethodCallHandler(null);
  }

  /// Answers one inbound call from the service.
  ///
  /// Public so a test can drive the protocol without a binary messenger; the
  /// app only reaches it through [register].
  Future<Object?> onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'status':
        return _handler.isUnlocked ? 'unlocked' : 'locked';
      case 'query':
        return (await _answer(call.arguments)).toJson();
      default:
        throw MissingPluginException(
          'Unknown autofill method: ${call.method}',
        );
    }
  }

  /// Reads the arguments defensively and fails closed.
  ///
  /// The arguments arrive from the platform, and a read that throws must not
  /// become a fill answer: any failure here is reported as [locked] with no
  /// candidates, which is the same answer the service gives when the vault is
  /// locked.
  Future<AutofillAnswer> _answer(Object? arguments) async {
    final map = arguments is Map ? arguments : const <Object?, Object?>{};
    final host = map['host'];
    final packageName = map['packageName'];
    final query = AutofillQuery(
      packageName: packageName is String ? packageName : '',
      host: host is String ? host : null,
    );
    try {
      return await _handler.query(query);
    } catch (_) {
      return const AutofillAnswer.locked();
    }
  }
}
