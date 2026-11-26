// Keep Cooking — Android port of apps/ios/Sync/SyncCrypto.swift (E2E V1).
//
// Thin E2E V1 client crypto. The server is blind: envelope payloads are
// AES-GCM sealed with a per-household key derived from the user-supplied
// `syncCode`. Only the envelope HEADER travels in plaintext.
//
// Locked interfaces (must match iOS + api/src/e2e.ts):
//   - keyBytes(fromCode:householdId:kid:): HKDF<SHA256>(IKM syncCode,
//     salt "smidgen-sync-v1", info "smidgen-sync-v1/hh:<householdId>/kid:<kid>",
//     32 bytes).
//   - seal/open: AES-GCM; `ciphertext` carries ciphertext+tag concatenated
//     (tag = trailing 16 bytes), base-64 encoded. 12-byte random nonce per seal.
//   - householdHash(syncCode:householdId:): hex SHA-256 of
//     "smidgen-hh-v1" || syncCode || householdId (UTF-8 concat).
//   - kid(syncCode:): first 12 chars of base64url(SHA-256(syncCode UTF-8)).
//   - Invite bundle: receiver verifies hash == derive before storing anything.
//   - Key storage: syncCode lives in EncryptedSharedPreferences in prod; here
//     it is kept in a dedicated DataStore file ("keepcooking_e2e_secret") so
//     it never mixes with non-secret metadata (kid / hash / householdId).
//     TODO(security, E2E gate): that DataStore file is PLAINTEXT. Migrate the
//     syncCode to EncryptedFile/Keystore before enabling E2E in production.
package com.keepcooking.app.sync

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64 as JavaBase64
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Domain separator prefix for household-hash derivation (matches api/src/e2e.ts). */
const val HOUSEHOLD_HASH_DOMAIN = "smidgen-hh-v1"

/** Domain separator for the E2E header associated-data binding. */
const val E2E_AD_CONTEXT = "smidgen-e2e-ad-v1"

private const val HKDF_SALT = "smidgen-sync-v1"
private const val GCM_TAG_BITS = 128
private val jsonLenient = Json { ignoreUnknownKeys = true; explicitNulls = false }

// MARK: - Key derivation + household hash

/** HKDF<SHA256> extract step. */
private fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    val effectiveSalt = if (salt.isEmpty()) ByteArray(32) else salt
    mac.init(SecretKeySpec(effectiveSalt, "HmacSHA256"))
    return mac.doFinal(ikm)
}

/** HKDF<SHA256> expand step to [length] bytes. */
private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    val out = mutableListOf<Byte>()
    var previous = ByteArray(0)
    var counter = 1
    while (out.size < length) {
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        mac.update(previous)
        mac.update(info)
        mac.update(counter.toByte())
        previous = mac.doFinal()
        out.addAll(previous.toList())
        counter++
    }
    return out.take(length).toByteArray()
}

/**
 * Derives the 32-byte household data key from the invite syncCode.
 * HKDF<SHA256>(IKM: syncCode UTF-8, salt: "smidgen-sync-v1",
 * info: "smidgen-sync-v1/hh:<householdId>/kid:<kid>", L: 32).
 */
fun keyBytes(fromCode: String, householdId: String, kid: String): ByteArray {
    val prk = hkdfExtract(HKDF_SALT.toByteArray(Charsets.UTF_8), fromCode.toByteArray(Charsets.UTF_8))
    val info = "smidgen-sync-v1/hh:$householdId/kid:$kid".toByteArray(Charsets.UTF_8)
    return hkdfExpand(prk, info, 32)
}

fun keySpec(fromCode: String, householdId: String, kid: String): SecretKey =
    SecretKeySpec(keyBytes(fromCode, householdId, kid), "AES")

/** Hex SHA-256 of "smidgen-hh-v1" || syncCode || householdId (UTF-8 concat). */
fun householdHash(syncCode: String, householdId: String): String {
    val input = (HOUSEHOLD_HASH_DOMAIN + syncCode + householdId).toByteArray(Charsets.UTF_8)
    return MessageDigest.getInstance("SHA-256").digest(input).joinToString("") { "%02x".format(it) }
}

/** Key id: first 12 chars of base64url(SHA-256(syncCode UTF-8)), no padding. */
fun kid(syncCode: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(syncCode.toByteArray(Charsets.UTF_8))
    return JavaBase64.getUrlEncoder().withoutPadding().encodeToString(digest).take(12)
}

/** First 8 hex chars of a household hash — the secret-store account suffix. */
fun hashPrefix8(hash: String): String = hash.take(8)
/** SHA-256 hex of raw bytes (photo dedup parity with iOS sha256Hex). */
fun sha256HexBytes(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

// MARK: - Canonical timestamps + header AD binding

/** Canonical E2E timestamp: whole milliseconds (floor). */
fun canonicalE2EMillis(epochMillis: Long): Long = (epochMillis / 1000L) * 1000L

/**
 * Canonical associated data binding the sealed payload to its plaintext
 * routing header. AES-GCM authenticates (but does not encrypt) these bytes,
 * so a blind-server header swap fails open instead of decrypting under a
 * forged header. Encoded as a JSON string array — deterministic.
 */
fun e2eHeaderAD(
    v: Int,
    alg: String,
    kid: String,
    householdHash: String,
    id: String,
    updatedAtMillis: Long,
    deviceId: String,
    deleted: Boolean,
    entity: String,
): ByteArray {
    val parts = listOf(
        E2E_AD_CONTEXT, v.toString(), alg, kid, householdHash, id,
        canonicalE2EMillis(updatedAtMillis).toString(), deviceId,
        if (deleted) "1" else "0", entity,
    )
    val encoded = runCatching {
        // kotlinx-serialization JSON string array: deterministic, and fields
        // containing quotes/backslashes (e.g. deviceIds) round-trip exactly.
        // Manual "\"$it\"" quoting would corrupt them and break the AES-GCM
        // associated-data binding on open.
        jsonLenient.encodeToString(parts)
    }.getOrDefault(parts.joinToString(""))
    return encoded.toByteArray(Charsets.UTF_8)
}

// MARK: - Seal / open (AES-GCM)

/** Standard-alphabet base-64 without padding (java.util: identical bytes on JVM + Android, no Robolectric needed). */
private fun b64EncodeStd(bytes: ByteArray): String =
    JavaBase64.getEncoder().withoutPadding().encodeToString(bytes)

/** Decodes standard-alphabet base-64, accepting padded and unpadded inputs. */
private fun b64DecodeStd(s: String): ByteArray {
    val clean = s.trim()
    require(clean.isNotEmpty()) { "empty base64" }
    val padded = clean + "=".repeat((4 - clean.length % 4) % 4)
    return JavaBase64.getDecoder().decode(padded)
}

sealed class SyncCryptoException(message: String) : Exception(message) {
    class InvalidNonceEncoding : SyncCryptoException("invalid nonce encoding")
    class InvalidCiphertextEncoding : SyncCryptoException("invalid ciphertext encoding")
    class MalformedNonce : SyncCryptoException("malformed nonce")
    class MalformedCiphertext : SyncCryptoException("malformed ciphertext")
    class SealFailed(cause: Throwable?) : SyncCryptoException("seal failed: $cause")
    class OpenFailed : SyncCryptoException("open failed")
    class PayloadDecode(detail: String) : SyncCryptoException("payload decode: $detail")
}

/**
 * AES-GCM seals `payload`. Returns base-64 (nonce, ciphertext) where
 * `ciphertext` is raw-ciphertext + 16-byte tag, base-64 encoded.
 * `authenticating`, when non-empty, is bound as associated data.
 */
fun seal(
    payload: ByteArray,
    key: SecretKey,
    authenticating: ByteArray = ByteArray(0),
): Pair<String, String> {
    try {
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.ENCRYPT_MODE, key,
            GCMParameterSpec(GCM_TAG_BITS, nonce),
        )
        if (authenticating.isNotEmpty()) cipher.updateAAD(authenticating)
        val combined = cipher.doFinal(payload) // ciphertext || 16-byte tag
        return Pair(b64EncodeStd(nonce), b64EncodeStd(combined))
    } catch (t: Throwable) {
        throw SyncCryptoException.SealFailed(t)
    }
}

/** Inverse of [seal]. Never leaks key-adjacent detail. */
fun open(
    nonceB64: String,
    ciphertextB64: String,
    key: SecretKey,
    authenticating: ByteArray = ByteArray(0),
): ByteArray {
    // Accept both padded and unpadded inputs (standard alphabet).
    val nonceData = runCatching { b64DecodeStd(nonceB64) }.getOrNull()
        ?: throw SyncCryptoException.InvalidNonceEncoding()
    val combined = runCatching { b64DecodeStd(ciphertextB64) }.getOrNull()
        ?: throw SyncCryptoException.InvalidCiphertextEncoding()
    if (nonceData.size != 12) throw SyncCryptoException.MalformedNonce()
    if (combined.size < 16) throw SyncCryptoException.MalformedCiphertext()
    try {
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE, key,
            GCMParameterSpec(GCM_TAG_BITS, nonceData),
        )
        if (authenticating.isNotEmpty()) cipher.updateAAD(authenticating)
        return cipher.doFinal(combined)
    } catch (e: SyncCryptoException) {
        throw e
    } catch (_: Throwable) {
        throw SyncCryptoException.OpenFailed()
    }
}

/** Seals an envelope-payload JSON object (canonical string encoding). */
fun sealPayload(
    payload: JsonObject,
    key: SecretKey,
    authenticating: ByteArray = ByteArray(0),
): Pair<String, String> =
    seal(payload.toString().toByteArray(Charsets.UTF_8), key, authenticating)

/** Inverse of [sealPayload]. */
fun openPayload(
    nonceB64: String,
    ciphertextB64: String,
    key: SecretKey,
    authenticating: ByteArray = ByteArray(0),
): JsonObject {
    val data = open(nonceB64, ciphertextB64, key, authenticating)
    try {
        return jsonLenient.parseToJsonElement(data.toString(Charsets.UTF_8)) as JsonObject
    } catch (t: Throwable) {
        throw SyncCryptoException.PayloadDecode(t.toString())
    }
}

// MARK: - Invite bundle

/** Share payload for adding a device to a household (out-of-band: QR / message). */
@Serializable
data class SyncInviteBundle(
    val householdId: String,
    val syncCode: String,
    val kid: String,
    val hash: String,
    val endpointHint: String? = null,
) {
    /**
     * True when `hash` equals the hash derived from `syncCode`+`householdId`
     * AND `kid` equals the key id derived from `syncCode`. The kid check
     * rejects bundles whose key locator does not match the code (iOS parity);
     * without it a mismatched kid would derive a wrong household key and
     * every open would fail closed later instead of failing fast here.
     */
    fun verify(): Boolean =
        hash == householdHash(syncCode, householdId) && kid == kid(syncCode)

    companion object {
        fun make(householdId: String, syncCode: String, kid: String, endpointHint: String? = null) =
            SyncInviteBundle(
                householdId = householdId,
                syncCode = syncCode,
                kid = kid,
                hash = householdHash(syncCode, householdId),
                endpointHint = endpointHint,
            )
    }
}

/** Non-secret E2E metadata (DataStore). The syncCode NEVER lives here. */
@Serializable
data class E2EMetadata(
    val householdId: String,
    val kid: String,
    val hash: String,
    val endpointHint: String? = null,
)

/** Active credential: metadata + the secret-store code + derived key. */
data class E2ECredential(val metadata: E2EMetadata, val syncCode: String) {
    fun key(): SecretKey = keySpec(syncCode, metadata.householdId, metadata.kid)
}

// MARK: - Invite bundle JSON + first-run identity

class E2EJoinException(message: String) : Exception(message)

/**
 * Encodes an invite bundle for out-of-band transport (share sheet / copy).
 * Matches the iOS bundle shape: {v, householdId, syncCode, kid, hash,
 * endpointHint?} with v == "2". The syncCode travels only inside this
 * user-shared payload — never in logs or prefs files.
 */
fun inviteBundleJson(bundle: SyncInviteBundle): String {
    val obj = buildJsonObject {
        put("v", JsonPrimitive("2"))
        put("householdId", JsonPrimitive(bundle.householdId))
        put("syncCode", JsonPrimitive(bundle.syncCode))
        put("kid", JsonPrimitive(bundle.kid))
        put("hash", JsonPrimitive(bundle.hash))
        bundle.endpointHint?.takeIf { it.isNotEmpty() }?.let { put("endpointHint", JsonPrimitive(it)) }
    }
    return Json.encodeToString(JsonObject.serializer(), obj)
}

/**
 * Parses pasted invite text, verifying hash == derive AND kid == derive
 * before returning. Stores nothing — the caller decides to acceptInvite.
 */
fun parseInviteBundle(pasted: String): SyncInviteBundle {
    val obj = runCatching {
        Json.parseToJsonElement(pasted.trim()).jsonObject
    }.getOrNull() ?: throw E2EJoinException("That text is not a Keep Cooking invite code.")
    if (obj["v"]?.jsonPrimitive?.content != "2") {
        throw E2EJoinException("That text is not a Keep Cooking invite code.")
    }
    val householdId = obj["householdId"]?.jsonPrimitive?.content.orEmpty()
    val syncCode = obj["syncCode"]?.jsonPrimitive?.content.orEmpty()
    val kidValue = obj["kid"]?.jsonPrimitive?.content.orEmpty()
    val hash = obj["hash"]?.jsonPrimitive?.content.orEmpty()
    val hint = obj["endpointHint"]?.jsonPrimitive?.contentOrNull
    if (householdId.isEmpty() || syncCode.isEmpty() || kidValue.isEmpty() || hash.isEmpty()) {
        throw E2EJoinException("That text is not a Keep Cooking invite code.")
    }
    if (hash != householdHash(syncCode, householdId)) {
        throw E2EJoinException("Code does not match — it was mistyped or tampered with.")
    }
    if (kid(syncCode) != kidValue) {
        throw E2EJoinException("Key ID mismatch — code was created by an incompatible app.")
    }
    return SyncInviteBundle(householdId, syncCode, kidValue, hash, hint)
}

/**
 * Returns the active credential, creating a fresh household identity
 * (random 32-byte base64 syncCode) on first run. Existing identities are
 * returned untouched — rotation is a deliberate Settings action, not a
 * side effect.
 */
suspend fun ensureE2EIdentity(
    metaStore: DataStore<Preferences>,
    secretStore: DataStore<Preferences>,
    householdId: String,
): E2ECredential? {
    E2EKeyStore.loadActive(metaStore, secretStore)?.let { return it }
    val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
    val syncCode = JavaBase64.getEncoder().encodeToString(bytes)
    val hh = householdId.trim().ifEmpty { "hh-demo" }
    val bundle = SyncInviteBundle.make(hh, syncCode, kid(syncCode))
    if (!E2EKeyStore.acceptInvite(metaStore, secretStore, bundle)) return null
    return E2EKeyStore.loadActive(metaStore, secretStore)
}

/**
 * E2E key store. Secret (syncCode) lives in [secretStore] under account
 * "smidgen.e2ee.<hashPrefix8>"; metadata lives in [metaStore]. Parity with
 * iOS E2EKeyStore (Keychain + UserDefaults split) — EXCEPT the secret
 * storage backend (see below).
 *
 * TODO(security): [secretStore] persists the syncCode in PLAINTEXT
 * (Preferences DataStore XML). This is a pass-1 placeholder so E2E sync can
 * be exercised end to end. Production MUST move the syncCode to EncryptedFile
 * (Tink/Keystore-backed) or the Android Keystore before E2E is enabled for
 * real households — enabling E2E on this plaintext store would leave the
 * household key recoverable from app-private storage. Gate: do not ship E2E
 * onboarding until this TODO is resolved (see apps/android/README.md).
 */
object E2EKeyStore {
    private val KEY_KID = stringPreferencesKey("smidgen.e2ee.kid")
    private val KEY_HASH = stringPreferencesKey("smidgen.e2ee.householdHash")
    private val KEY_HOUSEHOLD = stringPreferencesKey("smidgen.e2ee.householdId")
    private val KEY_HINT = stringPreferencesKey("smidgen.e2ee.endpointHint")

    fun secretAccount(hash: String) = "smidgen.e2ee.${hashPrefix8(hash)}"
    // TODO(security): plaintext DataStore key — see the E2EKeyStore KDoc gate
    // (EncryptedFile/Keystore) before enabling E2E in production.
    private fun secretKey(hash: String) = stringPreferencesKey(secretAccount(hash))

    suspend fun saveSyncCode(secretStore: DataStore<Preferences>, syncCode: String, hash: String): Boolean =
        runCatching {
            secretStore.edit { it[secretKey(hash)] = syncCode }
            true
        }.getOrDefault(false)

    suspend fun loadSyncCode(secretStore: DataStore<Preferences>, hash: String): String? =
        secretStore.data.map { it[secretKey(hash)] }.first().takeUnless { it.isNullOrEmpty() }

    suspend fun deleteSyncCode(secretStore: DataStore<Preferences>, hash: String): Boolean =
        runCatching {
            secretStore.edit { it.remove(secretKey(hash)) }
            true
        }.getOrDefault(false)

    suspend fun saveMetadata(metaStore: DataStore<Preferences>, metadata: E2EMetadata) {
        metaStore.edit {
            it[KEY_KID] = metadata.kid
            it[KEY_HASH] = metadata.hash
            it[KEY_HOUSEHOLD] = metadata.householdId
            if (metadata.endpointHint != null) it[KEY_HINT] = metadata.endpointHint
            else it.remove(KEY_HINT)
        }
    }

    suspend fun loadMetadata(metaStore: DataStore<Preferences>): E2EMetadata? {
        val prefs = metaStore.data.first()
        val k = prefs[KEY_KID]; val h = prefs[KEY_HASH]; val hh = prefs[KEY_HOUSEHOLD]
        if (k.isNullOrEmpty() || h.isNullOrEmpty() || hh.isNullOrEmpty()) return null
        return E2EMetadata(householdId = hh, kid = k, hash = h, endpointHint = prefs[KEY_HINT])
    }

    suspend fun clearMetadata(metaStore: DataStore<Preferences>) {
        metaStore.edit {
            it.remove(KEY_KID); it.remove(KEY_HASH); it.remove(KEY_HOUSEHOLD); it.remove(KEY_HINT)
        }
    }

    /**
     * Verifies the bundle (hash == derive), then stores the code in the secret
     * store and metadata separately. Secret commits FIRST so a failure leaves
     * the prior credential fully intact.
     */
    suspend fun acceptInvite(
        metaStore: DataStore<Preferences>,
        secretStore: DataStore<Preferences>,
        bundle: SyncInviteBundle,
    ): Boolean {
        if (!bundle.verify()) return false
        if (!saveSyncCode(secretStore, bundle.syncCode, bundle.hash)) return false
        saveMetadata(metaStore, E2EMetadata(bundle.householdId, bundle.kid, bundle.hash, bundle.endpointHint))
        return true
    }

    /** Loads the active credential, re-verifying hash == derive before returning. */
    suspend fun loadActive(
        metaStore: DataStore<Preferences>,
        secretStore: DataStore<Preferences>,
    ): E2ECredential? {
        val meta = loadMetadata(metaStore) ?: return null
        val code = loadSyncCode(secretStore, meta.hash) ?: return null
        if (householdHash(code, meta.householdId) != meta.hash) return null
        return E2ECredential(meta, code)
    }

    suspend fun reset(
        metaStore: DataStore<Preferences>,
        secretStore: DataStore<Preferences>,
        hash: String? = null,
    ) {
        val target = hash ?: metaStore.data.map { it[KEY_HASH] }.first()
        if (!target.isNullOrEmpty()) deleteSyncCode(secretStore, target)
        clearMetadata(metaStore)
    }
}
