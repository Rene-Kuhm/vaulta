import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/sensitive_clipboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SensitiveClipboardService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> nativeCalls;
  late List<String?> plainClipboardWrites;

  setUp(() {
    nativeCalls = [];
    plainClipboardWrites = [];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments as Map<Object?, Object?>;
        plainClipboardWrites.add(args['text'] as String?);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('Android: copies through the native sensitive channel only', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });

    await SensitiveClipboardService(isAndroid: true).copySensitive('s3cret!');

    expect(nativeCalls, hasLength(1));
    expect(nativeCalls.single.method, 'copySensitive');
    expect(nativeCalls.single.arguments, {'text': 's3cret!'});
    expect(
      plainClipboardWrites,
      isEmpty,
      reason: 'the unflagged Flutter clipboard must not be written too',
    );
  });

  test('non-Android: falls back to Clipboard.setData', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });

    await SensitiveClipboardService(isAndroid: false).copySensitive('s3cret!');

    expect(nativeCalls, isEmpty);
    expect(plainClipboardWrites, ['s3cret!']);
  });

  test('Android: falls back when the channel throws', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      throw PlatformException(code: 'CLIPBOARD_FAILED');
    });

    await SensitiveClipboardService(isAndroid: true).copySensitive('s3cret!');

    expect(nativeCalls, hasLength(1));
    expect(plainClipboardWrites, ['s3cret!']);
  });

  test('Android: falls back when the channel is not registered', () async {
    // No mock handler on the channel -> MissingPluginException.
    await SensitiveClipboardService(isAndroid: true).copySensitive('s3cret!');

    expect(plainClipboardWrites, ['s3cret!']);
  });
}
