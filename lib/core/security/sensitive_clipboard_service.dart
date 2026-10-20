import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Copies secrets to the system clipboard so that keyboards and the
/// Android 13+ clipboard preview do not display them.
///
/// On Android the text goes through the `com.insyd.vaulta/clipboard`
/// channel, which flags the `ClipDescription` extras with
/// `IS_SENSITIVE = true`. On every other platform, or when the
/// channel is missing or throws, it falls back to
/// [Clipboard.setData] so copying never silently fails.
///
/// The service only writes. Clearing after a timeout stays with the
/// caller, which reads back through [Clipboard.getData].
class SensitiveClipboardService {
  /// Uses the bundled [MethodChannel] unless [channel] is given.
  /// [isAndroid] defaults to [Platform.isAndroid]; tests override it.
  SensitiveClipboardService({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel(channelName),
      _isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  /// MethodChannel name for the Android sensitive-clipboard native side.
  static const channelName = 'com.insyd.vaulta/clipboard';

  final MethodChannel _channel;
  final bool _isAndroid;

  /// Puts [text] on the clipboard, marked sensitive where supported.
  Future<void> copySensitive(String text) async {
    if (_isAndroid) {
      try {
        await _channel.invokeMethod<void>('copySensitive', {'text': text});
        return;
      } on PlatformException catch (e) {
        debugPrint('[Vaulta/Clipboard] native copy failed: ${e.code}');
      } on MissingPluginException {
        debugPrint('[Vaulta/Clipboard] native channel missing');
      }
    }
    await Clipboard.setData(ClipboardData(text: text));
  }
}
