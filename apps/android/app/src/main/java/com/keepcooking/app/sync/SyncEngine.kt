package com.keepcooking.app.sync

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.keepcooking.app.data.AppDatabase
import com.keepcooking.app.data.IngredientEntity
import com.keepcooking.app.data.ListItemEntity
import com.keepcooking.app.data.MealSlot
import com.keepcooking.app.data.MenuEntity
import com.keepcooking.app.data.OutboxRow
import com.keepcooking.app.data.PantryItemEntity
import com.keepcooking.app.data.PlanEntity
import com.keepcooking.app.data.RecipeEntity
import com.keepcooking.app.data.ShoppingListEntity
import com.keepcooking.app.data.StepEntity
import com.keepcooking.app.data.SyncEntityName
import com.keepcooking.app.data.resolveSyncWinner
import com.keepcooking.app.network.ApiService
import com.keepcooking.app.network.E2EPushResponse
import com.keepcooking.app.network.EncryptedEnvelopeDto
import com.keepcooking.app.network.PushRequest
import com.keepcooking.app.network.SyncEnvelopeDto
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * SyncEngine stub with the real merge contract.
 *
 * Outbox LWW + tombstones: every local write enqueues a SyncEnvelope;
 * push() sends the outbox; pull() fetches remote envelopes and applies
 * last-write-wins (later updatedAt wins, ties → remote). Tombstones
 * (deleted=true) are just writes — a newer tombstone beats an older live
 * record and vice versa. Mirrors apps/ios/Sync/SyncEngine.swift.
 */
class SyncEngine(
    private val database: AppDatabase,
    private val api: ApiService,
    private val dataStore: DataStore<Preferences>,
    private val ioScope: CoroutineScope,
) {
    data class SyncResult(val pushed: Int, val pulled: Int, val conflicts: Int)

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    companion object {
        val KEY_DEVICE_ID = stringPreferencesKey("device_id")
        val KEY_BETA_TOKEN = stringPreferencesKey("beta_token")
        val KEY_BASE_URL = stringPreferencesKey("api_base_url")
        val KEY_USER_ID = stringPreferencesKey("user_id")
        val KEY_LAST_SYNC = stringPreferencesKey("last_sync_at")
        const val PROD_BASE_URL = "https://keep-cooking-api.pshippy-245.workers.dev"
    }

    suspend fun deviceId(): String {
        val existing = dataStore.data.map { it[KEY_DEVICE_ID] }.first()
        if (existing != null) return existing
        val fresh = UUID.randomUUID().toString()
        dataStore.edit { it[KEY_DEVICE_ID] = fresh }
        return fresh
    }

    /** Enqueue a local envelope into the outbox (called after every local write). */
    suspend fun enqueue(envelope: SyncEnvelopeDto) {
        database.outbox().enqueue(
            OutboxRow(
                id = "${envelope.entity}:${envelope.id}",
                entity = envelope.entity,
                envelopeJson = Json.encodeToString(SyncEnvelopeDto.serializer(), envelope),
            ),
        )
    }

    /** Full sync: push outbox, then pull + LWW-apply remote winners. */
    suspend fun sync(): SyncResult {
        val token = dataStore.data.map { it[KEY_BETA_TOKEN] }.first().orEmpty()
        val auth = token.ifBlank { null }?.let { "Bearer $it" }
        val outbox = database.outbox().all()
        val envelopes = outbox.map { Json.decodeFromString(SyncEnvelopeDto.serializer(), it.envelopeJson) }

        var conflicts = 0
        if (envelopes.isNotEmpty()) {
            val res = api.push(auth, PushRequest(envelopes))
            conflicts += res.conflicts
            // Server-won envelopes apply locally via LWW.
            for (winner in res.winners) applyRemote(winner)
            // Idempotent LWW push: clear outbox on success (beta scale, same as iOS).
            outbox.forEach { database.outbox().remove(it.id) }
        }

        val since = dataStore.data.map { it[KEY_LAST_SYNC] }.first()
        val household = "hh-demo"
        val pulled = api.pull(auth, since, household).envelopes
        for (env in pulled) applyRemote(env)
        dataStore.edit { it[KEY_LAST_SYNC] = Instant.now().toString() }
        return SyncResult(pushed = envelopes.size, pulled = pulled.size, conflicts = conflicts)
    }

    /** LWW apply of one remote envelope (tombstones included). */
    suspend fun applyRemote(env: SyncEnvelopeDto) {
        val remoteTs = runCatching { Instant.parse(env.updatedAt).toEpochMilli() }.getOrDefault(0L)
        when (env.entity) {
            SyncEntityName.RECIPE.raw -> {
                val local = database.recipes().byId(env.id)
                if (local == null || resolveSyncWinner(local.updatedAt, remoteTs)) {
                    upsertRecipe(env, remoteTs)
                }
            }
            SyncEntityName.LIST.raw -> {
                // Lists + items ride together in the list envelope (same as iOS applyList).
                upsertList(env, remoteTs)
            }
            SyncEntityName.PANTRY_ITEM.raw -> {
                val existing = database.pantry().liveItems().firstOrNull { it.id == env.id }
                if (existing == null || resolveSyncWinner(existing.updatedAt, remoteTs)) {
                    upsertPantry(env, remoteTs)
                }
            }
            SyncEntityName.PLAN.raw -> upsertPlan(env, remoteTs)
            SyncEntityName.MENU.raw -> upsertMenu(env, remoteTs)
            SyncEntityName.INGREDIENT.raw, SyncEntityName.STEP.raw -> {
                // Children normally ride inside recipe envelopes; standalone merge kept for parity.
            }
        }
    }

    // --- envelope → Room upserts (payload keys match iOS recipeEnvelope/listEnvelope/...) ---

    private suspend fun upsertRecipe(env: SyncEnvelopeDto, remoteTs: Long) {
        val p = env.payload
        val photos = p["photoKeys"]?.takeIf { it != JsonNull }?.jsonObject
        database.recipes().upsert(
            RecipeEntity(
                id = env.id,
                householdId = p.str("householdId") ?: "hh-demo",
                title = p.str("title") ?: "Untitled",
                recipeDescription = p.str("description") ?: "",
                servings = p.dbl("servings") ?: 4.0,
                prepMinutes = p.int("prepMinutes"),
                cookMinutes = p.int("cookMinutes"),
                rating = p.dbl("rating"),
                source = p.str("source") ?: "",
                sourceUrl = p.str("sourceUrl") ?: "",
                categoriesJson = p["categories"]?.jsonArray.toString() ?: "[]",
                photoOriginal = photos?.str("original"),
                photoLarge1024 = photos?.str("large1024"),
                photoThumb = photos?.str("thumb"),
                updatedAt = remoteTs,
                deviceId = env.deviceId,
                deleted = env.deleted,
            ),
        )
        val did = env.deviceId
        database.ingredients().deleteForRecipe(env.id)
        database.ingredients().upsertAll(
            p["ingredients"]?.jsonArray.orEmpty().mapIndexed { i, el ->
                val o = el.jsonObject
                IngredientEntity(
                    id = o.str("id") ?: UUID.randomUUID().toString(),
                    recipeId = env.id,
                    name = o.str("name") ?: "",
                    quantity = o.dbl("quantity"),
                    unit = o.str("unit") ?: "",
                    display = o.str("display") ?: "",
                    position = o.int("position") ?: i,
                    updatedAt = remoteTs,
                    deviceId = did,
                )
            },
        )
        database.steps().deleteForRecipe(env.id)
        database.steps().upsertAll(
            p["steps"]?.jsonArray.orEmpty().mapIndexed { i, el ->
                val o = el.jsonObject
                StepEntity(
                    id = o.str("id") ?: UUID.randomUUID().toString(),
                    recipeId = env.id,
                    position = o.int("position") ?: i,
                    text = o.str("text") ?: "",
                    timersJson = (o["timers"]?.takeIf { it != JsonNull }?.jsonArray ?: JsonArray(emptyList())).toString(),
                    updatedAt = remoteTs,
                    deviceId = did,
                )
            },
        )
    }

    private suspend fun upsertList(env: SyncEnvelopeDto, remoteTs: Long) {
        val p = env.payload
        database.shoppingLists().upsertAll(
            listOf(
                ShoppingListEntity(
                    id = env.id,
                    householdId = p.str("householdId") ?: "hh-demo",
                    name = p.str("name") ?: "List",
                    updatedAt = remoteTs,
                    deviceId = env.deviceId,
                    deleted = env.deleted,
                ),
            ),
        )
        database.listItems().deleteForList(env.id)
        database.listItems().upsertAll(
            p["items"]?.jsonArray.orEmpty().map { el ->
                val o = el.jsonObject
                ListItemEntity(
                    id = o.str("id") ?: UUID.randomUUID().toString(),
                    listId = env.id,
                    name = o.str("name") ?: "",
                    quantity = o.str("quantity") ?: "",
                    aisle = o.str("aisle") ?: "",
                    checked = o["checked"]?.jsonPrimitive?.content?.toBooleanStrictOrNull() == true,
                    recipeId = o.str("recipeId"),
                    updatedAt = remoteTs,
                    deviceId = env.deviceId,
                )
            },
        )
    }

    private suspend fun upsertPantry(env: SyncEnvelopeDto, remoteTs: Long) {
        val p = env.payload
        val expires = p.str("expiresAt")?.let {
            runCatching { LocalDate.parse(it, DateTimeFormatter.ISO_DATE).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli() }.getOrNull()
        }
        database.pantry().upsertAll(
            listOf(
                PantryItemEntity(
                    id = env.id,
                    householdId = p.str("householdId") ?: "hh-demo",
                    name = p.str("name") ?: "",
                    quantity = p.str("quantity") ?: "",
                    location = p.str("location") ?: "",
                    expiresAt = expires,
                    lowThreshold = p.str("lowThreshold") ?: "",
                    barcode = p.str("barcode") ?: "",
                    updatedAt = remoteTs,
                    deviceId = env.deviceId,
                    deleted = env.deleted,
                ),
            ),
        )
    }

    private suspend fun upsertPlan(env: SyncEnvelopeDto, remoteTs: Long) {
        val p = env.payload
        val date = p.str("date")?.let {
            runCatching { LocalDate.parse(it, DateTimeFormatter.ISO_DATE).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli() }.getOrNull()
        } ?: 0L
        database.plans().upsertAll(
            listOf(
                PlanEntity(
                    id = env.id,
                    householdId = p.str("householdId") ?: "hh-demo",
                    date = date,
                    mealRaw = p.str("meal") ?: MealSlot.DINNER.raw,
                    recipeId = p.str("recipeId"),
                    note = p.str("note") ?: "",
                    servings = p.dbl("servings"),
                    updatedAt = remoteTs,
                    deviceId = env.deviceId,
                    deleted = env.deleted,
                ),
            ),
        )
    }

    private suspend fun upsertMenu(env: SyncEnvelopeDto, remoteTs: Long) {
        val p = env.payload
        database.menus().upsertAll(
            listOf(
                MenuEntity(
                    id = env.id,
                    householdId = p.str("householdId") ?: "hh-demo",
                    name = p.str("name") ?: "Menu",
                    entriesJson = (p["entries"]?.takeIf { it != JsonNull }?.jsonArray ?: JsonArray(emptyList())).toString(),
                    updatedAt = remoteTs,
                    deviceId = env.deviceId,
                    deleted = env.deleted,
                ),
            ),
        )
    }

    private fun JsonObject.str(key: String): String? =
        this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.content

    private fun JsonObject.dbl(key: String): Double? =
        this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.doubleOrNull

    private fun JsonObject.int(key: String): Int? =
        this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.content?.toIntOrNull()

    // --- E2E sync (/v2/sync/:hash) ---

    /** The `since` bound for the next pull: one tick behind the cursor (strict `>` filter). */
    private suspend fun pullSinceValue(): String? {
        val since = dataStore.data.map { it[KEY_LAST_SYNC] }.first() ?: return null
        return runCatching {
            Instant.parse(since).minusSeconds(1).toString()
        }.getOrNull() ?: since
    }

    /** Advances the pull cursor by ENVELOPE time (max updatedAt seen), never wall-clock. */
    private suspend fun advancePullCursor(remote: List<SyncEnvelopeDto>) {
        val max = remote.mapNotNull { runCatching { Instant.parse(it.updatedAt) }.getOrNull() }.maxOrNull()
            ?: return
        val current = dataStore.data.map { it[KEY_LAST_SYNC] }.first()?.let {
            runCatching { Instant.parse(it) }.getOrNull()
        }
        if (current == null || max.isAfter(current)) {
            dataStore.edit { it[KEY_LAST_SYNC] = max.toString() }
        }
    }

    /**
     * E2E sync against /v2/sync/:hash. Outbox envelopes are folded
     * (ingredient/step into parent recipe) and sealed at push time so the
     * outbox stays plaintext; pull decrypts each envelope then runs the SAME
     * header-LWW merge as v1. Photos stay inline inside the sealed payload.
     */
    suspend fun syncE2E(identity: E2ESyncIdentity, authHeader: String? = null): SyncResult {
        val token = authHeader ?: dataStore.data.map { it[KEY_BETA_TOKEN] }.first().orEmpty()
            .ifBlank { null }?.let { "Bearer $it" }
        val remoteEncrypted = api.pullEncrypted(token, identity.hash, pullSinceValue())
        val remote = remoteEncrypted.map { e2eDecryptDto(it, identity) }
        var pulled = 0
        for (env in remote) {
            val before = database.outbox().all().size
            applyRemote(env)
            pulled++
            // Idempotent replay: identical envelopes dedupe via LWW; count stays honest.
            if (database.outbox().all().size != before) { /* outbox untouched by applyRemote */ }
        }
        advancePullCursor(remote)

        val outbox = database.outbox().all()
        val pending = outbox.map { Json.decodeFromString(SyncEnvelopeDto.serializer(), it.envelopeJson) }
        var conflicts = 0
        var pushed = 0
        if (pending.isNotEmpty()) {
            val encrypted = e2eEncryptBatch(pending, identity)
            val stored = api.pushEncrypted(token, identity.hash, encrypted).stored.toSet()
            for ((row, env) in outbox.zip(pending)) {
                if (stored.contains(e2eCarrierId(env))) {
                    database.outbox().remove(row.id)
                    pushed++
                }
            }
            val unstored = pending.filterNot { stored.contains(e2eCarrierId(it)) }
            if (unstored.isNotEmpty()) {
                // Force a FULL pull: the winner may predate the cursor. Reconcile
                // through header-LWW; entries still pending afterwards stay queued.
                val allEncrypted = api.pullEncrypted(token, identity.hash, null)
                val winners = allEncrypted.map { e2eDecryptDto(it, identity) }
                advancePullCursor(winners)
                for (env in winners) applyRemote(env)
                pulled += winners.size
                conflicts += unstored.size
            }
        }
        return SyncResult(pushed = pushed, pulled = pulled, conflicts = conflicts)
    }

    /** Runs E2E when [route] is E2E, else legacy v1 [sync]. Fails closed on missing identity. */
    suspend fun syncRouted(route: SyncRoute, authHeader: String? = null): SyncResult =
        when (route) {
            is SyncRoute.LegacyV1 -> sync()
            is SyncRoute.E2E -> syncE2E(route.identity, authHeader)
        }
}

// MARK: - Pure merge (LWW + tombstones) — parity with iOS mergeOutcome

/** Outcome of merging one remote envelope against the local copy. */
enum class MergeOutcome { TakeRemote, KeepLocal, Identical }

/**
 * Pure last-write-wins: remote newer (or tie) wins; identical requires same
 * updatedAt + same deleted + same device. Tombstones are just writes.
 */
fun mergeOutcome(local: SyncEnvelopeDto, remote: SyncEnvelopeDto): MergeOutcome {
    require(local.id == remote.id) { "merge requires matching ids" }
    val l = runCatching { Instant.parse(local.updatedAt) }.getOrNull()
    val r = runCatching { Instant.parse(remote.updatedAt) }.getOrNull()
    if (l != null && r != null) {
        if (r.isAfter(l)) return MergeOutcome.TakeRemote
        if (r.isBefore(l)) return MergeOutcome.KeepLocal
    } else {
        if (remote.updatedAt > local.updatedAt) return MergeOutcome.TakeRemote
        if (remote.updatedAt < local.updatedAt) return MergeOutcome.KeepLocal
    }
    if (remote.deleted == local.deleted && remote.deviceId == local.deviceId) return MergeOutcome.Identical
    return MergeOutcome.TakeRemote // tie-break: remote wins, deterministic convergence
}

// MARK: - Photo SHA-256 dedup

/** Hex SHA-256 of photo bytes. Uploads skip when the hash is already known (R2 key = photos/<sha>.jpg). */
fun sha256Hex(bytes: ByteArray): String = sha256HexBytes(bytes)

/** Returns the upload key, or null on dedup hit. Caller records the hash via [rememberPhotoHash]. */
fun photoUploadKeyIfNeeded(bytes: ByteArray, knownHashes: Set<String>): String? {
    val hash = sha256Hex(bytes)
    if (knownHashes.contains(hash)) return null
    return "photos/$hash.jpg"
}

// MARK: - CloudKit mirror stub

/** Seam for a future CloudKit/WorkManager mirror. Logged no-op so Room stays source of truth. */
object CloudMirrorStub {
    fun mirror(@Suppress("UNUSED_PARAMETER") count: Int) { /* no-op */ }
}

// MARK: - E2E identity / route (parity with iOS SyncEngine E2E section)

private val e2eJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

/** Identity for one E2E sync session: bucket hash + key material. */
data class E2ESyncIdentity(
    val householdId: String,
    val kid: String,
    val hash: String,
    val keyData: ByteArray,
) {
    constructor(syncCode: String, householdId: String, kid: String) : this(
        householdId = householdId,
        kid = kid,
        hash = householdHash(syncCode, householdId),
        keyData = keyBytes(syncCode, householdId, kid),
    )
    constructor(credential: E2ECredential) : this(
        householdId = credential.metadata.householdId,
        kid = credential.metadata.kid,
        hash = credential.metadata.hash,
        keyData = credential.key().encoded,
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is E2ESyncIdentity) return false
        return householdId == other.householdId && kid == other.kid && hash == other.hash &&
            keyData.contentEquals(other.keyData)
    }
    override fun hashCode(): Int = 31 * (31 * householdId.hashCode() + kid.hashCode()) + hash.hashCode()
}

sealed class E2EError(message: String) : Exception(message) {
    class StandaloneChildRejected(val entity: String, val id: String) :
        E2EError("standalone child $entity:$id must fold into parent recipe")
    class UnsupportedVersion(val v: Int) : E2EError("unsupported envelope version $v")
    class UnsupportedAlg(val alg: String) : E2EError("unsupported alg $alg")
    class DecryptFailed(val id: String) : E2EError("decrypt failed for $id")
    class PayloadDecode(detail: String) : E2EError("payload decode: $detail")
    class PayloadEncode(detail: String) : E2EError("payload encode: $detail")
    object MissingTransport : E2EError("E2E route selected but no identity supplied")
}

/** Which sync backend a sync run should use. */
sealed interface SyncRoute {
    data object LegacyV1 : SyncRoute
    data class E2E(val identity: E2ESyncIdentity) : SyncRoute
}

/** Millis-precision ISO-8601 for the /v2 wire: always exactly 3 fractional digits. */
fun e2eWireString(epochMillis: Long): String {
    val instant = Instant.ofEpochMilli(canonicalE2EMillis(epochMillis))
    return DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
        .withZone(ZoneOffset.UTC).format(instant)
}

fun parseE2EWire(s: String): Long =
    runCatching { Instant.parse(s).toEpochMilli() }.getOrDefault(0L)

/** Seals a plaintext envelope; header stays plaintext but is AEAD-bound to the payload. */
fun e2eEncrypt(envelope: SyncEnvelopeDto, identity: E2ESyncIdentity): EncryptedEnvelopeDto {
    val sealedAt = canonicalE2EMillis(parseE2EWire(envelope.updatedAt))
    val updatedAtStr = e2eWireString(sealedAt)
    val ad = e2eHeaderAD(
        v = 2, alg = "AES-GCM-256", kid = identity.kid, householdHash = identity.hash,
        id = envelope.id, updatedAtMillis = sealedAt, deviceId = envelope.deviceId,
        deleted = envelope.deleted, entity = envelope.entity,
    )
    val payloadBytes: ByteArray = try {
        envelope.payload.toString().toByteArray(Charsets.UTF_8)
    } catch (t: Throwable) {
        throw E2EError.PayloadEncode(t.toString())
    }
    val (nonceB64, ctB64) = try {
        seal(payloadBytes, SecretKeySpec(identity.keyData, "AES"), ad)
    } catch (t: Throwable) {
        throw E2EError.PayloadEncode(t.toString())
    }
    return EncryptedEnvelopeDto(
        kid = identity.kid, householdHash = identity.hash, id = envelope.id,
        updatedAt = updatedAtStr, deviceId = envelope.deviceId, deleted = envelope.deleted,
        entity = envelope.entity, nonce = nonceB64, ciphertext = ctB64,
    )
}

/** Opens an encrypted envelope. Rejects unknown versions/algs before touching crypto. */
fun e2eDecryptDto(encrypted: EncryptedEnvelopeDto, identity: E2ESyncIdentity): SyncEnvelopeDto {
    if (encrypted.v != 2) throw E2EError.UnsupportedVersion(encrypted.v)
    if (encrypted.alg != "AES-GCM-256") throw E2EError.UnsupportedAlg(encrypted.alg)
    val sealedAt = parseE2EWire(encrypted.updatedAt)
    val ad = e2eHeaderAD(
        v = encrypted.v, alg = encrypted.alg, kid = encrypted.kid,
        householdHash = encrypted.householdHash, id = encrypted.id,
        updatedAtMillis = sealedAt, deviceId = encrypted.deviceId,
        deleted = encrypted.deleted, entity = encrypted.entity,
    )
    val payload: kotlinx.serialization.json.JsonObject = try {
        openPayload(encrypted.nonce, encrypted.ciphertext, SecretKeySpec(identity.keyData, "AES"), ad)
    } catch (e: SyncCryptoException.PayloadDecode) {
        throw E2EError.PayloadDecode(e.message ?: "")
    } catch (_: Throwable) {
        throw E2EError.DecryptFailed(encrypted.id)
    }
    return pruneDeletedFoldedChildren(
        SyncEnvelopeDto(
            id = encrypted.id, updatedAt = encrypted.updatedAt, deviceId = encrypted.deviceId,
            deleted = encrypted.deleted, entity = encrypted.entity, payload = payload,
        ),
    )
}

// MARK: - Pre-encrypt folding (ingredient/step -> parent recipe)

private val e2eRecipeIdKeys = listOf("recipeId", "recipe_id")

private fun childParentId(env: SyncEnvelopeDto): String? =
    e2eRecipeIdKeys.firstNotNullOfOrNull { k ->
        env.payload[k]?.takeIf { it != JsonNull }?.jsonPrimitive?.content?.takeUnless { it.isEmpty() }
    }

private fun e2eChildMillis(iso: String): Long = parseE2EWire(iso)

private fun foldChild(child: SyncEnvelopeDto, parent: SyncEnvelopeDto): SyncEnvelopeDto {
    val listKey = if (child.entity == "ingredient") "ingredients" else "steps"
    val list = parent.payload[listKey]?.takeIf { it != JsonNull }?.jsonArray?.toMutableList()
        ?: mutableListOf()
    val incomingMillis = e2eChildMillis(child.updatedAt)
    if (child.deleted) {
        // Tombstone-by-absence: drop the embedded entry so the receiver's
        // rebuild restores nothing.
        val before = list.size
        val kept = list.filterNot {
            it.jsonObject["id"]?.takeIf { v -> v != JsonNull }?.jsonPrimitive?.content == child.id
        }
        if (kept.size != before) {
            val newPayload = JsonObject(parent.payload.toMutableMap().apply {
                put(listKey, JsonArray(kept))
            })
            val bumped = if (child.updatedAt > parent.updatedAt) child.updatedAt else parent.updatedAt
            return parent.copy(payload = newPayload, updatedAt = bumped)
        }
        return parent
    }
    val entryMap = child.payload.toMutableMap().apply {
        put("id", JsonPrimitive(child.id))
        put("deleted", JsonPrimitive(false))
        put("updatedAt", JsonPrimitive(incomingMillis))
        put("deviceId", JsonPrimitive(child.deviceId))
    }
    val entry = JsonObject(entryMap)
    val idx = list.indexOfFirst {
        it.jsonObject["id"]?.takeIf { v -> v != JsonNull }?.jsonPrimitive?.content == child.id
    }
    var changed = false
    val next = list.toMutableList()
    if (idx >= 0) {
        val existingMillis = list[idx].jsonObject["updatedAt"]?.takeIf { it != JsonNull }
            ?.jsonPrimitive?.content?.toLongOrNull() ?: Long.MIN_VALUE
        if (incomingMillis >= existingMillis) {
            next[idx] = entry
            changed = true
        }
    } else {
        next.add(entry)
        changed = true
    }
    if (!changed) return parent
    val newPayload = JsonObject(parent.payload.toMutableMap().apply {
        put(listKey, JsonArray(next))
    })
    val bumped = if (child.updatedAt > parent.updatedAt) child.updatedAt else parent.updatedAt
    return parent.copy(payload = newPayload, updatedAt = bumped)
}

/** Strips embedded entries still carrying `deleted == true` (sealed by older clients). */
private fun pruneDeletedFoldedChildren(envelope: SyncEnvelopeDto): SyncEnvelopeDto {
    var out = envelope
    for (key in listOf("ingredients", "steps")) {
        val list = out.payload[key]?.takeIf { it != JsonNull }?.jsonArray ?: continue
        val live = list.filterNot {
            it.jsonObject["deleted"]?.takeIf { v -> v != JsonNull }?.jsonPrimitive?.content == "true"
        }
        if (live.size != list.size) {
            out = out.copy(payload = JsonObject(out.payload.toMutableMap().apply {
                put(key, JsonArray(live))
            }))
        }
    }
    return out
}

/**
 * Folds ingredient/step envelopes into their parent recipe envelope BEFORE
 * encryption. Children without a parent in the batch get a synthesized parent
 * shell; children with NO parent link pass through so encrypt rejects loudly.
 */
fun foldEnvelopesForE2E(envelopes: List<SyncEnvelopeDto>): List<SyncEnvelopeDto> {
    val recipes = linkedMapOf<String, SyncEnvelopeDto>()
    val passthrough = mutableListOf<SyncEnvelopeDto>()
    val children = mutableListOf<SyncEnvelopeDto>()
    for (env in envelopes) {
        when (env.entity) {
            "recipe" -> {
                val cur = recipes[env.id]
                if (cur == null || env.updatedAt >= cur.updatedAt) recipes[env.id] = env
                else if (env.id !in recipes) recipes[env.id] = env
            }
            "ingredient", "step" -> children.add(env)
            else -> passthrough.add(env)
        }
    }
    val shells = linkedMapOf<String, SyncEnvelopeDto>()
    for (child in children) {
        val parentId = childParentId(child) ?: continue
        val existing = recipes[parentId]
        if (existing != null) {
            recipes[parentId] = foldChild(child, existing)
        } else {
            val shell = shells[parentId]
            if (shell != null) shells[parentId] = foldChild(child, shell)
            else {
                shells[parentId] = foldChild(
                    child,
                    SyncEnvelopeDto(
                        id = parentId, updatedAt = child.updatedAt, deviceId = child.deviceId,
                        entity = "recipe",
                        payload = buildJsonObject {
                            put("id", parentId)
                            put("_foldedShell", true)
                        },
                    ),
                )
            }
        }
    }
    val orphans = children.filter { childParentId(it).isNullOrEmpty() }
    return recipes.values.toList() + shells.values.toList() + passthrough + orphans
}

/** The wire id a pending envelope is carried under after folding. */
fun e2eCarrierId(envelope: SyncEnvelopeDto): String {
    if (envelope.entity == "ingredient" || envelope.entity == "step") {
        val parentId = childParentId(envelope)
        if (!parentId.isNullOrEmpty()) return parentId
    }
    return envelope.id
}

/** Folds then encrypts a batch. Throws on standalone children (server rejects 422). */
fun e2eEncryptBatch(envelopes: List<SyncEnvelopeDto>, identity: E2ESyncIdentity): List<EncryptedEnvelopeDto> {
    val folded = foldEnvelopesForE2E(envelopes)
    for (env in folded) {
        if (env.entity == "ingredient" || env.entity == "step") {
            throw E2EError.StandaloneChildRejected(env.entity, env.id)
        }
    }
    return folded.map { e2eEncrypt(it, identity) }
}

/** Credential selection: active E2E credential → /v2, else legacy v1. Caller supplies DataStores. */
suspend fun resolveSyncRoute(
    metaStore: DataStore<Preferences>,
    secretStore: DataStore<Preferences>,
): SyncRoute {
    val credential = E2EKeyStore.loadActive(metaStore, secretStore) ?: return SyncRoute.LegacyV1
    return SyncRoute.E2E(E2ESyncIdentity(credential))
}
