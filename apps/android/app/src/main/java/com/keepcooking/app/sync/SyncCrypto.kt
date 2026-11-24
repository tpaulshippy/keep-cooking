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
package com.keepcooking.app.sync

import android.util.Base64
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

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
    val b64 = Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    return b64.take(12)
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
        "[" + parts.joinToString(",") { "\"$it\"" } + "]"
    }.getOrDefault(parts.joinToString(""))
    return encoded.toByteArray(Charsets.UTF_8)
}

// MARK: - Seal / open (AES-GCM)

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
        val flags = Base64.NO_WRAP or Base64.NO_PADDING
        return Pair(
            Base64.encodeToString(nonce, flags),
            Base64.encodeToString(combined, flags),
        )
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
    val flags = Base64.NO_WRAP or Base64.NO_PADDING
    // Accept both padded and unpadded inputs.
    val nonceData = runCatching { Base64.decode(nonceB64, flags) }.getOrNull()
        ?: runCatching { Base64.decode(nonceB64, Base64.NO_WRAP) }.getOrNull()
        ?: throw SyncCryptoException.InvalidNonceEncoding()
    val combined = runCatching { Base64.decode(ciphertextB64, flags) }.getOrNull()
        ?: runCatching { Base64.decode(ciphertextB64, Base64.NO_WRAP) }.getOrNull()
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
    /** True when `hash` equals the hash derived from `syncCode`+`householdId`. */
    fun verify(): Boolean = hash == householdHash(syncCode, householdId)

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

/**
 * E2E key store. Secret (syncCode) lives in [secretStore] under account
 * "smidgen.e2ee.<hashPrefix8>"; metadata lives in [metaStore]. Parity with
 * iOS E2EKeyStore (Keychain + UserDefaults split).
 */
object E2EKeyStore {
    private val KEY_KID = stringPreferencesKey("smidgen.e2ee.kid")
    private val KEY_HASH = stringPreferencesKey("smidgen.e2ee.householdHash")
    private val KEY_HOUSEHOLD = stringPreferencesKey("smidgen.e2ee.householdId")
    private val KEY_HINT = stringPreferencesKey("smidgen.e2ee.endpointHint")

    fun secretAccount(hash: String) = "smidgen.e2ee.${hashPrefix8(hash)}"
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
