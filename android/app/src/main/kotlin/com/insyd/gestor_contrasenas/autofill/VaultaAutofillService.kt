package com.insyd.gestor_contrasenas.autofill

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Intent
import android.content.IntentSender
import android.content.pm.verify.domain.DomainVerificationManager
import android.content.pm.verify.domain.DomainVerificationUserState
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.text.InputType
import android.util.Log
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Vaulta's autofill entry point (ADR-008).
 *
 * The service answers a fill request in one of three ways, and the order in
 * which it decides is the design:
 *
 *   * **The app can answer and has a match** → datasets built from the bridge
 *     answer, one per candidate, with the username in the username fields and
 *     the secret in the password fields.
 *   * **The app can answer and has no match** → the single "search in Vaulta"
 *     marker and no item. Never a guess: an autofill menu that offers the wrong
 *     vault entry next to a bank login is a phishing assist (ADR-008 §3).
 *   * **Nothing can answer** (no engine handle, vault locked, channel error) →
 *     the locked contract from the previous slice: zero datasets and an
 *     authentication intent.
 *
 * The data comes from Dart, over [VaultaAutofillBridge], from the app's single
 * engine. This file contains no decryption, no key handling and no storage: the
 * vault is answered by the `VaultRepository` that already exists, and this
 * process must not grow a second view of it.
 *
 * Which host a request is matched against is decided in one order, and the
 * order is the decision (ADR-008 §3): the exact host the structure reports
 * first, then the requesting package's own **verified** web domains, then the
 * search marker. The middle step never guesses — see [verifiedHostFor] — because
 * an autofill menu that offers the wrong credential is a phishing assist.
 *
 * What must stay true of this file:
 *
 *   * No secret, no title, no username and no URL ever reaches the system's
 *     authentication surface. That presentation is a static label, because
 *     Android renders it outside this process and screenshots are possible
 *     (ADR-008 §1). Dataset labels do carry the item title and username: that
 *     is the fill UI the user is choosing from, which is the one place they
 *     belong.
 *   * Nothing is logged except the requesting package and the outcome
 *     (ADR-008 §6), and nothing is cached: a dataset is built from one answer
 *     to one request and dropped when the request ends (ADR-008 §4).
 *   * Nothing is written to disk and no network call is made.
 *
 * The whole file targets API 26+, which is the level the autofill framework
 * starts at; the platform cannot bind this service below that.
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
            val fields = if (structure == null) null else collectFields(structure)
            if (fields == null || fields.autofillIds.isEmpty()) {
                // Nothing in this screen can be autofilled, so there is
                // nothing to unlock for. setAuthentication() rejects an empty
                // id array, and answering "no response" is the honest result:
                // the system shows no Vaulta affordance at all.
                Log.i(TAG, "fill request package=$requester answer=no-fields")
                callback.onSuccess(null)
                return
            }

            // Which host the query runs against. The exact host a browser
            // reports always wins; package resolution only runs when the
            // structure has none, so it can never override a precise answer
            // with a broader one (ADR-008 §3). `null` here means "we do not
            // know which site this is", which the app answers with the search
            // marker.
            val host = fields.host ?: verifiedHostFor(requester)
            val match = when {
                fields.host != null -> MATCH_HOST
                host != null -> MATCH_PACKAGE
                else -> MATCH_NONE
            }

            // The framework hands the request to the main thread, and the
            // channel answers on it too, so this flag is only guarding against
            // a cancellation racing an answer.
            val answered = AtomicBoolean(false)
            cancellationSignal.setOnCancelListener {
                answered.set(true)
                Log.i(TAG, "fill request package=$requester answer=cancelled")
            }

            if (!VaultaAutofillBridge.isAvailable) {
                // No engine handle: the app is not running, so there is no
                // session to read, and the correct answer is the locked one.
                answered.set(true)
                Log.i(TAG, "fill request package=$requester match=$match answer=locked")
                callback.onSuccess(lockedResponse(fields, requester.orEmpty()))
                return
            }

            VaultaAutofillBridge.query(host, requester.orEmpty()) { answer ->
                if (!answered.compareAndSet(false, true)) return@query
                try {
                    if (answer == null || answer.isLocked) {
                        Log.i(TAG, "fill request package=$requester match=$match answer=locked")
                        callback.onSuccess(lockedResponse(fields, requester.orEmpty()))
                    } else if (answer.isSearchOnly || !fields.hasWritableFields) {
                        // Open vault, no host match — or a screen with nothing
                        // to write a credential into. Both end in the same
                        // honest affordance: one marker, no item.
                        Log.i(TAG, "fill request package=$requester match=$match answer=search-only")
                        callback.onSuccess(searchResponse(fields, requester.orEmpty()))
                    } else {
                        Log.i(TAG, "fill request package=$requester match=$match answer=matched")
                        callback.onSuccess(
                            matchedResponse(fields, answer.candidates, requester.orEmpty()),
                        )
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "fill request package=$requester answer=failed ${e.javaClass.simpleName}")
                    callback.onFailure(FAILURE_MESSAGE)
                }
            }
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

    // ---- Responses ----

    /**
     * Zero datasets plus the authentication intent. This is the whole answer
     * while the vault is locked, and it is also the answer to any failure: the
     * user sees the unlock affordance, nothing about the vault.
     */
    private fun lockedResponse(fields: FillFields, requester: String): FillResponse =
        FillResponse.Builder()
            .setAuthentication(
                fields.autofillIds.toTypedArray(),
                unlockIntentSender(requester),
                unlockPresentation(),
            )
            .build()

    /**
     * The "search in Vaulta" marker: zero datasets plus one affordance whose
     * label names the action, never the vault. Tapping it opens Vaulta for this
     * app; the picker itself is slice C work behind the same activity.
     *
     * It is deliberately the same shape as [lockedResponse] — the framework's
     * response-level authentication affordance is the one surface that can
     * launch an activity from a fill response, so both answers use it and only
     * the label differs.
     */
    private fun searchResponse(fields: FillFields, requester: String): FillResponse =
        FillResponse.Builder()
            .setAuthentication(
                fields.autofillIds.toTypedArray(),
                unlockIntentSender(requester),
                searchPresentation(),
            )
            .build()

    /** One dataset per candidate, built only from the vault answer. */
    private fun matchedResponse(
        fields: FillFields,
        candidates: List<AutofillCandidate>,
        requester: String,
    ): FillResponse {
        val builder = FillResponse.Builder()
        var built = 0
        for (candidate in candidates) {
            val dataset = buildDataset(fields, candidate) ?: continue
            builder.addDataset(dataset)
            built++
        }
        // An empty response shows no affordance at all, so a match that turned
        // out to carry nothing writable falls back to the marker.
        if (built == 0) return searchResponse(fields, requester)
        return builder.build()
    }

    /**
     * Builds one dataset, or `null` when it would carry nothing to write.
     *
     * Empty values are skipped rather than written: `AutofillValue.forText("")`
     * would clear a username the user already typed, and an entry with no
     * username or no secret is a real vault state, not an error.
     */
    private fun buildDataset(fields: FillFields, candidate: AutofillCandidate): Dataset? {
        val fillUsername = candidate.username.isNotEmpty() && fields.usernameIds.isNotEmpty()
        val fillSecret = candidate.secret.isNotEmpty() && fields.passwordIds.isNotEmpty()
        if (!fillUsername && !fillSecret) return null

        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_2).apply {
            setTextViewText(android.R.id.text1, candidate.label)
            setTextViewText(android.R.id.text2, candidate.username)
        }
        val builder = Dataset.Builder(presentation)
        if (fillUsername) {
            val usernameValue = AutofillValue.forText(candidate.username)
            for (id in fields.usernameIds) {
                builder.setValue(id, usernameValue)
            }
        }
        if (fillSecret) {
            val secretValue = AutofillValue.forText(candidate.secret)
            for (id in fields.passwordIds) {
                builder.setValue(id, secretValue)
            }
        }
        return builder.build()
    }

    /**
     * Intent that shows [AutofillUnlockActivity] when the user taps the
     * authentication affordance or the search marker.
     *
     * `FLAG_MUTABLE` is required, not an oversight: the platform fills the
     * authentication arguments (dataset id, client state) into this intent
     * before launching it, and an immutable PendingIntent would drop them.
     * The intent is explicit and the activity is not exported, so only the
     * PendingIntent holder (the autofill framework) can start it. The activity
     * reads no vault-shaped extra and nothing the requesting app supplies can
     * influence what is shown: [AutofillUnlockActivity.EXTRA_REQUESTER_PACKAGE]
     * is the requester's own package name, filled in here, and it is used for
     * one log line and for nothing else (ADR-008 §6).
     */
    private fun unlockIntentSender(requester: String): IntentSender {
        val intent = Intent(this, AutofillUnlockActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(AutofillUnlockActivity.EXTRA_REQUESTER_PACKAGE, requester)
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

    /** Static label for the search-only affordance. Same rule: a constant. */
    private fun searchPresentation(): RemoteViews =
        RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, SEARCH_LABEL)
        }

    // ---- Reading the request structure ----

    /**
     * The parts of the requesting screen this service uses: the ids the
     * platform can attach UI to, the ids worth writing a credential into, and
     * the web domain the platform reported, if any.
     */
    private class FillFields(
        val autofillIds: List<AutofillId>,
        val usernameIds: List<AutofillId>,
        val passwordIds: List<AutofillId>,
        val host: String?,
    ) {
        /** True when at least one field can receive a credential. */
        val hasWritableFields: Boolean
            get() = usernameIds.isNotEmpty() || passwordIds.isNotEmpty()
    }

    /**
     * Walks the structure once and classifies what it finds.
     *
     * Only fields that advertise themselves as autofillable are collected. A
     * text field that is not a password field counts as a username field,
     * which is the safe default: the username is not the secret, so a wrong
     * guess there costs an edit, while a secret in the wrong field is a
     * disclosure.
     */
    private fun collectFields(structure: AssistStructure): FillFields {
        val all = ArrayList<AutofillId>()
        val username = ArrayList<AutofillId>()
        val password = ArrayList<AutofillId>()
        for (i in 0 until structure.windowNodeCount) {
            collectFields(structure.getWindowNodeAt(i).rootViewNode, all, username, password)
        }
        return FillFields(
            autofillIds = all,
            usernameIds = username,
            passwordIds = password,
            host = requestedHost(structure),
        )
    }

    private fun collectFields(
        node: AssistStructure.ViewNode,
        all: MutableList<AutofillId>,
        username: MutableList<AutofillId>,
        password: MutableList<AutofillId>,
    ) {
        // autofillId is null for nodes the platform does not consider fillable.
        val autofillId = node.autofillId
        val autofillType = node.autofillType
        if (autofillId != null && autofillType != View.AUTOFILL_TYPE_NONE) {
            all.add(autofillId)
            if (autofillType == View.AUTOFILL_TYPE_TEXT) {
                if (isPasswordField(node)) {
                    password.add(autofillId)
                } else {
                    username.add(autofillId)
                }
            }
        }
        for (i in 0 until node.childCount) {
            collectFields(node.getChildAt(i), all, username, password)
        }
    }

    /** True for a masked text field, whether it advertises a hint or not. */
    private fun isPasswordField(node: AssistStructure.ViewNode): Boolean {
        val hints = node.autofillHints
        if (hints != null && hints.any { it == View.AUTOFILL_HINT_PASSWORD }) return true
        val inputType = node.inputType
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (inputType and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT ->
                variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            InputType.TYPE_CLASS_NUMBER ->
                variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    /**
     * The web domain the platform reported for this request, taken from the web
     * views in the structure (the activity itself only carries the requester
     * package). `null` for a native app with no web view, which is where
     * [verifiedHostFor] gets its turn and the search marker is the floor.
     */
    private fun requestedHost(structure: AssistStructure): String? {
        for (i in 0 until structure.windowNodeCount) {
            val host = webDomainOf(structure.getWindowNodeAt(i).rootViewNode)
            if (!host.isNullOrBlank()) return host
        }
        return null
    }

    private fun webDomainOf(node: AssistStructure.ViewNode): String? {
        val host = node.webDomain
        if (!host.isNullOrBlank()) return host
        for (i in 0 until node.childCount) {
            val childHost = webDomainOf(node.getChildAt(i))
            if (!childHost.isNullOrBlank()) return childHost
        }
        return null
    }

    /**
     * The host of [requestingPackage]'s **verified** web domain, or `null`.
     *
     * This is ADR-008 §3's second matching step and the only package→host
     * mapping this service accepts. It is deliberately narrow:
     *
     *   * The platform API that owns the mapping, `DomainVerificationManager`
     *     (API 31+), is asked for the requesting package's state, and only hosts
     *     in [DomainVerificationUserState.DOMAIN_STATE_VERIFIED] come back. A
     *     host that is merely *declared* in a manifest proves nothing: any app
     *     can declare `bank.com`, and handing it the bank credential is exactly
     *     the phishing assist ADR-008 §3 rejects.
     *   * Below API 31 the platform exposes no verified mapping, so the answer is
     *     `null` and the flow degrades to the search marker. It does not fall
     *     back to declared hosts, intent filters or the package name.
     *   * No substring, no suffix, no similarity on the item's website and no
     *     comparison between a package name and a domain. A miss costs a tap; a
     *     wrong suggestion costs a credential.
     *
     * A package may verify several domains, and the bridge takes one host, so
     * the first in sort order is used: the choice is deterministic instead of
     * depending on map order, and an item indexed under another of those domains
     * still degrades to the search marker rather than to a guess.
     *
     * The system is free to refuse the query — this is an ordinary app, not the
     * domain verifier, and package visibility can hide the requester — so every
     * failure becomes `null`, the honest "we do not know". The requester package
     * and the outcome are logged; the host never is (ADR-008 §6).
     */
    private fun verifiedHostFor(requestingPackage: String?): String? {
        if (requestingPackage.isNullOrBlank()) return null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return verifiedHostsOf(requestingPackage).firstOrNull()
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun verifiedHostsOf(requestingPackage: String): List<String> =
        try {
            val state = getSystemService(DomainVerificationManager::class.java)
                ?.getDomainVerificationUserState(requestingPackage)
            val hostToState = state?.hostToStateMap
            if (hostToState == null) {
                // The package declares no HTTP/HTTPS domain at all.
                emptyList()
            } else {
                hostToState.entries
                    .filter { it.value == DomainVerificationUserState.DOMAIN_STATE_VERIFIED }
                    .map { it.key }
                    .filter { it.isNotBlank() }
                    .sorted()
            }
        } catch (e: Throwable) {
            // NameNotFoundException, SecurityException, a package the platform
            // will not show us: all of them mean "no verified host known", and
            // the exception text is not worth a log line.
            Log.i(
                TAG,
                "package match package=$requestingPackage answer=unavailable " +
                    e.javaClass.simpleName,
            )
            emptyList()
        }

    private companion object {
        const val TAG = "Vaulta/Autofill"

        /** Where the queried host came from, logged and nothing more. */
        const val MATCH_HOST = "host"
        const val MATCH_PACKAGE = "package"
        const val MATCH_NONE = "none"

        /**
         * The only text the locked path ever shows in the system's fill UI.
         * Keep it free of vault data (ADR-008 §1) and keep it a constant.
         */
        const val UNLOCK_LABEL = "Unlock Vaulta"

        /**
         * The only text the "nothing matched" path shows. It names the app the
         * user is about to search in and nothing about the vault.
         */
        const val SEARCH_LABEL = "Search in Vaulta"

        const val FAILURE_MESSAGE = "Vaulta could not answer this fill request"

        const val REQUEST_CODE_UNLOCK = 1
    }
}
