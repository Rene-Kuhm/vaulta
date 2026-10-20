package com.insyd.gestor_contrasenas

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PersistableBundle
import android.os.SystemClock
import java.security.SecureRandom

/**
 * Copy-and-clear logic for secrets on the system clipboard, shared by
 * [ClipboardChannel] (Dart calls) and [ClipboardClearReceiver] (the
 * native backup alarm).
 *
 * Copy:
 *   * The clip is labeled [CLIP_LABEL] and its description extras get
 *     `IS_SENSITIVE = true` so keyboards and the Android 13+ clipboard
 *     preview hide it: [ClipDescription.EXTRA_IS_SENSITIVE] on API 33+,
 *     the literal `"android.content.extra.IS_SENSITIVE"` key on 24-32
 *     (Google's documented recommendation). `ClipDescription.setExtras`
 *     is API 24, so on API 23 the clip carries no extras.
 *   * Ownership is tracked with a random per-copy token, written into
 *     the clip extras and into private SharedPreferences. Nothing
 *     derived from the secret is persisted: a stored hash of a
 *     password would be an offline guessing oracle, a random token is
 *     not. The token survives process death so the alarm can still
 *     tell our clip apart.
 *   * An inexact `AlarmManager.set(ELAPSED_REALTIME, …)` alarm is
 *     scheduled for the clear delay. Android 12+ freezes cached apps,
 *     so the Dart timer alone may not run until the user returns; the
 *     alarm wakes the receiver instead. No exact-alarm permission is
 *     needed. The Dart timer remains the foreground path.
 *
 * Clear if owned (idempotent; whichever of the Dart timer, lock or the
 * alarm runs first wins, the rest are no-ops):
 *   * The alarm is cancelled and the token deleted in every case.
 *   * Clipboard readable and the clip is not ours -> left alone.
 *   * Clipboard readable and ours, or unreadable (Android 10+ hides
 *     the clipboard from background apps) -> cleared with
 *     `clearPrimaryClip()` on API 28+, an empty clip on 23-27.
 *   * No token stored: a Dart call returns false (nothing pending).
 *     The alarm path (token lost) clears only if the clip is
 *     unreadable or labeled [CLIP_LABEL].
 *
 * The clipped text is never logged or persisted.
 */
object SensitiveClipboard {
    /** Label of every clip Vaulta writes. */
    const val CLIP_LABEL = "vaulta-secret"

    private const val LEGACY_EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    private const val EXTRA_OWNER_TOKEN = "com.insyd.vaulta.CLIP_TOKEN"
    private const val PREFS_NAME = "vaulta_sensitive_clipboard"
    private const val PREF_TOKEN = "owned_clip_token"
    private const val ALARM_REQUEST_CODE = 0x5EC

    private val random = SecureRandom()

    /** Copies [text] flagged as sensitive and arms the backup clear. */
    fun copy(context: Context, text: String, clearAfterMs: Long) {
        val app = context.applicationContext
        val token = newToken()
        val clip = ClipData.newPlainText(CLIP_LABEL, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            clip.description.extras = PersistableBundle().apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                } else {
                    putBoolean(LEGACY_EXTRA_IS_SENSITIVE, true)
                }
                putString(EXTRA_OWNER_TOKEN, token)
            }
        }
        // Persist the token before the clip exists so a crash in
        // between can only leave a token without a clip (harmless).
        prefs(app).edit().putString(PREF_TOKEN, token).commit()
        clipboard(app).setPrimaryClip(clip)
        scheduleAlarm(app, clearAfterMs)
    }

    /**
     * Clears our clip if it is still there. [fromAlarm] selects the
     * stricter "token lost" rule described on [SensitiveClipboard].
     * Returns true when the clipboard was cleared.
     */
    fun clearIfOwned(context: Context, fromAlarm: Boolean): Boolean {
        val app = context.applicationContext
        cancelAlarm(app)
        val prefs = prefs(app)
        val token = prefs.getString(PREF_TOKEN, null)
        prefs.edit().remove(PREF_TOKEN).commit()

        val manager = clipboard(app)
        // Null when the clipboard is empty or hidden from a background
        // app (Android 10+); both are safe to clear.
        val current = manager.primaryClip
        if (current != null) {
            val description = current.description
            val labeled = description?.label?.toString() == CLIP_LABEL
            val ours = when {
                token == null -> fromAlarm && labeled
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.N ->
                    labeled && description?.extras?.getString(EXTRA_OWNER_TOKEN) == token
                else -> labeled
            }
            if (!ours) return false
        } else if (token == null && !fromAlarm) {
            return false
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.clearPrimaryClip()
        } else {
            manager.setPrimaryClip(ClipData.newPlainText("", ""))
        }
        return true
    }

    private fun scheduleAlarm(context: Context, delayMs: Long) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.set(
            AlarmManager.ELAPSED_REALTIME,
            SystemClock.elapsedRealtime() + delayMs,
            alarmIntent(context, PendingIntent.FLAG_UPDATE_CURRENT)!!,
        )
    }

    private fun cancelAlarm(context: Context) {
        val pending = alarmIntent(context, PendingIntent.FLAG_NO_CREATE) ?: return
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.cancel(pending)
        pending.cancel()
    }

    private fun alarmIntent(context: Context, flags: Int): PendingIntent? =
        PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST_CODE,
            Intent(context, ClipboardClearReceiver::class.java),
            flags or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun clipboard(context: Context): ClipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun newToken(): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
