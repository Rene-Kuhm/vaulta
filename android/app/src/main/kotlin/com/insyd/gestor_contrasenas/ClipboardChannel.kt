package com.insyd.gestor_contrasenas

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Copies secrets to the system clipboard flagged as sensitive.
 *
 * Android 13+ shows a visual preview of clipboard content and many
 * keyboards surface recent clips as suggestions. Marking the
 * [ClipDescription] extras with `IS_SENSITIVE = true` tells the
 * system UI and well-behaved IMEs to hide the value:
 *   * API 33+ uses [ClipDescription.EXTRA_IS_SENSITIVE].
 *   * Older APIs use the literal key
 *     `"android.content.extra.IS_SENSITIVE"`, as Google's
 *     "Copy and paste" guide recommends, so OEM keyboards that
 *     already honor it hide the value too.
 *
 * The clipped text is never logged. Clearing the clipboard after
 * the timeout stays on the Dart side.
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
                try {
                    copySensitive(text)
                    result.success(null)
                } catch (e: Throwable) {
                    Log.w(TAG, "copySensitive failed: ${e.javaClass.simpleName}")
                    result.error("CLIPBOARD_FAILED", e.javaClass.simpleName, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun copySensitive(text: String) {
        val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText(CLIP_LABEL, text)
        clip.description.extras = PersistableBundle().apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            } else {
                putBoolean(LEGACY_EXTRA_IS_SENSITIVE, true)
            }
        }
        manager.setPrimaryClip(clip)
    }

    companion object {
        const val CHANNEL_NAME = "com.insyd.vaulta/clipboard"
        private const val TAG = "Vaulta/Clipboard"
        private const val CLIP_LABEL = "Vaulta"
        private const val LEGACY_EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
