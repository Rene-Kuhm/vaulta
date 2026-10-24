package com.insyd.gestor_contrasenas.autofill

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.insyd.gestor_contrasenas.MainActivity
import com.insyd.gestor_contrasenas.R

/**
 * The screen behind the fill UI's "Unlock Vaulta" affordance (ADR-008 §1, §2).
 *
 * It unlocks nothing itself. Unlocking is the app's existing path —
 * [MainActivity] owns the single Flutter engine, the unlock screen, the
 * Keystore envelope, the biometric prompt policy and the attempt limiter — and
 * a second engine here would have its own Dart heap and could not see that
 * session (ADR-008 §1b). So this activity does exactly three things:
 *
 *   1. Marks its own window [WindowManager.LayoutParams.FLAG_SECURE] before any
 *      content is attached, and starts [MainActivity] so the user unlocks in the
 *      real app UI.
 *   2. Polls [VaultaAutofillBridge.requestStatus] at a modest interval — the
 *      bridge holds a channel handle and no session, so every answer is read
 *      fresh from the live vault in Dart (ADR-008 §4).
 *   3. Finishes as soon as the vault reports unlocked, so the framework
 *      re-issues the fill request, and this time the service has datasets to
 *      return. It also finishes on a bounded timeout, because a fill flow that
 *      hangs is worse than a fill flow that returns the unlock affordance again.
 *
 * Finishing without unlocking is a valid, expected outcome: the next fill
 * request simply answers with the authentication affordance from ADR-008 §1.
 *
 * Everything this class holds is a Handler, a deadline and a boolean — no
 * session, no candidate, no last result, nothing that could outlive the wait.
 *
 * The one thing that must never be lost:
 * [WindowManager.LayoutParams.FLAG_SECURE] is set in [onCreate] before any
 * content is attached. This is the only screen in the product that a
 * screenshot could capture next to a credential.
 *
 * It is deliberately built with plain platform views instead of a layout
 * resource, so this package still adds nothing under res/ beyond the autofill
 * metadata. The text it shows is static: nothing the requesting app supplies
 * can change what is displayed, and no title, username, secret or URL ever
 * appears here.
 */
class AutofillUnlockActivity : Activity() {

    private val handler = Handler(Looper.getMainLooper())

    /**
     * The requesting package, used for the `package + outcome` log line and for
     * nothing else: it never reaches the screen, and no branch reads it.
     */
    private var requesterPackage: String = UNKNOWN_PACKAGE

    /** `SystemClock.elapsedRealtime()` after which the wait is over, unlocked or not. */
    private var deadlineElapsedMs = 0L

    /** True once [MainActivity] was started, so the poll loop launches it once. */
    private var appStarted = false

    /**
     * Set when an outcome was logged. Cleared on destroy without one, which is
     * what happens when the autofill framework finishes this activity itself
     * instead of letting it reach [finishWith]. Without this line the flow ends
     * silently and the next person debugging it has no trail at all.
     */
    private var outcomeLogged = false

    private val pollTask = Runnable { poll() }
    private val timeoutTask = Runnable { finishWith(OUTCOME_TIMEOUT) }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super.onCreate and before any content: the flag must be on the
        // window by the time this activity is composed.
        applyScreenProtection()
        super.onCreate(savedInstanceState)
        setContentView(buildMessageView())
        // Set by the service that built the authentication intent; absent when
        // the system or a test started this activity some other way.
        requesterPackage = intent
            ?.getStringExtra(EXTRA_REQUESTER_PACKAGE)
            ?.takeIf { it.isNotBlank() }
            ?: UNKNOWN_PACKAGE
        deadlineElapsedMs = SystemClock.elapsedRealtime() + TOTAL_WAIT_MS
        // The deadline is a separate runnable on purpose: if a channel answer
        // never arrives, the poll loop is simply not rescheduled, and this is
        // what still ends the wait. Nothing here can hang.
        handler.postDelayed(timeoutTask, TOTAL_WAIT_MS)
        Log.i(TAG, "unlock activity start package=$requesterPackage")
        // Probe before starting the app UI: a fill request can arrive right
        // after the user unlocked in the app, and yanking the app to the front
        // again would be a pointless interruption.
        poll()
    }

    override fun onDestroy() {
        handler.removeCallbacks(pollTask)
        handler.removeCallbacks(timeoutTask)
        if (!outcomeLogged) {
            Log.i(TAG, "unlock activity package=$requesterPackage answer=system-finished")
        }
        super.onDestroy()
    }

    /**
     * One status probe. Never blocking: the bridge answers on the main thread,
     * and the chain continues from [schedulePoll] or from [finishWith].
     */
    private fun poll() {
        // No work for an activity that is already on its way out, and no answer
        // is worth delivering to it.
        if (isFinishing || isDestroyed) return
        // The timeout runnable normally fires first; this covers a poll that
        // arrives after the deadline because the main thread was busy.
        if (SystemClock.elapsedRealtime() >= deadlineElapsedMs) {
            finishWith(OUTCOME_TIMEOUT)
            return
        }

        if (!VaultaAutofillBridge.isAvailable) {
            // No channel handle: the process has no engine, so there is nothing
            // to read and nobody else is going to start one. Bring the app up —
            // it creates and owns the one engine — and keep waiting for its
            // answer.
            launchVaulta()
            schedulePoll()
            return
        }

        VaultaAutofillBridge.requestStatus { unlocked ->
            if (isFinishing || isDestroyed) return@requestStatus
            when (unlocked) {
                true -> finishWith(OUTCOME_UNLOCKED)
                false -> {
                    // Locked: the app UI is the only place that can change that.
                    launchVaulta()
                    schedulePoll()
                }
                // The bridge could not read an answer. That is not "locked" and
                // not "unlocked", so it is neither reported nor acted on: keep
                // waiting, and let the deadline end the flow if it never comes.
                null -> schedulePoll()
            }
        }
    }

    private fun schedulePoll() {
        handler.removeCallbacks(pollTask)
        handler.postDelayed(pollTask, POLL_INTERVAL_MS)
    }

    /**
     * Starts the real app UI, once. [MainActivity] is not exported and this is
     * the same app, so the explicit intent is all that is needed. `NEW_TASK`
     * keeps the app in its own task instead of stacking a second copy of the
     * Flutter activity inside the autofill task.
     */
    private fun launchVaulta() {
        if (appStarted) return
        appStarted = true
        Log.i(TAG, "unlock activity package=$requesterPackage launching=app-ui")
        try {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: Throwable) {
            // Without the app UI there is nothing to unlock and no point in
            // waiting out the deadline.
            Log.w(TAG, "unlock activity package=$requesterPackage launch-failed=${e.javaClass.simpleName}")
            appStarted = false
            finishWith(OUTCOME_FAILED)
        }
    }

    /**
     * Ends the flow. Safe to call from the deadline, from a status answer, or
     * twice: the second call is a no-op, and nothing is logged for an activity
     * that was already finishing.
     */
    private fun finishWith(outcome: String) {
        handler.removeCallbacks(pollTask)
        handler.removeCallbacks(timeoutTask)
        if (isFinishing || isDestroyed) return
        Log.i(TAG, "unlock activity package=$requesterPackage answer=$outcome")
        outcomeLogged = true
        finish()
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
            setTextColor(ContextCompat.getColor(this.context, colorRes))
        }

    companion object {
        /**
         * Extra carrying the requesting package from
         * `VaultaAutofillService.unlockIntentSender`. Logged, never displayed.
         */
        const val EXTRA_REQUESTER_PACKAGE =
            "com.insyd.gestor_contrasenas.autofill.extra.REQUESTER_PACKAGE"

        private const val TAG = "Vaulta/Autofill"

        /**
         * Static copy, kept as constants on purpose: this package owns no file
         * under res/values, and none of this text may depend on the request.
         */
        private const val MESSAGE_TITLE = "Unlock Vaulta"
        private const val MESSAGE_HINT = "Finish unlocking in Vaulta to fill this login."

        /**
         * The whole wait is bounded. Unlocking takes seconds; anything past a
         * minute means the user walked away, and the next fill request will show
         * the affordance again.
         */
        private const val TOTAL_WAIT_MS = 60_000L

        /** Modest interval: fast enough to feel immediate, cheap enough to ignore. */
        private const val POLL_INTERVAL_MS = 750L

        private const val MESSAGE_PADDING_DP = 24

        private const val UNKNOWN_PACKAGE = "unknown"

        private const val OUTCOME_UNLOCKED = "unlocked"
        private const val OUTCOME_TIMEOUT = "timeout"
        private const val OUTCOME_FAILED = "failed"
    }
}
