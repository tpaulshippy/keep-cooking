package com.keepcooking.app.network

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Response
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

    // --- Health (Advanced custom-server Test in Settings) ---

    @GET("health")
    suspend fun health(): JsonObject

    // --- Device identity (Pass 1 Ed25519 enroll; idempotent) ---

    /**
     * POST /v2/devices {deviceId, publicKey (standard b64, 32B), displayName?}.
     * Deliberately UNSIGNED (the server does not know this key yet).
     * 200/201 mark enrolled; a 409 means the deviceId is bound to a different
     * key (rotation is a non-goal) — see DeviceAuth.ensure for recovery.
     */
    @POST("v2/devices")
    suspend fun enrollDevice(@Body body: DeviceEnrollRequest): Response<JsonObject>

    // --- File import (POST /import; offline parse fallback when absent) ---

    /**
     * Server-side file import (Paprika/YAML/P1 formats). Optional: when the
     * server does not implement this route (404/5xx) callers fall back to the
     * on-device parser in `com.keepcooking.app.import`, so import works offline.
     * Request (`ImportRequest`, see packages/contracts/openapi.yaml `POST
     * /import` and api/src/import.ts): `{ filename, payload (base64 file
     * bytes), format?, text?, householdId?, importCookbooks?, dryRun? }`.
     * `format` is detected from filename/content when absent. Response
     * (`ImportReport`): `{ imported (count), ids, warnings }` — the server
     * persists via uid upsert; the client then relies on sync pull (or its
     * local offline parse) for the recipe rows.
     */
    @POST("import")
    suspend fun importFile(
        @Header("Authorization") auth: String?,
        @Body body: ImportRequestDto,
    ): ImportReportDto

    // --- Share (POST /share/cookbook — parity with ShareAPIClient) ---

    @POST("share/cookbook")
    suspend fun createCookbookShare(
        @Header("Authorization") auth: String?,
        @Body body: ShareCookbookRequest,
    ): ShareLinkDto

    // --- Photos (GET /photos/sign — mints a short-lived R2 download URL) ---

    /**
     * Mint a signed download URL for an R2 photo key (e.g. `photos/<id>/thumb.jpg`).
     * Unsigned read (no device signature or token required — the signature in
     * the returned URL is the capability, expiring in <15min).
     */
    @GET("photos/sign")
    suspend fun signPhoto(
        @Query("key") key: String,
    ): PhotoSignResponse
}

/** GET /photos/sign response: `{ url, expiresAt, key }` (see api/src/photos.ts signKey). */
@kotlinx.serialization.Serializable
data class PhotoSignResponse(
    val url: String = "",
    val expiresAt: String = "",
    val key: String = "",
)

@kotlinx.serialization.Serializable
data class SyncEnvelopeDto(
    val id: String,
    val updatedAt: String, // ISO8601
    val deviceId: String,
    val deleted: Boolean = false,
    val entity: String, // recipe | ingredient | step | list | pantryItem | plan | menu
    val payload: JsonObject,
)

/** POST /v2/devices request body: device enroll (idempotent per deviceId). */
@kotlinx.serialization.Serializable
data class DeviceEnrollRequest(
    val deviceId: String,
    val publicKey: String, // standard base64 (padded) of the 32-byte Ed25519 key
    val displayName: String? = null, // display hint, max 64 chars; never an identity
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

/** POST /import request body (see packages/contracts/openapi.yaml ImportRequest
 * and api/src/import.ts: the live server reads `filename` + `payload` (base64
 * file bytes), with `format` detected from filename/content when absent). */
@kotlinx.serialization.Serializable
data class ImportRequestDto(
    val filename: String,
    val payload: String, // base64-encoded file bytes
    val format: String? = null, // paprika-json | paprika-zip | yaml | html | …
    val text: String? = null, // decoded-text alternative to payload for text formats
    val householdId: String? = null,
    val importCookbooks: Boolean = true,
    val dryRun: Boolean = false,
)

/** POST /import response body (ImportReport: `{ imported (count), ids, warnings }`). */
@kotlinx.serialization.Serializable
data class ImportReportDto(
    val imported: Int = 0,
    val ids: List<String> = emptyList(),
    val warnings: List<String> = emptyList(),
    // OpenAPI-declared extras the live server may add later; defaulted so
    // unknown-shape responses still decode (ignoreUnknownKeys is on).
    val updated: Int = 0,
    val dryRun: Boolean = false,
    val cookbooksCreated: List<String> = emptyList(),
)

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

fun createApiService(
    baseUrl: String = "https://keepcooking.app/api/",
    deviceAuth: Interceptor? = null,
): ApiService {
    val logging = HttpLoggingInterceptor().apply { level = HttpLoggingInterceptor.Level.BASIC }
    val builder = OkHttpClient.Builder()
    // Device identity first so the signed headers are on the request before
    // it is sent. BASIC logging records only request/response lines, never
    // header values.
    if (deviceAuth != null) builder.addInterceptor(deviceAuth)
    builder.addInterceptor(logging)
    val client = builder.build()
    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    return Retrofit.Builder()
        .baseUrl(if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/")
        .client(client)
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build()
        .create(ApiService::class.java)
}
