import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Copies secrets to the system clipboard so that keyboards and the
/// Android 13+ clipboard preview do not display them, and clears them
/// again after [clearAfter] or when the vault locks.
///
/// On Android the text goes through the `com.insyd.vaulta/clipboard`
/// channel, which flags the `ClipDescription` extras with
/// `IS_SENSITIVE = true` and remembers (natively, as a hash) which
/// clip Vaulta put there. On every other platform, or when the
/// channel throws, it falls back to [Clipboard.setData] so copying
/// never silently fails.
///
/// Clearing is "clear if owned": a clip the user copied afterwards is
/// left alone. On Android 10+ a backgrounded app cannot read the
/// clipboard, so the native side clears whenever it cannot prove the
/// current clip is someone else's. That is what makes the timer work
/// after the user switches apps to paste.
///
/// The app shares a single instance, [shared], so the screen that
/// copies and the controller that locks act on the same pending clip.
class SensitiveClipboardService {
  /// Uses the bundled [MethodChannel] unless [channel] is given.
  /// [isAndroid] defaults to [Platform.isAndroid]; tests override it.
  /// [clearAfter] is how long a copied secret stays on the clipboard.
  SensitiveClipboardService({
    MethodChannel? channel,
    bool? isAndroid,
    this.clearAfter = defaultClearAfter,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  /// Process-wide instance used by the UI and the security controller.
  static final SensitiveClipboardService shared = SensitiveClipboardService();

  /// MethodChannel name for the Android sensitive-clipboard native side.
  static const channelName = 'com.insyd.vaulta/clipboard';

  /// Default lifetime of a copied secret on the clipboard.
  static const defaultClearAfter = Duration(seconds: 30);

  /// How long a copied secret stays on the clipboard before the
  /// automatic clear runs.
  final Duration clearAfter;

  final MethodChannel _channel;
  final bool _isAndroid;

  Timer? _clearTimer;
  VoidCallback? _onAutoCleared;

  /// Text written through the plain [Clipboard] fallback, kept only
  /// until the next clear so "clear if owned" can compare against it.
  String? _fallbackText;

  /// True while a secret copied by this service may still be on the
  /// clipboard (the automatic clear has not run yet).
  bool get hasPendingClip => _clearTimer != null;

  /// Puts [text] on the clipboard, marked sensitive where supported,
  /// and schedules the automatic clear after [clearAfter].
  /// [onAutoCleared] runs if that automatic clear actually removed
  /// the secret (not when [clearIfOwned] is called directly).
  Future<void> copySensitive(String text, {VoidCallback? onAutoCleared}) async {
    await _write(text);
    _clearTimer?.cancel();
    _onAutoCleared = onAutoCleared;
    _clearTimer = Timer(clearAfter, () {
      final callback = _onAutoCleared;
      unawaited(
        clearIfOwned().then((cleared) {
          if (cleared) callback?.call();
        }),
      );
    });
  }

  /// Clears the clipboard if it still holds the secret this service
  /// copied, and cancels the pending automatic clear. Returns true
  /// when the clipboard was cleared. Never throws.
  Future<bool> clearIfOwned() async {
    _clearTimer?.cancel();
    _clearTimer = null;
    _onAutoCleared = null;
    final fallbackText = _fallbackText;
    _fallbackText = null;

    if (_isAndroid && fallbackText == null) {
      try {
        return await _channel.invokeMethod<bool>('clearSensitive') ?? false;
      } on PlatformException catch (e) {
        debugPrint('[Vaulta/Clipboard] native clear failed: ${e.code}');
        return false;
      } on MissingPluginException {
        _assertChannelPresent();
        return false;
      }
    }

    if (fallbackText == null) {
      return false;
    }
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != fallbackText) {
        return false;
      }
      await Clipboard.setData(const ClipboardData(text: ''));
      return true;
    } on PlatformException catch (e) {
      debugPrint('[Vaulta/Clipboard] fallback clear failed: ${e.code}');
      return false;
    }
  }

  Future<void> _write(String text) async {
    if (_isAndroid) {
      try {
        await _channel.invokeMethod<void>('copySensitive', {'text': text});
        _fallbackText = null;
        return;
      } on PlatformException catch (e) {
        debugPrint('[Vaulta/Clipboard] native copy failed: ${e.code}');
      } on MissingPluginException {
        _assertChannelPresent();
      }
    }
    await Clipboard.setData(ClipboardData(text: text));
    _fallbackText = text;
  }

  /// The channel is registered by MainActivity on every Android build,
  /// so a missing channel is a regression. Fail loudly in debug; keep
  /// the plain fallback in release so copying still works.
  void _assertChannelPresent() {
    assert(
      false,
      'MissingPluginException: $channelName is not registered in '
      'MainActivity. Secrets would be copied without the sensitive flag.',
    );
    debugPrint('[Vaulta/Clipboard] native channel missing');
  }
}
