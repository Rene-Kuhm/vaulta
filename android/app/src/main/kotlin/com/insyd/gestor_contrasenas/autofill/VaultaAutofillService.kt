package com.insyd.gestor_contrasenas.autofill

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Intent
import android.content.IntentSender
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.util.Log
import android.view.View
import android.view.autofill.AutofillId
import android.widget.RemoteViews

/**
 * Vaulta's autofill entry point (ADR-008, slice A).
 *
 * This slice declares the binding and proves the *locked* half of the
 * two-phase answer and nothing else:
 *
 *   * [onFillRequest] always answers with zero datasets plus an
 *     authentication intent, which is the correct answer while the vault
 *     is locked and is the only answer this slice implements. There is no
 *     session, no vault read and no matching here: building datasets is a
 *     later slice behind its own review.
 *   * [onSaveRequest] is a deliberate no-op; see the comment there.
 *
 * What must stay true of this file:
 *
 *   * No secret, no title, no username and no item count ever reaches the
 *     system. The authentication presentation is a static label, because
 *     Android renders that surface outside this process and screenshots it
 *     are possible (ADR-008 §1).
 *   * Nothing is written to disk and no network call is made (ADR-008 §6).
 *   * No Flutter engine is started here. A system-started service has no
 *     engine and this slice does not need one; the service runs in the app
 *     process, so it inherits the process's lock policy and nothing more
 *     (ADR-008 §4).
 */
class VaultaAutofillService : AutofillService() {

    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback,
    ) {
        val structure = request.fillContexts.lastOrNull()?.structure
        // Package of the app being filled. Logged (ADR-008 §6 allows the
        // requester package) and never sent anywhere else.
        val requester = structure?.activityComponent?.packageName
        try {
            val ids = if (structure == null) emptyArray() else collectAutofillIds(structure)
            if (ids.isEmpty()) {
                // Nothing in this screen can be autofilled, so there is
                // nothing to unlock for. setAuthentication() rejects an empty
                // id array, and answering "no response" is the honest result:
                // the system shows no Vaulta affordance at all.
                Log.i(TAG, "fill request package=$requester answer=no-fields")
                callback.onSuccess(null)
                return
            }

            val response = FillResponse.Builder()
                // Zero datasets: while the vault is locked there is no data to
                // offer. The authentication intent is the entire answer, and
                // the system calls onFillRequest() again once the user has
                // authenticated.
                .setAuthentication(ids, unlockIntentSender(), unlockPresentation())
                .build()

            Log.i(TAG, "fill request package=$requester answer=locked")
            callback.onSuccess(response)
        } catch (e: Throwable) {
            // Never forward the exception text to the fill UI: it is built
            // from requester-supplied structure data.
            Log.w(TAG, "fill request package=$requester failed=${e.javaClass.simpleName}")
            callback.onFailure(FAILURE_MESSAGE)
        }
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        // Saving is not implemented on purpose. Capturing a credential the
        // user typed into *another* app is a separate change with its own
        // review: it needs validation before anything is stored, a decision
        // about the locked state at save time, and its own audit of what
        // leaves the requesting app. Until then the service answers "handled,
        // nothing saved" so the system does not keep re-offering the prompt.
        Log.i(TAG, "save request package=${request.fillContexts.lastOrNull()?.structure?.activityComponent?.packageName} answer=ignored")
        callback.onSuccess()
    }

    /**
     * Intent that shows [AutofillUnlockActivity] when the user taps the
     * authentication affordance.
     *
     * `FLAG_MUTABLE` is required, not an oversight: the platform fills the
     * authentication arguments (dataset id, client state) into this intent
     * before launching it, and an immutable PendingIntent would drop them.
     * The intent is explicit and the activity is not exported, so only the
     * PendingIntent holder (the autofill framework) can start it. The stub
     * activity reads none of the filled-in extras, so nothing the requesting
     * app supplies can influence what is shown.
     */
    private fun unlockIntentSender(): IntentSender {
        val intent = Intent(this, AutofillUnlockActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(
            this,
            REQUEST_CODE_UNLOCK,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        ).intentSender
    }

    /**
     * Static label for the authentication affordance. The platform's own
     * single-line list item is used as the RemoteViews layout so this slice
     * adds no resource of its own, and the text is a constant: a title, a
     * username or an item count here would leak vault data to a surface the
     * system draws and can be screenshotted.
     */
    private fun unlockPresentation(): RemoteViews =
        RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, UNLOCK_LABEL)
        }

    /**
     * Autofill ids of the views the platform can attach the authentication UI
     * to. Only fields that advertise themselves as autofillable are collected
     * — this is not matching against the vault, which is a later slice.
     */
    private fun collectAutofillIds(structure: AssistStructure): Array<AutofillId> {
        val ids = ArrayList<AutofillId>()
        for (i in 0 until structure.windowNodeCount) {
            collectAutofillIds(structure.getWindowNodeAt(i).rootViewNode, ids)
        }
        return ids.toTypedArray()
    }

    private fun collectAutofillIds(node: AssistStructure.ViewNode, out: MutableList<AutofillId>) {
        // autofillId is null for nodes the platform does not consider fillable.
        val autofillId = node.autofillId
        if (autofillId != null && node.autofillType != View.AUTOFILL_TYPE_NONE) {
            out.add(autofillId)
        }
        for (i in 0 until node.childCount) {
            collectAutofillIds(node.getChildAt(i), out)
        }
    }

    private companion object {
        const val TAG = "Vaulta/Autofill"

        /**
         * The only text this slice ever shows in the system's fill UI. Keep it
         * free of vault data (ADR-008 §1) and keep it a constant.
         */
        const val UNLOCK_LABEL = "Unlock Vaulta"

        const val FAILURE_MESSAGE = "Vaulta could not answer this fill request"

        const val REQUEST_CODE_UNLOCK = 1
    }
}
