// Keep Cooking — Lane clients Pass 1: Ed25519 device identity.
// sync/DeviceAuth.kt
//
// Sketch: every install generates an Ed25519 keypair at first launch
// (Android Keystore, NEVER the plaintext E2E DataStore file gated in
// SyncCrypto.kt:384-394), mints a persisted UUIDv4 deviceId, and enrolls once
// via POST /v2/devices (unsigned; 200/201 mark enrolled — a 409 means the id
// is bound to a different key and triggers a fresh-id re-enroll).
//
// Every MUTATING request (POST/PUT/DELETE, incl. /sync/push and the /v2/sync
// PUT) is signed with headers:
//   x-device-id, x-device-ts (unix millis, server Date.now basis),
// x-device-sig
// where x-device-sig = standard-base64(Ed25519(canonical)) and
//   canonical = METHOD + "\n" + path+query + "\n" + ts + "\n" + hex(SHA256(body))
// (body = raw request bytes, or empty for bodyless requests).
// ts MUST be unix millis: the server verifies against Date.now with a 5min
// skew window, so seconds values always fail verification.
// Reads (GET) carry x-device-id only and keep working without a signature.
//
// Contract notes (match the api lane: MemoryStore.enrollDevice):
//   - publicKey is STANDARD base64 (padded) of exactly 32 bytes.
//   - Re-enroll with the same key is idempotent; same deviceId + different
//     key is a 409 (server keeps the first key — rotation is a non-goal).
//
// Non-goals (Pass 1): rotation UI, Keystore sync opt-in, photo routes.
// `userId` ("beta-user") is a display hint only — the device key is the
// identity. `Build.MODEL` is a display hint for enrollment, never an identity.
//
// Ordering limitation (Pass 1): enrollment is best-effort async (offline
// safe). A mutating request fired before the first successful enroll goes
// out signed-but-unknown and the server rejects it; enrollment is retried on
// every app sync / launch, so a retry succeeds.
//
// Keystore coverage: Ed25519 in the Android Keystore requires recent platform
// versions; on runtimes without Keystore Ed25519 (plain-JVM unit tests,
// pre-33 devices) an ephemeral in-memory JCA key is used. Enrollment for an
// ephemeral key is retried every process and is never persisted (the key dies
// with the process). Reads still work everywhere; when no key is available at
// all, mutating requests go out unsigned and the server rejects them — the
// interceptor never throws, it just cannot sign.
package com.keepcooking.app.sync

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.keepcooking.app.network.DeviceEnrollRequest
import com.keepcooking.app.network.createApiService
import java.io.IOException
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.util.Base64 as JavaBase64
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import okhttp3.Interceptor
import okhttp3.Response
import okio.Buffer

/** Android Keystore alias for the Ed25519 device-signing key. */
const val DEVICE_AUTH_KEY_ALIAS = "keepcooking_device_ed25519"

/** Hex SHA-256 of the request body (empty input for bodyless requests). */
fun deviceAuthBodyHashHex(body: ByteArray?): String {
    val bytes = body ?: ByteArray(0)
    return java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }
}

/** Canonical bytes: METHOD + "\n" + path+query + "\n" + ts + "\n" + bodyHashHex. */
fun deviceAuthCanonical(method: String, pathQuery: String, ts: String, bodyHashHex: String): ByteArray =
    "${method.uppercase()}\n$pathQuery\n$ts\n$bodyHashHex".toByteArray(Charsets.UTF_8)

/** Path + query as signed, taken from the SERIALIZED request URL. */
fun deviceAuthPathQuery(url: String): String {
    var rest = url
    val schemeIdx = rest.indexOf("://")
    if (schemeIdx >= 0) {
        rest = rest.substring(schemeIdx + 3)
        val slash = rest.indexOf('/')
        if (slash < 0) return "/"
        rest = rest.substring(slash)
    }
    return rest.substringBefore("#").ifEmpty { "/" }
}

/**
 * Signed header set for a mutating request. Pure apart from [state.sign];
 * shared by [DeviceAuthInterceptor] and the direct-OkHttp clients
 * (ClipClient, ShareApiClient) so both sign identically.
 */
fun deviceSignedHeaders(
    method: String,
    url: String,
    body: ByteArray,
    state: DeviceAuthInterceptor.State,
): Map<String, String> {
    // Both platforms sign the serialized-URL substring (see
    // deviceAuthPathQuery) so iOS/Android agree byte-for-byte.
    val pathQuery = deviceAuthPathQuery(url)
    // ts is unix millis (server Date.now basis — seconds fail verification).
    val ts = System.currentTimeMillis().toString()
    val canonical = deviceAuthCanonical(method, pathQuery, ts, deviceAuthBodyHashHex(body))
    val sig = try {
        state.sign(canonical)
    } catch (t: Exception) {
        throw IOException("device signing failed", t)
    }
    return mapOf(
        "x-device-id" to state.deviceId,
        "x-user-id" to "beta-user",
        "x-device-ts" to ts,
        "x-device-sig" to JavaBase64.getEncoder().encodeToString(sig),
    )
}

/**
 * OkHttp application interceptor: attaches x-device-id (+ x-user-id) to
 * every request and Ed25519-signs mutating ones. State is a volatile global
 * populated by [DeviceAuth.ensure]; when null (key unavailable) requests go
 * out unsigned — reads keep working, mutating writes are rejected by the
 * server (401).
 */
class DeviceAuthInterceptor(
    private val stateProvider: () -> State?,
) : Interceptor {
    /** Device identity + signing closure (a fresh Signature per call). */
    data class State(
        val deviceId: String,
        val sign: (ByteArray) -> ByteArray,
    )

    override fun intercept(chain: Interceptor.Chain): Response {
        val req = chain.request()
        val state = stateProvider()
        val builder = req.newBuilder()
        if (state != null) builder.header("x-device-id", state.deviceId)
        if (req.header("x-user-id") == null) builder.header("x-user-id", "beta-user")
        if (state != null && req.method != "GET" && req.method != "HEAD") {
            val bodyBytes = req.body?.let { body ->
                Buffer().also { body.writeTo(it) }.readByteArray()
            } ?: ByteArray(0)
            for ((k, v) in deviceSignedHeaders(req.method, req.url.toString(), bodyBytes, state)) {
                builder.header(k, v)
            }
        }
        return chain.proceed(builder.build())
    }
}

/** Device identity: persisted UUID + Keystore Ed25519 key + enroll-once. */
object DeviceAuth {
    val KEY_DEVICE_ID = stringPreferencesKey("device_id")
    private val KEY_ENROLLED_FOR = stringPreferencesKey("device_enrolled_for")

    @Volatile
    private var state: DeviceAuthInterceptor.State? = null

    @Volatile
    private var memoryFallbackKey: KeyPair? = null

    @Volatile
    private var sharedInterceptor: DeviceAuthInterceptor? = null

    /**
     * In-process enrollment markers (see [enrollmentMarker]). Covers ephemeral
     * keys, which are never persisted, and avoids re-enrolling twice within
     * one process for an already-enrolled endpoint.
     */
    private val enrolledInMemory: MutableSet<String> = mutableSetOf()

    /** Current signed state, if the device key is available. */
    fun currentState(): DeviceAuthInterceptor.State? = state

    /** Singleton interceptor reading the volatile state (safe to share). */
    fun interceptor(): DeviceAuthInterceptor =
        sharedInterceptor ?: DeviceAuthInterceptor(::currentState).also { sharedInterceptor = it }

    /** Persisted UUIDv4 device id (stable across launches). */
    suspend fun deviceId(dataStore: DataStore<Preferences>): String {
        dataStore.data.map { it[KEY_DEVICE_ID] }.first()
            ?.takeIf { it.isNotEmpty() }?.let { return it }
        val fresh = UUID.randomUUID().toString()
        dataStore.edit { it[KEY_DEVICE_ID] = fresh }
        return fresh
    }

    /** Display hint for enrollment (≤64 chars server-side). Not an identity. */
    fun displayName(): String = "Android ${Build.MODEL}".take(64)

    /**
     * Loads the Ed25519 keypair from the Android Keystore, generating on
     * first launch. Falls back to an ephemeral in-memory JCA key on runtimes
     * without Keystore Ed25519 (plain-JVM unit tests); the signing key NEVER
     * touches the plaintext E2E DataStore file (see SyncCrypto.kt gate).
     */
    fun getOrCreateKeyPair(): KeyPair? {
        memoryFallbackKey?.let { return it }
        runCatching {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (ks.getKey(DEVICE_AUTH_KEY_ALIAS, null) as? PrivateKey)?.let { priv ->
                ks.getCertificate(DEVICE_AUTH_KEY_ALIAS)?.publicKey?.let { pub ->
                    return KeyPair(pub, priv)
                }
            }
            val kpg = KeyPairGenerator.getInstance("Ed25519", "AndroidKeyStore")
            kpg.initialize(
                KeyGenParameterSpec.Builder(DEVICE_AUTH_KEY_ALIAS, KeyProperties.PURPOSE_SIGN).build(),
            )
            return kpg.generateKeyPair()
        }
        return runCatching {
            KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        }.getOrNull()?.also { memoryFallbackKey = it }
    }

    /**
     * Standard-base64 (padded) of the 32-byte Ed25519 public key. The JCA
     * encoding is X.509 SPKI (12-byte prefix + 32-byte key); the raw key is
     * the trailing 32 bytes. The api lane rejects any other shape with 400.
     */
    fun publicKeyB64(publicKey: PublicKey): String? {
        val enc = runCatching { publicKey.encoded }.getOrNull() ?: return null
        if (enc.size < 32) return null
        return JavaBase64.getEncoder().encodeToString(enc.takeLast(32).toByteArray())
    }

    /**
     * Ensures the device identity: keypair + idempotent enroll. Returns the
     * signed state (or null when no key is available — reads still work).
     * POST /v2/devices is deliberately UNSIGNED (the server does not know
     * this key yet). 200/201 mark this endpoint enrolled; a 409 means the id
     * is bound to a different key, so a fresh deviceId is minted and enrolled
     * once. Enrollment is tracked per (endpoint, deviceId, publicKey) and
     * retried on every call until it succeeds — a failed first enroll never
     * sticks.
     */
    suspend fun ensure(dataStore: DataStore<Preferences>, baseUrl: String): DeviceAuthInterceptor.State? {
        var did = deviceId(dataStore)
        val kp = getOrCreateKeyPair() ?: return null
        val pubB64 = publicKeyB64(kp.public) ?: return null
        // Ephemeral (in-memory fallback) keys die with the process: never
        // trust — or write — the persisted marker for them, or the next launch
        // would skip enrollment under a fresh key and every signature would
        // fail verification.
        val ephemeral = kp === memoryFallbackKey
        val markerFor = { id: String -> enrollmentMarker(baseUrl, id, pubB64) }
        if (!isEnrolled(dataStore, markerFor(did), ephemeral)) {
            when (tryEnroll(baseUrl, did, pubB64)) {
                EnrollOutcome.Enrolled -> markEnrolled(dataStore, markerFor(did), ephemeral)
                EnrollOutcome.Conflict -> {
                    // Same id, different key on the server (rotation is a
                    // non-goal): mint a fresh id and enroll it once so later
                    // signatures verify. The old id stays server-bound and is
                    // simply abandoned.
                    did = UUID.randomUUID().toString()
                    dataStore.edit { it[KEY_DEVICE_ID] = did }
                    if (tryEnroll(baseUrl, did, pubB64) == EnrollOutcome.Enrolled) {
                        markEnrolled(dataStore, markerFor(did), ephemeral)
                    } else {
                        Log.w("DeviceAuth", "enroll conflict retry failed; retrying on next sync")
                    }
                }
                EnrollOutcome.Failed ->
                    Log.w("DeviceAuth", "enroll deferred (offline); retrying on next sync")
            }
        }
        val st = DeviceAuthInterceptor.State(did) { canonical ->
            val sig = Signature.getInstance("Ed25519")
            sig.initSign(kp.private)
            sig.update(canonical)
            sig.sign()
        }
        state = st
        return st
    }

    /**
     * Enrollment marker binding endpoint + device id + public key. A key
     * change (restored DataStore paired with a fresh Keystore key, or a new
     * ephemeral key each process) or a server switch invalidates any prior
     * marker, so the device re-enrolls instead of signing with a key the
     * server has never seen. Legacy values stored only the device id and
     * never match, forcing exactly one re-enroll after upgrade.
     */
    fun enrollmentMarker(baseUrl: String, deviceId: String, publicKeyB64: String): String =
        "${baseUrl.trim().trimEnd('/')}|$deviceId|$publicKeyB64"

    private suspend fun isEnrolled(dataStore: DataStore<Preferences>, marker: String, ephemeral: Boolean): Boolean {
        if (synchronized(enrolledInMemory) { enrolledInMemory.contains(marker) }) return true
        if (ephemeral) return false
        return dataStore.data.map { it[KEY_ENROLLED_FOR] }.first() == marker
    }

    private suspend fun markEnrolled(dataStore: DataStore<Preferences>, marker: String, ephemeral: Boolean) {
        synchronized(enrolledInMemory) { enrolledInMemory.add(marker) }
        if (!ephemeral) dataStore.edit { it[KEY_ENROLLED_FOR] = marker }
    }

    private enum class EnrollOutcome { Enrolled, Conflict, Failed }

    private suspend fun tryEnroll(baseUrl: String, deviceId: String, publicKeyB64: String): EnrollOutcome {
        return try {
            val resp = createApiService(baseUrl).enrollDevice(
                DeviceEnrollRequest(deviceId = deviceId, publicKey = publicKeyB64, displayName = displayName()),
            )
            when (resp.code()) {
                200, 201 -> EnrollOutcome.Enrolled
                409 -> EnrollOutcome.Conflict
                else -> EnrollOutcome.Failed
            }
        } catch (t: Exception) {
            EnrollOutcome.Failed
        }
    }

    /** Test seam: resets the volatile state (unit tests only). */
    fun resetForTests() {
        state = null
        memoryFallbackKey = null
        synchronized(enrolledInMemory) { enrolledInMemory.clear() }
    }
}
