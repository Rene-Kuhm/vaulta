package com.insyd.gestor_contrasenas

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Coordinates the BiometricPrompt round-trip for the Dart envelope.
 *
 *   1. Dart calls `requestDecryptAuthorization(ciphertext)`.
 *   2. The host activity builds a KeyStore RSA `Cipher` in DECRYPT_MODE and
 *      binds it to the prompt via `BiometricPrompt.CryptoObject`, then calls
 *      `authenticate(info, CryptoObject(cipher))`.
 *   3. On `onAuthenticationSucceeded`, the activity runs `cipher.doFinal(ct)`
 *      with the Android-authorized cipher and returns the recovered seed to
 *      Dart. On failure it returns a stable `BiometricErrorCode`.
 *
 * The private key never leaves the KeyStore, but the recovered seed *does*
 * cross this channel as a `ByteArray`: Android only authorizes the operation,
 * it cannot hand back a `SecretKey` to Dart. It is materialized as a
 * `SecretKey` on the Dart side by `BiometricKeyEnvelopeService`.
 *
 * This is the only path that unwraps the biometric envelope. `KeystoreChannel`
 * deliberately exposes no decrypt method: under
 * `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` an
 * unauthorized `Cipher.init(DECRYPT_MODE, privateKey)` can never succeed, so
 * a second decrypt path would be dead code that reads like a vulnerability.
 *
 * Beyond the auth round-trip, this channel also exposes:
 *   * `probeAvailability` — structured platform capabilities so Dart
 *     can decide whether to render the biometric button at all and
 *     with which label.
 *   * `openBiometricEnrollment` — opens the system biometric-enroll
 *     settings so the user can configure a fingerprint/face without
 *     leaving the app.
 */
class BiometricChannel(
    engine: FlutterEngine,
    private val onAuthenticate: (ciphertext: ByteArray, result: MethodChannel.Result) -> Unit,
    private val onProbe: () -> Map<String, Any>,
    private val onOpenEnrollment: () -> Boolean,
) : MethodChannel.MethodCallHandler {

    private val channel: MethodChannel =
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestDecryptAuthorization" -> {
                val ciphertext = call.argument<ByteArray>("ciphertext")
                if (ciphertext == null) {
                    result.error("ARG", "ciphertext is required", null)
                    return
                }
                onAuthenticate(ciphertext, result)
            }
            "probeAvailability" -> {
                try {
                    result.success(onProbe())
                } catch (e: Throwable) {
                    result.error(
                        BiometricErrorCode.UNAVAILABLE,
                        e.message ?: e.javaClass.simpleName,
                        null
                    )
                }
            }
            "openBiometricEnrollment" -> {
                try {
                    result.success(onOpenEnrollment())
                } catch (e: Throwable) {
                    result.error(
                        BiometricErrorCode.UNAVAILABLE,
                        e.message ?: e.javaClass.simpleName,
                        null
                    )
                }
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL_NAME = "com.insyd.vaulta/biometric"
    }
}
