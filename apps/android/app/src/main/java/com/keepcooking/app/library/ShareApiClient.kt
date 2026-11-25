package com.keepcooking.app.library

import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

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
 */
class ShareApiClient(
    private val baseUrl: String,
    private val betaToken: String? = null,
    private val userId: String = "beta-user",
    private val deviceId: String = "app",
    private val http: OkHttpClient = OkHttpClient(),
) {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** POST /share/cookbook → [ShareLink]. */
    fun createCookbookShare(
        householdId: String,
        recipeIds: List<String>,
        expiresInDays: Int = 30,
    ): ShareLink {
        val body = json.encodeToString(CookbookShareRequest(householdId, recipeIds, expiresInDays))
        val req = Request.Builder()
            .url(baseUrl.trimEnd('/') + "/share/cookbook")
            .post(body.toRequestBody("application/json".toMediaType()))
            .header("x-user-id", userId)
            .header("x-device-id", deviceId)
            .apply { if (!betaToken.isNullOrEmpty()) header("Authorization", "Bearer $betaToken") }
            .build()
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
