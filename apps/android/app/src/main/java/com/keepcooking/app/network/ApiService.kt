package com.keepcooking.app.network

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.POST
import retrofit2.http.PUT
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * API transport for SyncEngine. Parity with iOS APISyncTransport:
 * push envelopes up, pull changes down. Same /sync/pull + /sync/push shape
 * as packages/contracts/openapi.yaml: both directions are BARE JSON arrays
 * of SyncEnvelope (`POST /sync/push` takes an array, returns the array of
 * server-won conflict envelopes; `GET /sync/pull` returns an array).
 */
interface ApiService {
    @POST("sync/push")
    suspend fun push(
        @Header("Authorization") auth: String?,
        @Body body: List<SyncEnvelopeDto>,
    ): List<SyncEnvelopeDto>

    @GET("sync/pull")
    suspend fun pull(
        @Header("Authorization") auth: String?,
        @Query("since") since: String?,
        @Query("householdId") householdId: String?,
    ): List<SyncEnvelopeDto>

    // --- E2E V1 (/v2/sync/:hash — blind server, parity with APIE2ETransport) ---

    @GET("v2/sync/{hash}")
    suspend fun pullEncrypted(
        @Header("Authorization") auth: String?,
        @Path("hash") hash: String,
        @Query("since") since: String?,
    ): List<EncryptedEnvelopeDto>

    @PUT("v2/sync/{hash}")
    suspend fun pushEncrypted(
        @Header("Authorization") auth: String?,
        @Path("hash") hash: String,
        @Body body: List<EncryptedEnvelopeDto>,
    ): E2EPushResponse

    @DELETE("v2/sync/{hash}")
    suspend fun wipeEncrypted(
        @Header("Authorization") auth: String?,
        @Path("hash") hash: String,
    ): E2EWipeResponse

    // --- Share (POST /share/cookbook — parity with ShareAPIClient) ---

    @POST("share/cookbook")
    suspend fun createCookbookShare(
        @Header("Authorization") auth: String?,
        @Body body: ShareCookbookRequest,
    ): ShareLinkDto
}

@kotlinx.serialization.Serializable
data class SyncEnvelopeDto(
    val id: String,
    val updatedAt: String, // ISO8601
    val deviceId: String,
    val deleted: Boolean = false,
    val entity: String, // recipe | ingredient | step | list | pantryItem | plan | menu
    val payload: JsonObject,
)

/** Wire shape for PUT/GET/DELETE /v2/sync/:hash (1:1 with openapi EncryptedEnvelope). */
@kotlinx.serialization.Serializable
data class EncryptedEnvelopeDto(
    val v: Int = 2,
    val alg: String = "AES-GCM-256",
    val kid: String,
    val householdHash: String,
    val id: String,
    val updatedAt: String, // millis-precision ISO-8601, exactly 3 fractional digits
    val deviceId: String,
    val deleted: Boolean = false,
    val entity: String, // recipe | list | pantryItem | plan | menu (no standalone children)
    val nonce: String, // base64, 12 random bytes
    val ciphertext: String, // base64 AES-GCM-256(raw-ciphertext + 16-byte tag)
)

/** PUT /v2/sync/:hash response body: `{ "stored": [<id>, ...] }`. */
@kotlinx.serialization.Serializable
data class E2EPushResponse(val stored: List<String> = emptyList())

@kotlinx.serialization.Serializable
data class E2EWipeResponse(val wiped: Int = 0)

@kotlinx.serialization.Serializable
data class ShareCookbookRequest(
    val householdId: String,
    val recipeIds: List<String>,
    val expiresInDays: Int = 30,
)

@kotlinx.serialization.Serializable
data class ShareLinkDto(
    val id: String,
    val url: String,
    val expiresAt: String = "",
)

fun createApiService(baseUrl: String = "https://keep-cooking-api.pshippy-245.workers.dev/"): ApiService {
    val logging = HttpLoggingInterceptor().apply { level = HttpLoggingInterceptor.Level.BASIC }
    val client = OkHttpClient.Builder().addInterceptor(logging).build()
    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    return Retrofit.Builder()
        .baseUrl(if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/")
        .client(client)
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build()
        .create(ApiService::class.java)
}
