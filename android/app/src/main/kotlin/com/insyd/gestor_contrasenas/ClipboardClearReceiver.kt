package com.insyd.gestor_contrasenas

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Fires from the inexact backup alarm armed by
 * [SensitiveClipboard.copy] and clears a Vaulta secret still on the
 * clipboard. Declared `exported="false"`: only this app's own
 * PendingIntent can reach it.
 */
class ClipboardClearReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            val cleared = SensitiveClipboard.clearIfOwned(context, fromAlarm = true)
            Log.i(TAG, "backup clear ran, cleared=$cleared")
        } catch (e: Throwable) {
            Log.w(TAG, "backup clear failed: ${e.javaClass.simpleName}")
        }
    }

    private companion object {
        const val TAG = "Vaulta/Clipboard"
    }
}
