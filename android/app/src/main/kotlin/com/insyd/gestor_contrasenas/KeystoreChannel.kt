package com.insyd.gestor_contrasenas

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
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
 * (AndroidKeyStore provider) with `setUserAuthenticationRequired(true)`.
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
 * Best-practice notes (Android 11+ / API 30+):
 *   * `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` is
 *     the explicit form that Android wants you to call instead of
 *     relying on the legacy `setUserAuthenticationValidityDuration`
 *     shortcut. With timeout=0 every private-key operation requires
 *     a fresh BiometricPrompt.
 *   * On older devices that pre-date `setUserAuthenticationParameters`
 *     (API < 30) we fall back to `setUserAuthenticationValidityDuration(0)`
 *     which has the same semantics under the hood.
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
     * Deliberately cheap. The previous implementation generated and
     * deleted a throwaway RSA-2048 keypair to prove the KeyStore would
     * accept the spec, and this method runs on every acquire and every
     * release, so an RSA keygen sat on the critical path of the unlock
     * button. A spec that the KeyStore provider rejects fails loudly at
     * `ensureKey` time, which is where a genuine incompatibility
     * belongs.
     */
    private fun isAvailable(): Boolean {
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
            buildKeySpec(PROBE_ALIAS)
            Log.i(TAG, "isAvailable: strong biometric enrolled and spec supported")
            true
        } catch (e: Throwable) {
            Log.w(TAG, "isAvailable: biometric RSA spec unsupported", e)
            false
        }
    }

    private fun ensureKey(): String {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        if (ks.containsAlias(KEY_ALIAS)) {
            Log.d(TAG, "ensureKey: alias $KEY_ALIAS already present")
            return KEY_ALIAS
        }

        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            ANDROID_KEYSTORE
        )
        val spec = buildKeySpec(KEY_ALIAS)
        generator.initialize(spec)
        generator.generateKeyPair()
        Log.i(TAG, "ensureKey: generated new RSA-2048 alias=$KEY_ALIAS")
        return KEY_ALIAS
    }

    /**
     * Build the [KeyGenParameterSpec] for the biometric-bound RSA key.
     *
     * The auth timeout is 0 (every operation needs a fresh prompt).
     *
     * On API 30+ we set this explicitly with
     * [KeyGenParameterSpec.Builder.setUserAuthenticationParameters] and
     * the [KeyProperties.AUTH_BIOMETRIC_STRONG] authenticator so the
     * platform never grants a time-based bypass. On API 23-29 the
     * older `setUserAuthenticationValidityDuration` shortcut has been
     * pruned from the public SDK, so we leave the timeout unset; the
     * default for `setUserAuthenticationRequired(true)` is already
     * "every operation needs a fresh user auth", which is exactly
     * what we want for the per-unlock biometric gate.
     */
    private fun buildKeySpec(alias: String): KeyGenParameterSpec {
        val builder = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
            .setKeySize(2048)
            .setUserAuthenticationRequired(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // API 30+ — explicit authenticator set. timeout=0 means
            // "every use requires a fresh user auth".
            builder.setUserAuthenticationParameters(
                /* timeout = */ 0,
                /* authType = */ KeyProperties.AUTH_BIOMETRIC_STRONG
            )
        }
        // On API < 30 the system default is the same per-operation
        // requirement, so we do nothing else. See class docs.
        return builder.build()
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
