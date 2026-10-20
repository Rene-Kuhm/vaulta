import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_contrasenas/core/security/sensitive_clipboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SensitiveClipboardService.channelName);
  const shortDelay = Duration(milliseconds: 20);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> nativeCalls;
  late List<String?> plainClipboardWrites;
  String? plainClipboard;
  bool nativeClearResult = true;

  void mockNative() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'clearSensitive') return nativeClearResult;
      return null;
    });
  }

  setUp(() {
    nativeCalls = [];
    plainClipboardWrites = [];
    plainClipboard = null;
    nativeClearResult = true;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          final args = call.arguments as Map<Object?, Object?>;
          plainClipboard = args['text'] as String?;
          plainClipboardWrites.add(plainClipboard);
          return null;
        case 'Clipboard.getData':
          return <String, Object?>{'text': plainClipboard};
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('copySensitive', () {
    test('Android: copies through the native sensitive channel only', () async {
      mockNative();
      final service = SensitiveClipboardService(isAndroid: true);

      await service.copySensitive('s3cret!');

      expect(nativeCalls.single.method, 'copySensitive');
      expect(nativeCalls.single.arguments, {'text': 's3cret!'});
      expect(
        plainClipboardWrites,
        isEmpty,
        reason: 'the unflagged Flutter clipboard must not be written too',
      );
      expect(service.hasPendingClip, isTrue);
      await service.clearIfOwned();
    });

    test('non-Android: falls back to Clipboard.setData', () async {
      mockNative();
      final service = SensitiveClipboardService(isAndroid: false);

      await service.copySensitive('s3cret!');

      expect(nativeCalls, isEmpty);
      expect(plainClipboardWrites, ['s3cret!']);
      await service.clearIfOwned();
    });

    test('Android: falls back when the channel throws', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call);
        throw PlatformException(code: 'CLIPBOARD_FAILED');
      });
      final service = SensitiveClipboardService(isAndroid: true);

      await service.copySensitive('s3cret!');

      expect(nativeCalls, hasLength(1));
      expect(plainClipboardWrites, ['s3cret!']);
      await service.clearIfOwned();
    });

    test(
      'Android: a missing channel asserts in debug (regression guard)',
      () async {
        // No mock handler on the channel -> MissingPluginException.
        final service = SensitiveClipboardService(isAndroid: true);

        await expectLater(
          service.copySensitive('s3cret!'),
          throwsA(isA<AssertionError>()),
        );
        expect(plainClipboardWrites, isEmpty);
      },
    );
  });

  group('automatic clear', () {
    test(
      'Android: timer calls native clearSensitive after clearAfter',
      () async {
        mockNative();
        var cleared = 0;
        final service = SensitiveClipboardService(
          isAndroid: true,
          clearAfter: shortDelay,
        );

        await service.copySensitive('s3cret!', onAutoCleared: () => cleared++);
        expect(nativeCalls.map((c) => c.method), ['copySensitive']);

        await Future<void>.delayed(shortDelay * 3);

        expect(nativeCalls.map((c) => c.method), [
          'copySensitive',
          'clearSensitive',
        ]);
        expect(cleared, 1);
        expect(service.hasPendingClip, isFalse);
      },
    );

    test('Android: no callback when native reports it did not clear '
        '(user copied something else)', () async {
      mockNative();
      nativeClearResult = false;
      var cleared = 0;
      final service = SensitiveClipboardService(
        isAndroid: true,
        clearAfter: shortDelay,
      );

      await service.copySensitive('s3cret!', onAutoCleared: () => cleared++);
      await Future<void>.delayed(shortDelay * 3);

      expect(nativeCalls.last.method, 'clearSensitive');
      expect(cleared, 0);
    });

    test('fallback: clears when the clipboard is unchanged', () async {
      var cleared = 0;
      final service = SensitiveClipboardService(
        isAndroid: false,
        clearAfter: shortDelay,
      );

      await service.copySensitive('s3cret!', onAutoCleared: () => cleared++);
      await Future<void>.delayed(shortDelay * 3);

      expect(plainClipboardWrites, ['s3cret!', '']);
      expect(cleared, 1);
    });

    test('fallback: leaves a clip the user copied afterwards', () async {
      var cleared = 0;
      final service = SensitiveClipboardService(
        isAndroid: false,
        clearAfter: shortDelay,
      );

      await service.copySensitive('s3cret!', onAutoCleared: () => cleared++);
      plainClipboard = 'something else';
      await Future<void>.delayed(shortDelay * 3);

      expect(plainClipboardWrites, ['s3cret!']);
      expect(plainClipboard, 'something else');
      expect(cleared, 0);
    });
  });

  group('clearIfOwned', () {
    test('Android: delegates to native and cancels the timer', () async {
      mockNative();
      var cleared = 0;
      final service = SensitiveClipboardService(
        isAndroid: true,
        clearAfter: shortDelay,
      );
      await service.copySensitive('s3cret!', onAutoCleared: () => cleared++);

      expect(await service.clearIfOwned(), isTrue);
      await Future<void>.delayed(shortDelay * 3);

      expect(
        nativeCalls.where((c) => c.method == 'clearSensitive'),
        hasLength(1),
        reason: 'the cancelled timer must not clear a second time',
      );
      expect(cleared, 0, reason: 'explicit clears do not fire the callback');
    });

    test('Android: native error returns false instead of throwing', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'CLIPBOARD_FAILED');
      });

      expect(
        await SensitiveClipboardService(isAndroid: true).clearIfOwned(),
        isFalse,
      );
    });

    test('fallback: nothing copied -> nothing cleared', () async {
      plainClipboard = 'user data';

      expect(
        await SensitiveClipboardService(isAndroid: false).clearIfOwned(),
        isFalse,
      );
      expect(plainClipboardWrites, isEmpty);
    });
  });
}
