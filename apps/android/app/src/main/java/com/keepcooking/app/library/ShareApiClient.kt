package com.keepcooking.app.library

import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import com.keepcooking.app.sync.DeviceAuthInterceptor
import com.keepcooking.app.sync.deviceSignedHeaders
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import okio.Buffer

/** Transport error for the share API (carries status codes, never content). */
sealed class ShareApiError(message: String) : IOException(message) {
    class HttpStatus(val status: Int) : ShareApiError("share failed with status $status")
    class Decode(cause: Throwable) : ShareApiError("share decode failed: ${cause.message}")
}

@Serializable
private data class CookbookShareRequest(
    val householdId: String,
    val recipeIds: List<String>,
    val expiresInDays: Int = 30,
)

/**
 * Minimal client for Lane 1 share routes. Base URL is injected so
 * previews/tests never hit the network. Mirrors iOS ShareAPIClient.
 * Pass the current [DeviceAuthInterceptor.State] to Ed25519-sign the
 * mutating POST (see sync/DeviceAuth.kt); without it the POST sends
 * identity headers only.
 */
class ShareApiClient(
    private val baseUrl: String,
    private val betaToken: String? = null,
    private val userId: String = "beta-user",
    private val deviceId: String = "app",
    private val http: OkHttpClient = OkHttpClient(),
    private val deviceState: DeviceAuthInterceptor.State? = null,
) {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** POST /share/cookbook → [ShareLink]. */
    fun createCookbookShare(
        householdId: String,
        recipeIds: List<String>,
        expiresInDays: Int = 30,
    ): ShareLink {
        val body = json.encodeToString(CookbookShareRequest(householdId, recipeIds, expiresInDays))
        val bodyReq = body.toRequestBody("application/json".toMediaType())
        val shareUrl = baseUrl.trimEnd('/') + "/share/cookbook"
        val builder = Request.Builder()
            .url(shareUrl)
            .post(bodyReq)
            .header("x-user-id", userId)
            .header("x-device-id", deviceState?.deviceId ?: deviceId)
            .apply { if (!betaToken.isNullOrEmpty()) header("Authorization", "Bearer $betaToken") }
        deviceState?.let { state ->
            val raw = Buffer().also { bodyReq.writeTo(it) }.readByteArray()
            for ((k, v) in deviceSignedHeaders("POST", shareUrl, raw, state)) builder.header(k, v)
        }
        val req = builder.build()
        http.newCall(req).execute().use { resp ->
            val raw = resp.body?.string().orEmpty()
            if (resp.code != 201) throw ShareApiError.HttpStatus(resp.code)
            try {
                return json.decodeFromString(ShareLink.serializer(), raw)
            } catch (e: Exception) {
                throw ShareApiError.Decode(e)
            }
        }
    }
}
