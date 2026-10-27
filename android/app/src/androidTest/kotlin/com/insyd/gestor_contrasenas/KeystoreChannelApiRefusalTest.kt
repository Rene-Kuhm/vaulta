package com.insyd.gestor_contrasenas

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Executed verification of the API < 30 biometric refusal.
 *
 * Vaulta refuses to mint a biometric envelope key below Android 11 (API 30)
 * instead of minting one that the device PIN could also authorize
 * ([KeystoreChannel.MIN_BIOMETRIC_ONLY_AUTH_SDK]). Until this suite existed
 * that decision was only verified by reading `KeystoreChannel.kt`; see
 * `docs/reference/api30-biometric-refusal-verification.md`.
 *
 * The suite drives the production channel through its real method-call
 * surface ([KeystoreChannel.onMethodCall], the same entry point the Dart side
 * uses) and inspects the real `AndroidKeyStore`, on whatever device it runs
 * on. It never asserts `Build.VERSION.SDK_INT >= 30` and calls that a result:
 * the SDK level only selects which branch of the behaviour this device is
 * supposed to exhibit, and the assertions are about what the channel and the
 * KeyStore actually did.
 *
 * Below API 30 the refusal is the assertion; at API 30 and above the
 * counterpart asserts that no API-level refusal is left: `isAvailable` follows
 * the platform's strong-biometric enrolment state, and the key is minted once
 * something strong is enrolled. Run it on the `vaulta-a10` AVD (API 29,
 * `scripts/verify_api30_biometric_refusal.sh`) for the refusal, and on an
 * API 30+ device for the counterpart.
 */
@RunWith(AndroidJUnit4::class)
class KeystoreChannelApiRefusalTest {

    private lateinit var engine: FlutterEngine
    private lateinit var channel: KeystoreChannel

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // The channel only uses the engine to register its MethodChannel on
        // the messenger; no Dart code runs. The engine is still constructed on
        // the main thread because that is where the Flutter embedding expects
        // an engine to be created.
        onMainThread {
            engine = FlutterEngine(context)
            channel = KeystoreChannel(engine, context)
        }
        // Every test starts without the production alias so "no key was
        // minted" can be asserted on the KeyStore itself.
        deleteEnvelopeAlias()
    }

    @After
    fun tearDown() {
        deleteEnvelopeAlias()
        onMainThread { engine.destroy() }
    }

    /**
     * The security decision: below API 30 the envelope key provider reports
     * unavailable, refuses to mint a key, and leaves the KeyStore without the
     * production alias. If the refusal ever regresses into the old downgrade
     * (a `setUserAuthenticationRequired(true)` key that the PIN can satisfy),
     * this test fails on the API 29 device because a key appears.
     */
    @Test
    fun belowApi30ReportsUnavailableAndMintsNoKey() {
        assumeTrue(
            "Covers devices below the API $FIRST_BIOMETRIC_ONLY_API refusal floor; " +
                "this device is API ${Build.VERSION.SDK_INT}",
            isBelowRefusalFloor()
        )
        assertFalse(
            "precondition: the production alias must not exist before the call",
            androidKeyStore().containsAlias(ENVELOPE_ALIAS)
        )

        val available = call("isAvailable")
        assertEquals(
            "isAvailable() must report unavailable below API $FIRST_BIOMETRIC_ONLY_API",
            false,
            available.successValue("isAvailable()")
        )

        val refusal = call("ensureKey").refusal("ensureKey()")
        assertEquals("KEYSTORE", refusal.code)
        val refusalMessage = refusal.message
        assertNotNull("the refusal must carry a message", refusalMessage)
        assertTrue(
            "the refusal must name the API floor, got: $refusalMessage",
            refusalMessage!!.contains("API $FIRST_BIOMETRIC_ONLY_API")
        )
        assertFalse(
            "ensureKey() must not mint a key below API $FIRST_BIOMETRIC_ONLY_API",
            androidKeyStore().containsAlias(ENVELOPE_ALIAS)
        )

        // rsaEncrypt() is the path that wraps the per-installation seed and it
        // calls ensureKey() itself, so it must not mint one either.
        val encrypt = call("rsaEncrypt", mapOf("plaintext" to ByteArray(32)))
        assertEquals("KEYSTORE", encrypt.refusal("rsaEncrypt()").code)
        assertFalse(
            "rsaEncrypt() must not mint a key below API $FIRST_BIOMETRIC_ONLY_API",
            androidKeyStore().containsAlias(ENVELOPE_ALIAS)
        )
    }

    /**
     * `ensureKey` builds the key spec before it looks at the alias, so a
     * leftover entry at the production alias cannot keep the envelope
     * unlocking on an app version that is supposed to have closed the hole.
     * The test installs such an entry itself — a plain RSA key, because an
     * auth-bound one needs a secure lock screen and an enrolled biometric that
     * a bare emulator does not have (the API 36 run recorded in
     * `docs/reference/api30-biometric-refusal-verification.md` shows the platform
     * refusing that keygen), and the ordering pinned here does not depend on
     * how the leftover key was created.
     */
    @Test
    fun belowApi30RefusesEvenWhenALeftoverAliasExists() {
        assumeTrue(
            "Covers devices below the API $FIRST_BIOMETRIC_ONLY_API refusal floor; " +
                "this device is API ${Build.VERSION.SDK_INT}",
            isBelowRefusalFloor()
        )
        installLeftoverKeyAtEnvelopeAlias()

        val refusal = call("ensureKey").refusal("ensureKey() with a leftover alias")
        assertEquals("KEYSTORE", refusal.code)
        assertTrue(
            "the leftover alias must not be handed out as the envelope key, got: " +
                "${refusal.message}",
            refusal.message.orEmpty().contains("API $FIRST_BIOMETRIC_ONLY_API")
        )
        // The leftover entry is still there (the refusal is not a cleanup), but
        // it was never returned to Dart as an envelope key.
        assertTrue(androidKeyStore().containsAlias(ENVELOPE_ALIAS))

        assertEquals(
            "isAvailable() must stay false with a leftover alias present",
            false,
            call("isAvailable").successValue("isAvailable()")
        )
    }

    /**
     * The counterpart: from API 30 on there is no API-level refusal left.
     * What happens then is decided by the device's own state, and the test
     * asserts it instead of assuming it:
     *
     *  * with a strong biometric enrolled the channel mints the envelope key
     *    and `isAvailable()` answers true;
     *  * with nothing enrolled the platform itself refuses to generate an
     *    auth-per-use key (`IllegalStateException: At least one biometric must
     *    be enrolled ...`), `isAvailable()` answers false, and — the part that
     *    matters — the refusal the channel reports is that enrolment problem,
     *    never the API-floor message that [belowApi30ReportsUnavailableAndMintsNoKey]
     *    pins. That is what shows the floor is not leaking upward.
     *
     * A bare emulator runs the second branch; a device or AVD with an enrolled
     * fingerprint runs the first one.
     */
    @Test
    fun atApi30AndAboveHasNoApiLevelRefusal() {
        assumeTrue(
            "Covers devices at or above the API $FIRST_BIOMETRIC_ONLY_API floor; " +
                "this device is API ${Build.VERSION.SDK_INT}",
            !isBelowRefusalFloor()
        )

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val strongEnrolled = BiometricManager.from(context)
            .canAuthenticate(Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS
        val ensureKey = call("ensureKey")

        if (strongEnrolled) {
            assertEquals(
                "with a strong biometric enrolled the envelope key must be minted",
                ENVELOPE_ALIAS,
                ensureKey.successValue("ensureKey()")
            )
            assertTrue(
                "the minted key must exist in the AndroidKeyStore",
                androidKeyStore().containsAlias(ENVELOPE_ALIAS)
            )
            assertEquals(
                "with a strong biometric enrolled isAvailable() must answer true",
                true,
                call("isAvailable").successValue("isAvailable()")
            )
        } else {
            val refusal = ensureKey.refusal("ensureKey() without an enrolled biometric")
            assertEquals("KEYSTORE", refusal.code)
            assertFalse(
                "the API floor must not leak into API $FIRST_BIOMETRIC_ONLY_API+, got: " +
                    "${refusal.message}",
                refusal.message.orEmpty()
                    .contains("requires API $FIRST_BIOMETRIC_ONLY_API")
            )
            assertFalse(
                "no key may be minted while nothing strong is enrolled",
                androidKeyStore().containsAlias(ENVELOPE_ALIAS)
            )
            assertEquals(
                "isAvailable() must follow the platform's enrolment state, not the API level",
                false,
                call("isAvailable").successValue("isAvailable()")
            )
        }
    }

    // ---------------------------------------------------------------------

    private fun isBelowRefusalFloor(): Boolean =
        Build.VERSION.SDK_INT < FIRST_BIOMETRIC_ONLY_API

    private fun call(method: String, arguments: Any? = null): Outcome {
        // Guard rail: the suite exists to pin the refusal floor, so it fails
        // loudly if the production constant is ever lowered silently.
        assertEquals(
            "the biometric envelope floor is a security decision, not a knob",
            FIRST_BIOMETRIC_ONLY_API,
            KeystoreChannel.MIN_BIOMETRIC_ONLY_AUTH_SDK
        )
        val result = CapturingResult()
        onMainThread { channel.onMethodCall(MethodCall(method, arguments), result) }
        return result.outcome
            ?: throw AssertionError("$method did not answer on the method channel")
    }

    /** The value a successful channel answer carried, or a readable failure. */
    private fun Outcome.successValue(what: String): Any? =
        (this as? Outcome.Success)?.value
            ?: throw AssertionError("$what must succeed on this device, got $this")

    /** The refusal a channel answer carried, or a readable failure. */
    private fun Outcome.refusal(what: String): Outcome.Failure =
        this as? Outcome.Failure
            ?: throw AssertionError("$what must be refused on this device, got $this")

    private fun installLeftoverKeyAtEnvelopeAlias() {
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            ANDROID_KEYSTORE
        )
        generator.initialize(
            KeyGenParameterSpec.Builder(
                ENVELOPE_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                .setKeySize(2048)
                .build()
        )
        generator.generateKeyPair()
        assertTrue(androidKeyStore().containsAlias(ENVELOPE_ALIAS))
    }

    private fun deleteEnvelopeAlias() {
        val keyStore = androidKeyStore()
        if (keyStore.containsAlias(ENVELOPE_ALIAS)) {
            keyStore.deleteEntry(ENVELOPE_ALIAS)
        }
    }

    private fun androidKeyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun onMainThread(block: () -> Unit) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(block)
    }

    /** What the channel answered on the MethodChannel.Result it was handed. */
    private sealed class Outcome {
        data class Success(val value: Any?) : Outcome()
        data class Failure(val code: String, val message: String?) : Outcome()
        object NotImplemented : Outcome()
    }

    private class CapturingResult : MethodChannel.Result {
        var outcome: Outcome? = null

        override fun success(result: Any?) {
            outcome = Outcome.Success(result)
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            outcome = Outcome.Failure(errorCode, errorMessage)
        }

        override fun notImplemented() {
            outcome = Outcome.NotImplemented
        }
    }

    private companion object {
        /**
         * The refusal floor this suite exists to pin. Spelled out here rather
         * than read from [KeystoreChannel.MIN_BIOMETRIC_ONLY_AUTH_SDK] so that
         * lowering the production constant cannot silently rewrite the
         * expectation: `call()` asserts the two agree.
         */
        const val FIRST_BIOMETRIC_ONLY_API = 30

        /**
         * Mirrors the private `KEY_ALIAS` in `KeystoreChannel.kt`. Pinned
         * against production by [atApi30AndAboveHasNoApiLevelRefusal], which
         * receives the alias from `ensureKey()` itself on a device with an
         * enrolled strong biometric.
         */
        const val ENVELOPE_ALIAS = "vaulta_biometric_envelope_v1"

        const val ANDROID_KEYSTORE = "AndroidKeyStore"
    }
}
