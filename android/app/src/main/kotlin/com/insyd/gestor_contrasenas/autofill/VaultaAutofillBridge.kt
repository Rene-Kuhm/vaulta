package com.insyd.gestor_contrasenas.autofill

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The autofill service's door to the app's Flutter engine (ADR-008 §3, §4).
 *
 * Why this is a bridge and not a repository:
 *
 *   * The vault is encrypted in Dart. Decryption, the session and the host
 *     index all live behind `VaultRepository` in Dart, and the one thing this
 *     slice must never do is grow a second implementation of any of them in
 *     Kotlin.
 *   * The service runs in the app's process, so it can talk to the app's
 *     **one** engine. A second `FlutterEngine` would have its own Dart heap,
 *     its own (empty) session, and would answer "locked" forever — and the
 *     temptation to fix that with a cache is exactly what ADR-008 §4 forbids.
 *     There is therefore no engine here: only a [MethodChannel] handle that
 *     [com.insyd.gestor_contrasenas.MainActivity.configureFlutterEngine] sets
 *     for the engine it already created.
 *
 * When no handle is set — the process was started by the service alone, the
 * activity was destroyed, or the engine is gone — every query answers "not
 * available" and the caller keeps the slice A response: zero datasets plus the
 * authentication intent. Nothing is queued, retried or cached in that state.
 */
object VaultaAutofillBridge {

    /**
     * The channel name, which must stay equal to `autofillChannelName` in
     * `lib/features/autofill/autofill_channel.dart`. The Dart test pins that
     * literal so the two halves cannot drift silently.
     */
    const val CHANNEL_NAME = "com.insyd.gestor_contrasenas/autofill"

    private var channel: MethodChannel? = null

    /**
     * True when a query can reach the app's Dart side right now. Read from the
     * service before deciding between "ask the app" and the slice A answer.
     */
    val isAvailable: Boolean
        get() = channel != null

    /**
     * Keeps the handle of the app's engine. Called once from
     * `MainActivity.configureFlutterEngine`, where the process's other platform
     * channels are created, so there is exactly one channel per engine and no
     * engine is created here.
     */
    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
    }

    /**
     * Drops the handle when the engine goes away. Must be safe to call when
     * nothing is attached.
     */
    fun detach() {
        channel = null
    }

    /**
     * Asks the app for the answer to one fill request.
     *
     * [onAnswer] receives `null` for every "not available" outcome — no engine,
     * channel error, unimplemented method, unparseable answer — so the caller
     * has one branch for it, and the branch is the slice A answer. It is called
     * exactly once, and always on the main thread: `onFillRequest` runs there
     * and [MethodChannel] results are delivered there too.
     *
     * Nothing in here is logged: the answer carries a title, a username and a
     * secret (ADR-008 §6).
     */
    fun query(
        host: String?,
        packageName: String,
        onAnswer: (AutofillAnswer?) -> Unit,
    ) {
        val current = channel
        if (current == null) {
            onAnswer(null)
            return
        }
        try {
            current.invokeMethod(
                "query",
                mapOf("host" to host, "packageName" to packageName),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        onAnswer(parseAnswer(result))
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        onAnswer(null)
                    }

                    override fun notImplemented() {
                        onAnswer(null)
                    }
                },
            )
        } catch (e: Throwable) {
            // A destroyed engine throws here. "Not available" is the correct
            // answer and the only thing this catch is allowed to do: the
            // exception text can carry channel names, never vault data, but it
            // still has no business reaching the fill UI.
            onAnswer(null)
        }
    }

    /**
     * Turns the Dart map into [AutofillAnswer], or `null` when it is not an
     * answer this service understands. A status it does not know is treated as
     * "not available" rather than guessed at, so a protocol change fails closed.
     */
    private fun parseAnswer(result: Any?): AutofillAnswer? {
        val map = result as? Map<*, *> ?: return null
        val status = map["status"] as? String ?: return null
        val candidates = ArrayList<AutofillCandidate>()
        val rawCandidates = map["candidates"] as? List<*>
        if (rawCandidates != null) {
            for (entry in rawCandidates) {
                val candidate = entry as? Map<*, *> ?: continue
                val label = candidate["label"] as? String ?: continue
                // A candidate whose secret did not survive the channel cannot
                // fill anything, so it is dropped instead of offered empty.
                val secret = candidate["secret"] as? String ?: continue
                candidates.add(
                    AutofillCandidate(
                        label = label,
                        username = candidate["username"] as? String ?: "",
                        secret = secret,
                    ),
                )
            }
        }
        return when (status) {
            "locked" -> AutofillAnswer(isLocked = true, candidates = emptyList())
            "searchOnly" -> AutofillAnswer(isLocked = false, candidates = emptyList())
            "matched" -> AutofillAnswer(isLocked = false, candidates = candidates)
            else -> null
        }
    }
}

/**
 * One credential the fill UI may offer.
 *
 * Deliberately not a `data class`: the generated `toString()` of a data class
 * would include the title, the username and the secret, and one
 * `Log.d(TAG, "$candidate")` during debugging would put a password in logcat.
 * The override below keeps that mistake cheap.
 */
class AutofillCandidate(
    val label: String,
    val username: String,
    val secret: String,
) {
    override fun toString(): String = "AutofillCandidate(redacted)"
}

/**
 * A parsed answer from the app: locked, matched with [candidates], or open with
 * nothing to offer (search only).
 *
 * Redacted `toString()` for the same reason as [AutofillCandidate]: this object
 * is one string interpolation away from a log line.
 */
class AutofillAnswer(
    val isLocked: Boolean,
    val candidates: List<AutofillCandidate>,
) {
    /** True when the vault is open but no item is indexed for the host. */
    val isSearchOnly: Boolean
        get() = !isLocked && candidates.isEmpty()

    override fun toString(): String = "AutofillAnswer(redacted)"
}
