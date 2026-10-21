package com.insyd.gestor_contrasenas.autofill

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.insyd.gestor_contrasenas.R

/**
 * Stub of the unlock screen the autofill flow will use (ADR-008 §2).
 *
 * Slice A only proves the locked contract, so this activity does not unlock
 * anything: it shows a static message and finishes. Slice B replaces the body
 * with the existing unlock path ([com.insyd.gestor_contrasenas.BiometricChannel]
 * / the master-password fallback) so the Keystore envelope, the prompt policy
 * and the attempt limiter stay the single implementation the app already uses.
 *
 * It is deliberately built with plain platform views instead of a layout
 * resource, so this slice adds nothing under res/ beyond the autofill metadata.
 *
 * The one thing that must not be lost when slice B lands:
 * [WindowManager.LayoutParams.FLAG_SECURE] is set in [onCreate] before any
 * content is attached. This is the only screen in the product that a
 * screenshot could capture next to a credential.
 *
 * The intent that starts it is filled in by the platform with the
 * authentication arguments. This stub reads none of them, so nothing the
 * requesting app supplies can change what is displayed.
 */
class AutofillUnlockActivity : Activity() {

    private val handler = Handler(Looper.getMainLooper())
    private val finishTask = Runnable { finish() }

    override fun onCreate(savedInstanceState: Bundle?) {
        applyScreenProtection()
        super.onCreate(savedInstanceState)
        setContentView(buildMessageView())
        // Long enough to read the message, short enough that the stub does not
        // sit on screen: there is no input to collect here yet.
        handler.postDelayed(finishTask, MESSAGE_DURATION_MS)
    }

    override fun onDestroy() {
        handler.removeCallbacks(finishTask)
        super.onDestroy()
    }

    private fun applyScreenProtection() {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    }

    private fun buildMessageView(): LinearLayout {
        val padding = (MESSAGE_PADDING_DP * resources.displayMetrics.density).toInt()
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(padding, padding, padding, padding)
            setBackgroundColor(ContextCompat.getColor(context, R.color.vaulta_paper))
            addView(messageText(MESSAGE_TITLE, 18f, R.color.vaulta_ink))
            addView(messageText(MESSAGE_HINT, 14f, R.color.vaulta_ink))
        }
    }

    private fun messageText(text: String, sizeSp: Float, colorRes: Int): TextView =
        TextView(this).apply {
            this.text = text
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            setTextColor(ContextCompat.getColor(context, colorRes))
        }

    private companion object {
        /**
         * Stub copy, kept as constants on purpose: this slice owns no file
         * under res/values, so the strings move to a localized resource when
         * slice B implements the real unlock screen.
         */
        const val MESSAGE_TITLE = "Unlock in Vaulta"
        const val MESSAGE_HINT = "Vaulta unlocks with your biometrics before it fills anything."

        const val MESSAGE_DURATION_MS = 2_000L
        const val MESSAGE_PADDING_DP = 24
    }
}
