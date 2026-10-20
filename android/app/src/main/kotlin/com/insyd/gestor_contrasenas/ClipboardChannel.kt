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
import java.security.MessageDigest

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
 * `ClipDescription.setExtras` exists from API 24 (N); on API 23 the
 * clip is copied without the flag.
 *
 * `clearSensitive` implements "clear if owned". Vaulta remembers only
 * a SHA-256 of the last secret it copied (never the text):
 *   * clipboard readable and holds a different clip -> leave it, the
 *     user copied something else;
 *   * clipboard readable and holds our clip -> clear it;
 *   * clipboard unreadable (Android 10+ returns null to background
 *     apps) -> clear it, because we cannot prove it is not ours and
 *     the Dart timer usually fires after the user switched apps.
 * Clearing uses `clearPrimaryClip()` on API 28+ and an empty clip on
 * 23-27. The Dart side decides when to call it (30 s timer, lock).
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
                try {
                    copySensitive(text)
                    result.success(null)
                } catch (e: Throwable) {
                    Log.w(TAG, "copySensitive failed: ${e.javaClass.simpleName}")
                    result.error("CLIPBOARD_FAILED", e.javaClass.simpleName, null)
                }
            }
            "clearSensitive" -> {
                try {
                    result.success(clearSensitive())
                } catch (e: Throwable) {
                    Log.w(TAG, "clearSensitive failed: ${e.javaClass.simpleName}")
                    result.error("CLIPBOARD_FAILED", e.javaClass.simpleName, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun clipboard(): ClipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private fun copySensitive(text: String) {
        val clip = ClipData.newPlainText(CLIP_LABEL, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            clip.description.extras = PersistableBundle().apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                } else {
                    putBoolean(LEGACY_EXTRA_IS_SENSITIVE, true)
                }
            }
        }
        clipboard().setPrimaryClip(clip)
        ownedHash = sha256(text)
    }

    /** Returns true when the clipboard was cleared. */
    private fun clearSensitive(): Boolean {
        val expected = ownedHash ?: return false
        ownedHash = null
        val manager = clipboard()
        // Null when the clipboard is empty or when Android 10+ hides it
        // from a background app; both cases are safe to clear.
        val current = manager.primaryClip
        if (current != null) {
            val label = current.description?.label?.toString()
            val text = if (current.itemCount > 0) {
                current.getItemAt(0).text?.toString()
            } else {
                null
            }
            val ours = label == CLIP_LABEL && text != null &&
                MessageDigest.isEqual(sha256(text), expected)
            if (!ours) return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.clearPrimaryClip()
        } else {
            manager.setPrimaryClip(ClipData.newPlainText("", ""))
        }
        return true
    }

    private fun sha256(text: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))

    companion object {
        const val CHANNEL_NAME = "com.insyd.vaulta/clipboard"
        private const val TAG = "Vaulta/Clipboard"
        private const val CLIP_LABEL = "vaulta-secret"

        /**
         * SHA-256 of the last secret Vaulta copied, or null when none
         * is pending. Process-wide so a recreated engine/channel still
         * knows what it owns.
         */
        @Volatile
        private var ownedHash: ByteArray? = null
        private const val LEGACY_EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
