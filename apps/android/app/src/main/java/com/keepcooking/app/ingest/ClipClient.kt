package com.keepcooking.app.ingest

import com.keepcooking.app.sync.DeviceAuthInterceptor
import com.keepcooking.app.sync.deviceSignedHeaders
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import java.io.IOException

/** Transport error for the clip API (carries status codes, never content). */
sealed class ClipClientError(message: String) : IOException(message) {
    class BadUrl(url: String) : ClipClientError("bad clip url: $url")
    class HttpStatus(val status: Int) : ClipClientError("clip failed with status $status")
    class Decode(cause: Throwable) : ClipClientError("clip decode failed: ${cause.message}")
    /** Thrown before any network call when no device key is available to sign the mutating POST. */
    class NoDeviceKey : ClipClientError("clip requires an enrolled device key (enrollment incomplete)")
}

/**
 * POST /clip client — port of iOS ClipClient.
 * Base URL is injected so previews/tests never hit the network.
 *
 * Device auth: pass the current [DeviceAuthInterceptor.State] (e.g.
 * `DeviceAuth::currentState`) to Ed25519-sign the mutating POST (see
 * sync/DeviceAuth.kt). A null state fails fast with [ClipClientError.NoDeviceKey]:
 * an unsigned POST is rejected by the server (401), so it is never sent.
 * Reads are unaffected.
 */
class ClipClient(
    private val baseUrl: String,
    private val betaToken: String? = null,
    private val userId: String = "beta-user",
    private val http: OkHttpClient = OkHttpClient(),
    private val deviceState: DeviceAuthInterceptor.State? = null,
) {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** POST /clip with ClipRequest{url, caption, source}. Returns decoded ClipReport. */
    suspend fun clip(request: ClipRequest): ClipReport = withContext(Dispatchers.IO) {
        // Fail fast: without a key the POST would go out unsigned and prod
        // rejects it with 401. Never send a keyless mutating request.
        val signingState = deviceState ?: throw ClipClientError.NoDeviceKey()
        val url = (baseUrl.trimEnd('/') + "/clip")
        val body = json.encodeToString(request).toRequestBody("application/json".toMediaType())
        val builder = Request.Builder()
            .url(url)
            .post(body)
            .header("x-user-id", userId)
            .header("x-device-id", signingState.deviceId)
            .apply { if (!betaToken.isNullOrEmpty()) header("Authorization", "Bearer $betaToken") }
        // Signing failures throw IOException (fail loudly) — computed
        // outside the transport try/catch so they are never misreported
        // as a bad URL below.
        val raw = Buffer().also { body.writeTo(it) }.readByteArray()
        for ((k, v) in deviceSignedHeaders("POST", url, raw, signingState)) builder.header(k, v)
        val req = builder.build()
        try {
            http.newCall(req).execute().use { resp ->
                val raw = resp.body?.string().orEmpty()
                if (resp.code != 200) throw ClipClientError.HttpStatus(resp.code)
                try {
                    return@withContext json.decodeFromString(ClipReport.serializer(), raw)
                } catch (e: Exception) {
                    throw ClipClientError.Decode(e)
                }
            }
        } catch (e: ClipClientError) {
            throw e
        } catch (e: Exception) {
            throw ClipClientError.BadUrl(url)
        }
    }

    /** PII-safe log event for a completed clip. */
    fun logEvent(report: ClipReport, requestUrl: String?): ClipLogEvent =
        ClipLogEvent(
            strategy = report.strategy,
            host = clipHost(requestUrl ?: report.sourceUrl),
            confidence = report.confidence ?: 0.0,
        )
}
