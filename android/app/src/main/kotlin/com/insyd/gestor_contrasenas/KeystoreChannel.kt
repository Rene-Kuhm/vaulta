package com.insyd.gestor_contrasenas

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.annotation.RequiresApi
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

/**
 * Bridge between the Dart envelope and the Android KeyStore.
 *
 * Generates an RSA-2048 keypair inside the hardware-backed KeyStore
 * (AndroidKeyStore provider) declared for
 * `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` — biometric,
 * per operation, never the device PIN.
 * The private key never leaves the secure element; every decrypt
 * operation must be preceded by a successful BiometricPrompt, which
 * the host activity handles on a separate channel. We only return
 * cipher-text + IV here; the key itself is referenced by alias.
 *
 * For the Vaulta envelope we use the public key to RSA-OAEP-encrypt
 * a per-installation AES-256 seed (generated on the Dart side). The
 * Dart side also generates the AES-256 key used to wrap the DEK with
 * HKDF — the RSA-encrypted seed is stored in secure storage, and the
 * `unwrap` path is what requires the BiometricPrompt to release the
 * private key for one decryption.
 *
 * Algorithm choices:
 *   - RSA-OAEP-SHA256 is the standard wrap algorithm for short keys.
 *   - AES/GCM/NoPadding inside the Dart envelope is the DEK wrap.
 *   - We never persist the DEK in clear, even on disk.
 *
 * Best-practice notes:
 *   * The key declares its authenticator type with
 *     `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`, so
 *     the device PIN/pattern/password can never authorize it and every
 *     private-key operation needs a fresh BiometricPrompt. That call —
 *     and the `AUTH_BIOMETRIC_STRONG` constant itself — only exist from
 *     API 30 on.
 *   * Below API 30 there is no way to say "biometric only" to the
 *     KeyStore: `setUserAuthenticationRequired(true)` alone is satisfied
 *     by any secure lock-screen credential, so a key minted there is
 *     authorized by the device PIN as well as by a fingerprint. Rather
 *     than mint such a key and call it biometric-bound, this channel
 *     refuses to build one: [isAvailable] answers false and [ensureKey]
 *     throws, so the biometric envelope simply is not offered and the
 *     user falls back to the master password. See [buildKeySpecForDevice].
 */
class KeystoreChannel(
    engine: FlutterEngine,
    context: Context,
) : MethodChannel.MethodCallHandler {

    private val appContext: Context = context.applicationContext

    private val channel: MethodChannel =
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "ensureKey" -> result.success(ensureKey())
                "deleteKey" -> {
                    deleteKey()
                    result.success(null)
                }
                "isAvailable" -> result.success(isAvailable())
                "rsaEncrypt" -> {
                    val plaintext = call.argument<ByteArray>("plaintext")
                        ?: return result.error("ARG", "plaintext is required", null)
                    val encrypted = rsaEncrypt(plaintext)
                    result.success(encrypted)
                }
                // There is deliberately no unauthenticated decrypt method on this
                // channel. The private key is generated with
                // setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG), so a
                // Cipher.init(DECRYPT_MODE, privateKey) without a
                // BiometricPrompt.CryptoObject can never be authorized by Android.
                // Unwrapping the seed happens in MainActivity.authenticateAndDecrypt,
                // which owns the prompt and runs cipher.doFinal() inside
                // onAuthenticationSucceeded. See ADR-001.
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("KEYSTORE", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /**
     * Reports whether this device can actually back the biometric
     * envelope right now.
     *
     * Two things have to hold: the platform must accept a
     * biometric-strong RSA spec, and the user must actually have a
     * strong biometric enrolled. Checking only the first is how a device
     * with no enrolled fingerprint could report `true`, let enrollment
     * persist an encrypted seed, and then fail every unlock.
     *
     * A third thing has to hold, and it is the one that was missing: the
     * platform must be able to declare the authenticator type at all. On
     * API < 30 it cannot, so no key minted on such a device is really
     * biometric-bound and this answers false.
     *
     * Deliberately cheap. The previous implementation generated and
     * deleted a throwaway RSA-2048 keypair to prove the KeyStore would
     * accept the spec, and this method runs on every acquire and every
     * release, so an RSA keygen sat on the critical path of the unlock
     * button. A spec that the KeyStore provider rejects fails loudly at
     * `ensureKey` time, which is where a genuine incompatibility
     * belongs.
     */
    private fun isAvailable(): Boolean {
        if (!supportsBiometricOnlyAuth()) {
            Log.i(
                TAG,
                "isAvailable: API ${Build.VERSION.SDK_INT} cannot declare " +
                    "AUTH_BIOMETRIC_STRONG for a KeyStore key; " +
                    "biometric envelope unavailable"
            )
            return false
        }

        val strongEnrolled = try {
            BiometricManager.from(appContext)
                .canAuthenticate(Authenticators.BIOMETRIC_STRONG) ==
                BiometricManager.BIOMETRIC_SUCCESS
        } catch (e: Throwable) {
            Log.w(TAG, "isAvailable: BiometricManager probe failed", e)
            return false
        }
        if (!strongEnrolled) {
            Log.i(TAG, "isAvailable: no strong biometric enrolled")
            return false
        }

        // A spec the provider cannot even build is an incompatibility we
        // can detect without paying for a keypair. buildKeySpec throws on
        // an unsupported authenticator set, which is the whole probe.
        return try {
            KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            buildKeySpecForDevice(PROBE_ALIAS)
            Log.i(TAG, "isAvailable: strong biometric enrolled and spec supported")
            true
        } catch (e: Throwable) {
            Log.w(TAG, "isAvailable: biometric RSA spec unsupported", e)
            false
        }
    }

    private fun ensureKey(): String {
        // The spec is built before the alias check on purpose: on a device
        // that cannot declare the authenticator type we must refuse even
        // when a legacy alias is still lying around, or the envelope would
        // keep unlocking through the PIN on an app version that was
        // supposed to have closed that hole.
        val spec = buildKeySpecForDevice(KEY_ALIAS)
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (ks.containsAlias(KEY_ALIAS)) {
            Log.d(TAG, "ensureKey: alias $KEY_ALIAS already present")
            return KEY_ALIAS
        }

        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            ANDROID_KEYSTORE
        )
        generator.initialize(spec)
        generator.generateKeyPair()
        Log.i(TAG, "ensureKey: generated new RSA-2048 alias=$KEY_ALIAS")
        return KEY_ALIAS
    }

    /**
     * True when this platform can declare an authenticator type for the
     * envelope key.
     *
     * [KeyGenParameterSpec.Builder.setUserAuthenticationParameters] and
     * [KeyProperties.AUTH_BIOMETRIC_STRONG] were both introduced in API 30.
     * Before that, the only knobs were `setUserAuthenticationRequired` and
     * the deprecated `setUserAuthenticationValidityDurationSeconds`, and
     * neither restricts *which* credential satisfies the requirement: a
     * key that requires user auth on API 23-29 is authorized by the
     * device PIN/pattern/password as readily as by a fingerprint. There
     * is no keystore-level fix for that, so the honest answer is that the
     * biometric envelope is unavailable rather than available with a
     * weaker guarantee than the UI claims.
     *
     * Annotated [ChecksSdkIntAtLeast] so lint keeps treating the
     * API 30 branch below as genuinely guarded.
     */
    @ChecksSdkIntAtLeast(api = Build.VERSION_CODES.R)
    private fun supportsBiometricOnlyAuth(): Boolean =
        declaresBiometricOnlyAuth(Build.VERSION.SDK_INT)

    /**
     * The one place the API-level branch is written. Below API 30 it is a
     * refusal, never a downgrade: minting a key whose declared guarantee
     * is "some secure lock-screen credential" under a UI that says
     * "biometrics" is exactly the defect this guards against. The
     * comparison is spelled against [Build.VERSION.SDK_INT] directly so
     * lint can see it as a version guard.
     */
    private fun buildKeySpecForDevice(alias: String): KeyGenParameterSpec =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            buildKeySpec(alias, Build.VERSION.SDK_INT)
        } else {
            throw UnsupportedOperationException(
                "vaulta biometric envelope key requires API " +
                    "$MIN_BIOMETRIC_ONLY_AUTH_SDK: setUserAuthenticationParameters " +
                    "and AUTH_BIOMETRIC_STRONG do not exist on API " +
                    "${Build.VERSION.SDK_INT}, where a " +
                    "setUserAuthenticationRequired(true) key is also authorized by " +
                    "the device PIN/pattern/password"
            )
        }

    /**
     * Build the [KeyGenParameterSpec] for the biometric-bound RSA key.
     *
     * The auth timeout is 0 (every operation needs a fresh prompt) and
     * the authenticator type is declared as
     * [KeyProperties.AUTH_BIOMETRIC_STRONG], so the device PIN is not an
     * accepted substitute for the fingerprint.
     *
     * [sdkInt] is a parameter rather than a [Build.VERSION] read so the
     * precondition is an input: [buildKeySpecForDevice] is the only
     * production caller and it refuses anything below
     * [MIN_BIOMETRIC_ONLY_AUTH_SDK], and the redundant check here means
     * the function cannot be turned into a silent downgrade by a future
     * caller that skips the guard.
     *
     * @param sdkInt the platform API level the spec has to be valid for.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun buildKeySpec(alias: String, sdkInt: Int): KeyGenParameterSpec {
        if (!declaresBiometricOnlyAuth(sdkInt)) {
            throw UnsupportedOperationException(
                "vaulta biometric envelope key requires API " +
                    "$MIN_BIOMETRIC_ONLY_AUTH_SDK, got API $sdkInt"
            )
        }

        return KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
            .setKeySize(2048)
            .setUserAuthenticationRequired(true)
            // timeout = 0 → every use needs a fresh user auth;
            // authType   → a biometric, never the device PIN.
            .setUserAuthenticationParameters(
                /* timeout = */ 0,
                /* authType = */ KeyProperties.AUTH_BIOMETRIC_STRONG
            )
            .build()
    }

    private fun deleteKey() {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (ks.containsAlias(KEY_ALIAS)) {
            ks.deleteEntry(KEY_ALIAS)
            Log.i(TAG, "deleteKey: removed alias $KEY_ALIAS")
        }
    }

    private fun rsaEncrypt(plaintext: ByteArray): ByteArray {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (!ks.containsAlias(KEY_ALIAS)) {
            ensureKey()
        }
        val entry = ks.getEntry(KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
        val publicKey = KeyFactory.getInstance(KeyProperties.KEY_ALGORITHM_RSA)
            .generatePublic(X509EncodedKeySpec(entry.certificate.publicKey.encoded))
        val cipher = Cipher.getInstance(TRANSFORMATION_RSA)
        // No IvParameter for RSA-OAEP. Encryption is a public-key
        // operation, so the biometric gate is intentionally not
        // consulted here: this is the path the app uses to wrap a
        // fresh seed at activation time, not to unwrap it.
        cipher.init(Cipher.ENCRYPT_MODE, publicKey, OAEP_SHA256_MGF1_SHA1)
        val out = cipher.doFinal(plaintext)
        Log.d(TAG, "rsaEncrypt: ${plaintext.size} bytes -> ${out.size} bytes")
        return out
    }

    // Removed: rsaDecryptAuthorized() and the three KeystoreException classes it
    // needed. The method was unreachable from Dart and, under
    // setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG), Android can never
    // authorize its Cipher.init(DECRYPT_MODE, privateKey) without a
    // BiometricPrompt.CryptoObject. Keeping an unauthenticated decrypt on a
    // crypto channel is an audit finding waiting to happen, so the path is gone
    // rather than merely unused. Seed unwrapping lives in
    // MainActivity.authenticateAndDecrypt, inside onAuthenticationSucceeded.

    companion object {
        const val CHANNEL_NAME = "com.insyd.vaulta/keystore"

        /**
         * First API level that can express "this key needs a strong
         * biometric, not the device PIN". Compile-time constant, so it is
         * inlined and safe to reference from a pre-30 device.
         */
        const val MIN_BIOMETRIC_ONLY_AUTH_SDK = Build.VERSION_CODES.R

        /**
         * The platform policy as a pure function of the API level, so the
         * decision is readable — and testable, once `android/app/src/test`
         * has a runner — without a live [Build.VERSION].
         *
         * Public because the biometric probe has to answer the same
         * question to Dart: the UI must be able to say "this Android is
         * too old to enforce biometric-only auth" without anybody
         * repeating the API level as a literal. The floor lives here and
         * only here.
         */
        @JvmStatic
        fun declaresBiometricOnlyAuth(sdkInt: Int): Boolean =
            sdkInt >= MIN_BIOMETRIC_ONLY_AUTH_SDK

        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "vaulta_biometric_envelope_v1"
        private const val PROBE_ALIAS = "vaulta-biometric-probe"
        private const val TRANSFORMATION_RSA = "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"
        private const val TAG = "Vaulta/KeyStore"
        private val OAEP_SHA256_MGF1_SHA1 = OAEPParameterSpec(
            "SHA-256",
            "MGF1",
            MGF1ParameterSpec.SHA1,
            PSource.PSpecified.DEFAULT
        )
    }
}
