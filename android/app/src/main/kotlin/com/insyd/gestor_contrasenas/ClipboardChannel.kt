package com.insyd.gestor_contrasenas

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart bridge for [SensitiveClipboard]: copies secrets flagged as
 * sensitive and clears them "if owned". The copy/clear rules, the
 * backup alarm and the API-level guards live in [SensitiveClipboard]
 * so this channel and [ClipboardClearReceiver] share one
 * implementation.
 *
 *   * `copySensitive {text, clearAfterMs}` -> null
 *   * `clearSensitive` -> Boolean (true when the clipboard was cleared)
 *
 * The clipped text is never logged.
 */
class ClipboardChannel(
    engine: FlutterEngine,
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    private val channel: MethodChannel =
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "copySensitive" -> {
                val text = call.argument<String>("text")
                if (text == null) {
                    result.error("ARG", "text is required", null)
                    return
                }
                val clearAfterMs = call.argument<Number>("clearAfterMs")?.toLong()
                    ?: DEFAULT_CLEAR_AFTER_MS
                try {
                    SensitiveClipboard.copy(context, text, clearAfterMs)
                    result.success(null)
                } catch (e: Throwable) {
                    Log.w(TAG, "copySensitive failed: ${e.javaClass.simpleName}")
                    result.error("CLIPBOARD_FAILED", e.javaClass.simpleName, null)
                }
            }
            "clearSensitive" -> {
                try {
                    result.success(SensitiveClipboard.clearIfOwned(context, fromAlarm = false))
                } catch (e: Throwable) {
                    Log.w(TAG, "clearSensitive failed: ${e.javaClass.simpleName}")
                    result.error("CLIPBOARD_FAILED", e.javaClass.simpleName, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL_NAME = "com.insyd.vaulta/clipboard"
        private const val TAG = "Vaulta/Clipboard"
        private const val DEFAULT_CLEAR_AFTER_MS = 30_000L
    }
}
