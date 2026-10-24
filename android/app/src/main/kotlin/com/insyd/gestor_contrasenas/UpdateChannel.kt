package com.insyd.gestor_contrasenas

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Over-the-air update bridge.
 *
 * Stable releases are cut from `vX.Y.Z` tags by `release.yml` and
 * served from `/releases/latest`; the opt-in dev channel follows the
 * rolling `dev-latest` pre-release rebuilt on every push to master.
 * Both publish a `SHA256SUMS` asset next to `vaulta.apk`.
 *
 * The channel queries the public Releases API, downloads the APK to
 * the app's private files directory and hands it to the system
 * installer via FileProvider — but only after the Dart side has
 * checked the SHA-256 against `SHA256SUMS`, and only if the APK is
 * signed by the same certificate as the installed app.
 * [openInstallPrompt] re-checks both right before launching the
 * installer, so an unverified file can never reach it.
 *
 * Methods exposed to Dart:
 *   * `checkForUpdate(owner, repo, currentVersion, channel)` -> map
 *     describing whether a new release is available.
 *   * `downloadChecksums(url)` -> SHA256SUMS text (size-capped).
 *   * `downloadApk(apkUrl)` -> absolute file path to the cached APK.
 *   * `sha256File(filePath)` -> lowercase hex SHA-256 of the file.
 *   * `verifyApkSigner(filePath)` -> true if the APK signer matches
 *     the installed app.
 *   * `discardDownload(filePath)` -> deletes a cached APK.
 *   * `openInstallPrompt(filePath, expectedSha256)` -> bool, true if
 *     the system installer was launched.
 */
class UpdateChannel(
    engine: FlutterEngine,
    private val appContext: Context,
) : MethodChannel.MethodCallHandler {

    private val mainHandler: Handler = Handler(Looper.getMainLooper())
    private val networkExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private val channel: MethodChannel =
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }

    private val updatesDir: File
        get() = File(appContext.filesDir, "updates")

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "checkForUpdate" -> {
                    val owner = call.argument<String>("owner")
                    val repo = call.argument<String>("repo")
                    val currentVersion = call.argument<String>("currentVersion")
                    val releaseChannel = call.argument<String>("channel")
                    if (owner.isNullOrBlank() || repo.isNullOrBlank()) {
                        result.error("ARG", "owner and repo are required", null)
                        return
                    }
                    runInBackground(call.method, result) {
                        checkForUpdate(owner, repo, currentVersion, releaseChannel)
                    }
                }
                "downloadChecksums" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("ARG", "url is required", null)
                        return
                    }
                    runInBackground(call.method, result) {
                        downloadChecksums(url)
                    }
                }
                "downloadApk" -> {
                    val apkUrl = call.argument<String>("apkUrl")
                    if (apkUrl.isNullOrBlank()) {
                        result.error("ARG", "apkUrl is required", null)
                        return
                    }
                    runInBackground(call.method, result) {
                        downloadApk(apkUrl)
                    }
                }
                "sha256File" -> {
                    val file = requireUpdateFile(call.argument<String>("filePath"))
                    runInBackground(call.method, result) {
                        sha256Hex(file)
                    }
                }
                "verifyApkSigner" -> {
                    val file = requireUpdateFile(call.argument<String>("filePath"))
                    runInBackground(call.method, result) {
                        isSignedByInstalledSigner(file)
                    }
                }
                "discardDownload" -> {
                    val file = requireUpdateFile(call.argument<String>("filePath"))
                    result.success(file.delete())
                }
                "openInstallPrompt" -> {
                    val file = requireUpdateFile(call.argument<String>("filePath"))
                    val expectedSha256 = call.argument<String>("expectedSha256")
                    if (expectedSha256.isNullOrBlank()) {
                        result.error("ARG", "expectedSha256 is required", null)
                        return
                    }
                    runInBackground(call.method, result) {
                        verifyThenInstall(file, expectedSha256)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Method ${call.method} failed", e)
            result.error(
                "UPDATE_FAILED",
                e.message ?: e.javaClass.simpleName,
                null
            )
        }
    }

    private fun runInBackground(
        methodName: String,
        result: MethodChannel.Result,
        block: () -> Any?,
    ) {
        networkExecutor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Throwable) {
                Log.w(TAG, "Method $methodName failed", e)
                mainHandler.post {
                    result.error(
                        "UPDATE_FAILED",
                        e.message ?: e.javaClass.simpleName,
                        null
                    )
                }
            }
        }
    }

    /**
     * Resolves [filePath] and rejects anything outside
     * `filesDir/updates`, so the hashing, signer, delete and install
     * methods cannot be pointed at arbitrary app files.
     */
    private fun requireUpdateFile(filePath: String?): File {
        require(!filePath.isNullOrBlank()) { "filePath is required" }
        val file = File(filePath).canonicalFile
        val root = updatesDir.canonicalFile
        require(file.parentFile == root) { "filePath is outside the updates directory" }
        return file
    }

    /** Only HTTPS downloads are accepted. */
    private fun requireHttpsUrl(url: String): URL {
        val parsed = URL(url)
        require(parsed.protocol.equals("https", ignoreCase = true)) {
            "Only https URLs are accepted"
        }
        return parsed
    }

    // ---- checkForUpdate ----

    /**
     * Queries the GitHub Releases API for the selected channel:
     * `/releases/latest` (stable, the default and the fallback for
     * any unknown value) or `/releases/tags/dev-latest` (dev).
     */
    private fun checkForUpdate(
        owner: String,
        repo: String,
        currentVersion: String?,
        releaseChannel: String?,
    ): Map<String, Any?> {
        val path = if (releaseChannel == CHANNEL_DEV) "releases/tags/dev-latest" else "releases/latest"
        val apiUrl = "https://api.github.com/repos/$owner/$repo/$path"
        Log.d(TAG, "checkForUpdate: GET $apiUrl")
        val conn = (URL(apiUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 15_000
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "Vaulta-UpdateChannel/1.0")
        }
        try {
            val code = conn.responseCode
            if (code == 404) {
                Log.d(TAG, "checkForUpdate: no release on $path yet")
                return mapOf(
                    "available" to false,
                    "reason" to "no_release",
                    "currentVersion" to currentVersion,
                )
            }
            if (code !in 200..299) {
                Log.w(TAG, "checkForUpdate: GitHub returned HTTP $code")
                return mapOf(
                    "available" to false,
                    "reason" to "http_$code",
                    "currentVersion" to currentVersion,
                )
            }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            return parseRelease(body, currentVersion)
        } finally {
            conn.disconnect()
        }
    }

    private fun parseRelease(json: String, currentVersion: String?): Map<String, Any?> {
        val root = JSONObject(json)
        val tagName = root.optString("tag_name", "")
        val publishedAt = root.optString("published_at", "")
        val releaseId = root.optLong("id", 0L)
        val body = root.optString("body", "")
        val remoteVersion = Regex(
            """(?:Vaulta\s+version|Version):\s*([0-9A-Za-z.+-]+)""",
            RegexOption.IGNORE_CASE,
        )
            .find(body)
            ?.groupValues
            ?.getOrNull(1)
            ?: Regex("""^v(\d+\.\d+\.\d+)$""").find(tagName)?.groupValues?.getOrNull(1)
            ?: ""

        // GitHub returns assets as a JSONArray. We need the APK and
        // the SHA256SUMS file the release workflows publish with it.
        val assets = root.optJSONArray("assets")
        var apkUrl: String? = null
        var apkAssetId = 0L
        var apkAssetName = ""
        var apkAssetUpdatedAt = ""
        var apkAssetSize = 0L
        var checksumsUrl = ""
        if (assets != null) {
            for (i in 0 until assets.length()) {
                val asset = assets.getJSONObject(i)
                val name = asset.optString("name", "")
                if (name == CHECKSUMS_ASSET) {
                    checksumsUrl = asset.optString("browser_download_url", "")
                } else if (apkUrl == null && name.endsWith(".apk", ignoreCase = true)) {
                    apkUrl = asset.optString("browser_download_url", null)
                    apkAssetId = asset.optLong("id", 0L)
                    apkAssetName = name
                    apkAssetUpdatedAt = asset.optString("updated_at", "")
                    apkAssetSize = asset.optLong("size", 0L)
                }
            }
        }
        if (apkUrl == null) {
            Log.w(TAG, "parseRelease: no .apk asset on release $tagName")
            return mapOf(
                "available" to false,
                "reason" to "no_apk_asset",
                "tagName" to tagName,
                "publishedAt" to publishedAt,
                "releaseId" to releaseId,
                "currentVersion" to currentVersion,
            )
        }

        // The Dart side persists the last-seen release id in
        // secure storage. We always return the release metadata;
        // the Dart wrapper compares versions and fingerprints. A
        // missing SHA256SUMS is reported as an empty checksumsUrl and
        // makes the Dart side refuse the download.
        return mapOf(
            "available" to true,
            "tagName" to tagName,
            "apkUrl" to apkUrl,
            "checksumsUrl" to checksumsUrl,
            "changelog" to body,
            "publishedAt" to publishedAt,
            "releaseId" to releaseId,
            "remoteVersion" to remoteVersion,
            "assetId" to apkAssetId,
            "assetName" to apkAssetName,
            "assetUpdatedAt" to apkAssetUpdatedAt,
            "assetSize" to apkAssetSize,
            "buildFingerprint" to "$releaseId:$apkAssetId:$apkAssetUpdatedAt:$apkAssetSize",
            "currentVersion" to currentVersion,
        )
    }

    // ---- downloadChecksums ----

    /** Fetches the SHA256SUMS text, refusing anything over 64 KiB. */
    private fun downloadChecksums(url: String): String {
        val conn = (requireHttpsUrl(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 15_000
            setRequestProperty("User-Agent", "Vaulta-UpdateChannel/1.0")
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw RuntimeException("SHA256SUMS download failed: HTTP $code")
            }
            val bytes = conn.inputStream.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(8 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    out.write(buf, 0, n)
                    if (out.size() > MAX_CHECKSUMS_BYTES) {
                        throw RuntimeException("SHA256SUMS is too large")
                    }
                }
                out.toByteArray()
            }
            return String(bytes, Charsets.UTF_8)
        } finally {
            conn.disconnect()
        }
    }

    // ---- downloadApk ----

    /**
     * Streams the APK to filesDir/updates/<basename>.apk. Returns
     * the absolute file path so the Dart side can verify it and hand
     * it back to `openInstallPrompt`. A partial file is deleted if
     * the download fails.
     */
    private fun downloadApk(apkUrl: String): String {
        Log.d(TAG, "downloadApk: GET $apkUrl")
        val conn = (requireHttpsUrl(apkUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 30_000
            readTimeout = 60_000
            setRequestProperty("User-Agent", "Vaulta-UpdateChannel/1.0")
        }
        val dir = updatesDir.apply { mkdirs() }
        val rawName = apkUrl.substringAfterLast('/')
        val basename = if (SAFE_FILE_NAME.matches(rawName)) rawName else "vaulta-update.apk"
        val target = File(dir, basename)
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw RuntimeException("APK download failed: HTTP $code")
            }
            conn.inputStream.use { input ->
                FileOutputStream(target).use { output ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        output.write(buf, 0, n)
                    }
                }
            }
            Log.d(TAG, "downloadApk: wrote ${target.length()} bytes to ${target.absolutePath}")
            return target.absolutePath
        } catch (e: Throwable) {
            target.delete()
            throw e
        } finally {
            conn.disconnect()
        }
    }

    // ---- verification ----

    private fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * True when [apk] is signed by the certificate(s) of the
     * installed app. Returns false (never throws to "allow") when any
     * piece of signing information cannot be read.
     *
     * API 28+: uses GET_SIGNING_CERTIFICATES. The installed app's
     * current signer set must be contained in the archive's signer
     * set (its signing-certificate history when single-signed, which
     * keeps APK Signature Scheme v3 key rotation working). If the
     * platform returns no SigningInfo for the archive (seen on some
     * API 28 builds) it falls back to GET_SIGNATURES for the archive.
     *
     * Below API 28: uses GET_SIGNATURES and requires identical sets.
     */
    private fun isSignedByInstalledSigner(apk: File): Boolean {
        val pm = appContext.packageManager
        val packageName = appContext.packageName
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val installed = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                val installedCurrent = currentSigners(installed) ?: return false
                val archive = pm.getPackageArchiveInfo(apk.absolutePath, PackageManager.GET_SIGNING_CERTIFICATES)
                    ?: return false
                if (archive.packageName != packageName) return false
                val archiveSigners = allSigners(archive)
                    ?: legacySignatures(pm, apk)
                    ?: return false
                installedCurrent.isNotEmpty() && archiveSigners.containsAll(installedCurrent)
            } else {
                @Suppress("DEPRECATION")
                val installed = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                @Suppress("DEPRECATION")
                val installedSet = installed.signatures?.map { certDigest(it) }?.toSet()
                    ?: return false
                val archiveSet = legacySignatures(pm, apk) ?: return false
                installedSet.isNotEmpty() && installedSet == archiveSet
            }
        } catch (e: Throwable) {
            Log.w(TAG, "verifyApkSigner failed", e)
            false
        }
    }

    /** Current signer digests of an installed package (API 28+). */
    private fun currentSigners(info: PackageInfo): Set<String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        val signingInfo = info.signingInfo ?: return null
        val signers = if (signingInfo.hasMultipleSigners()) {
            signingInfo.apkContentsSigners
        } else {
            signingInfo.signingCertificateHistory?.takeLast(1)?.toTypedArray()
        } ?: return null
        return signers.map { certDigest(it) }.toSet()
    }

    /** Every signer digest an archive proves, incl. rotation history (API 28+). */
    private fun allSigners(info: PackageInfo): Set<String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        val signingInfo = info.signingInfo ?: return null
        val signers = if (signingInfo.hasMultipleSigners()) {
            signingInfo.apkContentsSigners
        } else {
            signingInfo.signingCertificateHistory
        } ?: return null
        return signers.map { certDigest(it) }.toSet().ifEmpty { null }
    }

    private fun legacySignatures(pm: PackageManager, apk: File): Set<String>? {
        @Suppress("DEPRECATION")
        val archive = pm.getPackageArchiveInfo(apk.absolutePath, PackageManager.GET_SIGNATURES)
            ?: return null
        if (archive.packageName != appContext.packageName) return null
        @Suppress("DEPRECATION")
        return archive.signatures?.map { certDigest(it) }?.toSet()?.ifEmpty { null }
    }

    private fun certDigest(signature: Signature): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    // ---- openInstallPrompt ----

    /**
     * Re-hashes [file] and re-checks its signer, then opens the
     * system install prompt through FileProvider. Any mismatch
     * deletes the file and returns false without launching anything.
     */
    private fun verifyThenInstall(file: File, expectedSha256: String): Boolean {
        if (!file.exists()) {
            Log.w(TAG, "openInstallPrompt: file does not exist: ${file.absolutePath}")
            return false
        }
        if (!sha256Hex(file).equals(expectedSha256, ignoreCase = true)) {
            Log.w(TAG, "openInstallPrompt: checksum mismatch, refusing to install")
            file.delete()
            return false
        }
        if (!isSignedByInstalledSigner(file)) {
            Log.w(TAG, "openInstallPrompt: signer mismatch, refusing to install")
            file.delete()
            return false
        }
        val authority = "${appContext.packageName}.fileprovider"
        val uri = try {
            FileProvider.getUriForFile(appContext, authority, file)
        } catch (e: Throwable) {
            Log.w(TAG, "openInstallPrompt: FileProvider failed", e)
            return false
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            appContext.startActivity(intent)
            Log.d(TAG, "openInstallPrompt: launched system installer for ${file.absolutePath}")
            true
        } catch (e: Throwable) {
            Log.w(TAG, "openInstallPrompt: no activity handled the intent", e)
            false
        }
    }

    companion object {
        private const val TAG = "Vaulta/Update"
        const val CHANNEL_NAME = "com.insyd.vaulta/update"
        private const val CHANNEL_DEV = "dev"
        private const val CHECKSUMS_ASSET = "SHA256SUMS"
        private const val MAX_CHECKSUMS_BYTES = 64 * 1024
        private val SAFE_FILE_NAME = Regex("""^[A-Za-z0-9._-]{1,128}\.apk$""")
    }
}
