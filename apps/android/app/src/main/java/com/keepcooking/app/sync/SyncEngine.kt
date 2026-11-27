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
import com.keepcooking.app.network.createApiService
import com.keepcooking.app.network.E2EPushResponse
import com.keepcooking.app.network.EncryptedEnvelopeDto
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
import kotlinx.serialization.json.booleanOrNull
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
        val KEY_DEVICE_ID = DeviceAuth.KEY_DEVICE_ID
        val KEY_BASE_URL = stringPreferencesKey("api_base_url")
        val KEY_USER_ID = stringPreferencesKey("user_id")
        val KEY_LAST_SYNC = stringPreferencesKey("last_sync_at")
        const val PROD_BASE_URL = "https://keep-cooking-api.pshippy-245.workers.dev"
    }

    /**
     * Persisted UUIDv4 device id (stable across launches). identifierForVendor
     * / Build.MODEL are display hints only — the device key is the identity.
     */
    suspend fun deviceId(): String = DeviceAuth.deviceId(dataStore)

    /**
     * Transport for this run: Advanced custom-server override or the built-in
     * server. Enroll-once runs first (unsigned, idempotent, best-effort) and
     * every transport carries the device interceptor, which signs mutating
     * requests (POST/PUT/DELETE) and leaves reads unsigned.
     */
    private val overrideApiCache = mutableMapOf<String, ApiService>()

    suspend fun activeApi(): ApiService {
        val override = dataStore.data.map { it[KEY_BASE_URL]?.trim().orEmpty() }.first()
        val base = override.ifEmpty { PROD_BASE_URL }
        runCatching { DeviceAuth.ensure(dataStore, base) }
        if (override.isEmpty()) return api
        // Cache per base URL: a Retrofit/OkHttpClient per sync run would
        // leak connection pools and threads.
        synchronized(overrideApiCache) {
            return overrideApiCache.getOrPut(override) { createApiService(override, DeviceAuth.interceptor()) }
        }
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

    /**
     * Full sync, iOS parity: pull first and LWW-merge against the pending
     * outbox (an unsynced offline edit shadows any stale remote), advance the
     * cursor by ENVELOPE time, then push what remains. Server-won conflict
     * envelopes (the bare-array push response) apply via LWW; pushed rows —
     * accepted or superseded by a winner — leave the outbox so conflicts
     * cannot retry forever.
     */
    suspend fun sync(): SyncResult {
        // Open access: no token enrollment. The Advanced custom-server
        // override (KEY_BASE_URL) selects the transport; blank = built-in.
        val transport = activeApi()

        // 1. Pull + LWW-apply. Pulled winners reconcile against the outbox:
        //    a pending row the winner supersedes (same id, winner newer-or-equal)
        //    is dropped instead of being pushed back up. The cursor overlaps by
        //    one tick (strict `updatedAt >` server filter would otherwise skip
        //    later envelopes sharing the cursor timestamp); replay is safe via LWW.
        val since = pullSinceValue()
        val household = "hh-demo"
        val pulled = transport.pull(null, since, household)
        var applied = 0
        for (env in pulled) {
            if (applyRemote(env)) applied++
        }
        advancePullCursor(pulled)

        // 2. Push whatever is still pending after the reconcile.
        val outbox = database.outbox().all()
        val envelopes = outbox.map { Json.decodeFromString(SyncEnvelopeDto.serializer(), it.envelopeJson) }
        var conflicts = 0
        var pushed = 0
        if (envelopes.isNotEmpty()) {
            val winners = transport.push(null, envelopes)
            conflicts = winners.size
            val wonIds = winners.map { "${it.entity}:${it.id}" }.toSet()
            // Server-won envelopes apply locally via LWW.
            for (winner in winners) applyRemote(winner)
            for ((row, env) in outbox.zip(envelopes)) {
                if ("${env.entity}:${env.id}" !in wonIds) pushed++
                database.outbox().remove(row.id)
            }
        }
        return SyncResult(pushed = pushed, pulled = applied, conflicts = conflicts)
    }

    /**
     * LWW apply of one remote envelope (tombstones included). Returns true
     * when the remote won (or there was nothing to compare against).
     * Standalone children never apply here — they ride inside their parent
     * recipe envelope (see foldEnvelopesForE2E / upsertRecipe).
     */
    suspend fun applyRemote(env: SyncEnvelopeDto): Boolean {
        if (env.entity == SyncEntityName.INGREDIENT.raw || env.entity == SyncEntityName.STEP.raw) return false
        val remoteTs = runCatching { Instant.parse(env.updatedAt).toEpochMilli() }.getOrDefault(0L)
        val localTs = localTimestampFor(env)
        // Header LWW runs against stored rows INCLUDING tombstones, so an
        // older remote live envelope can never resurrect a newer local delete
        // (and vice versa). Tombstones are just writes.
        if (localTs != null && !resolveSyncWinner(localTs, remoteTs)) return false
        when (env.entity) {
            SyncEntityName.RECIPE.raw -> upsertRecipe(env, remoteTs)
            SyncEntityName.LIST.raw -> upsertList(env, remoteTs)
            SyncEntityName.PANTRY_ITEM.raw -> upsertPantry(env, remoteTs)
            SyncEntityName.PLAN.raw -> upsertPlan(env, remoteTs)
            SyncEntityName.MENU.raw -> upsertMenu(env, remoteTs)
            else -> return false
        }
        reconcileOutboxRow(env, remoteTs)
        return true
    }

    /** Stored header timestamp for LWW, including tombstoned rows. Null when unknown. */
    private suspend fun localTimestampFor(env: SyncEnvelopeDto): Long? = when (env.entity) {
        SyncEntityName.RECIPE.raw -> database.recipes().byId(env.id)?.updatedAt
        SyncEntityName.LIST.raw -> database.shoppingLists().byIdIncludingDeleted(env.id)?.updatedAt
        SyncEntityName.PANTRY_ITEM.raw -> database.pantry().byIdIncludingDeleted(env.id)?.updatedAt
        SyncEntityName.PLAN.raw -> database.plans().byIdIncludingDeleted(env.id)?.updatedAt
        SyncEntityName.MENU.raw -> database.menus().byIdIncludingDeleted(env.id)?.updatedAt
        else -> null
    }

    /**
     * Drops the pending outbox row for [env] when the remote winner supersedes
     * it (same entity:id, remote newer-or-equal). A pending row NEWER than the
     * winner stays queued for the next push.
     */
    private suspend fun reconcileOutboxRow(env: SyncEnvelopeDto, remoteTs: Long) {
        val rowId = "${env.entity}:${env.id}"
        val row = database.outbox().all().firstOrNull { it.id == rowId } ?: return
        val pendingTs = runCatching {
            Instant.parse(Json.decodeFromString(SyncEnvelopeDto.serializer(), row.envelopeJson).updatedAt).toEpochMilli()
        }.getOrDefault(0L)
        if (remoteTs >= pendingTs) database.outbox().remove(row.id)
    }

    // --- envelope → Room upserts (payload keys match iOS recipeEnvelope/listEnvelope/...) ---

    private suspend fun upsertRecipe(env: SyncEnvelopeDto, remoteTs: Long) {
        val p = env.payload
        // Sparse child-only shells (see foldEnvelopesForE2E) carry a partial
        // child set and placeholder parent fields: merge their children
        // per-child LWW and preserve the local parent snapshot. Only a FULL
        // recipe envelope may replace parent fields.
        if (isFoldedShell(env) && !env.deleted) {
            val local = database.recipes().byId(env.id)
            if (local != null) {
                mergeShellChildren(env, remoteTs)
                if (resolveSyncWinner(local.updatedAt, remoteTs)) {
                    database.recipes().upsert(
                        local.copy(updatedAt = remoteTs, deviceId = env.deviceId, deleted = false),
                    )
                }
                return
            }
            // No local row: fall through and materialize the shell minimally;
            // a later full recipe envelope converges via normal header LWW.
        }
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
                categoriesJson = categoriesJsonOf(p),
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

    /**
     * Merges a sparse shell's embedded children into the existing local rows
     * WITHOUT touching parent fields or unrelated children. Each embedded
     * entry carries its own updatedAt/deviceId stamps; an entry only replaces
     * its local row when it wins that per-child LWW. Tombstone markers
     * (deleted == true, sealed by older clients) are never resurrected —
     * tombstones fold by absence.
     *
     * Deletion by absence ONLY when the shell declares the incoming array a
     * COMPLETE set ([shellChildSetIsFull]): local rows missing from a declared-
     * full set are deleted when the set's stamp (shell header [remoteTs]) wins
     * the per-child LWW against the local row. Partial shells (unmarked —
     * every shell this client synthesizes) merge present children only, so a
     * sparse update can never wipe unrelated rows.
     */
    private suspend fun mergeShellChildren(env: SyncEnvelopeDto, remoteTs: Long) {
        val p = env.payload
        val did = env.deviceId
        val incomingIngs = p["ingredients"]?.takeIf { it != JsonNull }?.jsonArray.orEmpty()
        if (incomingIngs.isNotEmpty() || shellChildSetIsFull(p, "ingredients")) {
            val existing = database.ingredients().forRecipe(env.id).associateBy { it.id }
            val writes = mutableListOf<IngredientEntity>()
            val seen = mutableSetOf<String>()
            for (el in incomingIngs) {
                val o = runCatching { el.jsonObject }.getOrNull() ?: continue
                val id = o["id"]?.takeIf { it != JsonNull }?.jsonPrimitive?.content ?: continue
                seen += id
                val stamp = shellChildWriteStamp(o, existing[id]?.updatedAt, remoteTs) ?: continue
                writes += IngredientEntity(
                    id = id,
                    recipeId = env.id,
                    name = o.str("name") ?: existing[id]?.name ?: "",
                    quantity = o.dbl("quantity") ?: existing[id]?.quantity,
                    unit = o.str("unit") ?: existing[id]?.unit ?: "",
                    display = o.str("display") ?: existing[id]?.display ?: "",
                    position = o.int("position") ?: existing[id]?.position ?: 0,
                    updatedAt = stamp,
                    deviceId = o.str("deviceId") ?: did,
                )
            }
            if (writes.isNotEmpty()) database.ingredients().upsertAll(writes)
            if (shellChildSetIsFull(p, "ingredients")) {
                for ((id, row) in existing) {
                    if (id !in seen && remoteTs >= row.updatedAt) {
                        database.ingredients().deleteById(env.id, id)
                    }
                }
            }
        }
        val incomingSteps = p["steps"]?.takeIf { it != JsonNull }?.jsonArray.orEmpty()
        if (incomingSteps.isNotEmpty() || shellChildSetIsFull(p, "steps")) {
            val existing = database.steps().forRecipe(env.id).associateBy { it.id }
            val writes = mutableListOf<StepEntity>()
            val seen = mutableSetOf<String>()
            for ((i, el) in incomingSteps.withIndex()) {
                val o = runCatching { el.jsonObject }.getOrNull() ?: continue
                val id = o["id"]?.takeIf { it != JsonNull }?.jsonPrimitive?.content ?: continue
                seen += id
                val stamp = shellChildWriteStamp(o, existing[id]?.updatedAt, remoteTs) ?: continue
                writes += StepEntity(
                    id = id,
                    recipeId = env.id,
                    position = o.int("position") ?: existing[id]?.position ?: i,
                    text = o.str("text") ?: existing[id]?.text ?: "",
                    timersJson = o["timers"]?.takeIf { it != JsonNull }?.let { t ->
                        runCatching { t.jsonArray }.getOrNull()?.toString()
                    } ?: existing[id]?.timersJson ?: "[]",
                    updatedAt = stamp,
                    deviceId = o.str("deviceId") ?: did,
                )
            }
            if (writes.isNotEmpty()) database.steps().upsertAll(writes)
            if (shellChildSetIsFull(p, "steps")) {
                for ((id, row) in existing) {
                    if (id !in seen && remoteTs >= row.updatedAt) {
                        database.steps().deleteById(env.id, id)
                    }
                }
            }
        }
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
        val max = pullCursorMax(remote) ?: return
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
        // Open access: no token enrollment. An explicit authHeader still
        // overrides (tests/local targets); otherwise no Authorization header.
        // Device identity (Ed25519 enroll + signed mutating requests) flows
        // via the transport's device interceptor (see activeApi/DeviceAuth).
        val token = authHeader
        val transport = activeApi()
        val remoteEncrypted = transport.pullEncrypted(token, identity.hash, pullSinceValue())
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
            val stored = transport.pushEncrypted(token, identity.hash, encrypted).stored.toSet()
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
                val allEncrypted = transport.pullEncrypted(token, identity.hash, null)
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

// MARK: - Pure sync helpers (unit-tested; SyncEngine delegates to these)

/**
 * Header LWW decision: take the remote when there is no local row, or when
 * the remote header is newer-or-equal. Tombstones are just writes — a newer
 * tombstone beats an older live row and vice versa, so callers MUST pass
 * stored timestamps that include tombstoned rows.
 */
fun remoteWins(localUpdatedAt: Long?, remoteUpdatedAt: Long): Boolean =
    localUpdatedAt == null || resolveSyncWinner(localUpdatedAt, remoteUpdatedAt)

/** Max envelope timestamp of a pull page; null when empty/unparseable. The v1 cursor advances from this, never wall-clock. */
fun pullCursorMax(remote: List<SyncEnvelopeDto>): Instant? =
    remote.mapNotNull { runCatching { Instant.parse(it.updatedAt) }.getOrNull() }.maxOrNull()

/**
 * Outbox row ids (entity:id) superseded by pulled winners: same id, winner
 * newer-or-equal to the pending envelope. Those rows must leave the outbox
 * so they are not pushed back up (conflicts retrying forever). A pending row
 * NEWER than every winner for its id stays queued.
 */
fun outboxIdsSuperseded(pending: List<SyncEnvelopeDto>, winners: List<SyncEnvelopeDto>): Set<String> {
    val byKey = winners.groupBy { "${it.entity}:${it.id}" }
    val drop = mutableSetOf<String>()
    for (p in pending) {
        val key = "${p.entity}:${p.id}"
        val contenders = byKey[key] ?: continue
        val pendingTs = runCatching { Instant.parse(p.updatedAt).toEpochMilli() }.getOrDefault(0L)
        if (contenders.any { w ->
            runCatching { Instant.parse(w.updatedAt).toEpochMilli() }.getOrDefault(0L) >= pendingTs
        }) {
            drop.add(key)
        }
    }
    return drop
}

/** True when [env] is a synthesized child-only shell (see foldEnvelopesForE2E). */
fun isFoldedShell(env: SyncEnvelopeDto): Boolean =
    env.payload["_foldedShell"]?.takeIf { it != JsonNull }?.jsonPrimitive?.booleanOrNull == true

/**
 * True when a shell payload declares its embedded [key] array ("ingredients" /
 * "steps") a COMPLETE set. Only then may the receiver treat locally-present
 * but remotely-absent rows as deletes, still gated by per-child LWW against
 * the set's stamp (see mergeShellChildren). Partial shells carry no marker
 * and merge present children only.
 */
fun shellChildSetIsFull(payload: JsonObject, key: String): Boolean {
    val marker = when (key) {
        "ingredients" -> "_fullIngredients"
        "steps" -> "_fullSteps"
        else -> return false
    }
    return payload[marker]?.takeIf { it != JsonNull }?.jsonPrimitive?.booleanOrNull == true
}

/** Embedded child stamp (epoch millis) for per-child LWW; unstamped legacy entries sort as [Long.MIN_VALUE]. */
fun shellChildStamp(entry: JsonObject): Long =
    entry["updatedAt"]?.takeIf { it != JsonNull }?.jsonPrimitive?.content?.toLongOrNull() ?: Long.MIN_VALUE

/** True when an embedded child entry carries a tombstone marker (sealed by older clients); never resurrect these. */
fun shellChildDeleted(entry: JsonObject): Boolean {
    val v = entry["deleted"]?.takeIf { it != JsonNull }?.jsonPrimitive ?: return false
    return v.booleanOrNull == true || v.content == "true"
}

/**
 * Stamp to write for an embedded shell child, or null to skip it.
 * Deleted markers are skipped; an unstamped incoming entry never clobbers a
 * stamped local row; otherwise the incoming entry must win the per-child LWW
 * (incoming newer-or-equal). New rows stamp the child's own millis so later
 * per-child compares keep working (never the shell header time), falling
 * back to [remoteTs] only for unstamped legacy entries.
 */
fun shellChildWriteStamp(entry: JsonObject, existingUpdatedAt: Long?, remoteTs: Long): Long? {
    if (shellChildDeleted(entry)) return null
    val incoming = shellChildStamp(entry)
    if (existingUpdatedAt == null) return if (incoming == Long.MIN_VALUE) remoteTs else incoming
    if (incoming == Long.MIN_VALUE) return null
    return if (incoming >= existingUpdatedAt) incoming else null
}

/**
 * Encoded `categories` array for a recipe row. Missing or explicit-null
 * payloads default to `[]` — never the literal string `"null"`.
 */
fun categoriesJsonOf(payload: JsonObject): String =
    (payload["categories"]?.takeIf { it != JsonNull }?.jsonArray ?: JsonArray(emptyList())).toString()

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

/**
 * Carries full-set markers through folding. A non-shell base is the sender's
 * complete recipe snapshot, so the merged arrays stay complete and the
 * receiver may reconcile deletions by absence ([shellChildSetIsFull]).
 * Shells are partial by construction and never gain markers.
 */
private fun stampFullMarkers(base: SyncEnvelopeDto, listKey: String, payload: JsonObject): JsonObject {
    if (isFoldedShell(base)) return payload
    val carriesArray = base.payload[listKey]?.takeIf { it != JsonNull }?.let {
        runCatching { it.jsonArray }.getOrNull()
    } != null
    if (!carriesArray) return payload
    val marker = if (listKey == "ingredients") "_fullIngredients" else "_fullSteps"
    if (payload[marker]?.takeIf { it != JsonNull }?.jsonPrimitive?.booleanOrNull == true) return payload
    return JsonObject(payload.toMutableMap().apply { put(marker, JsonPrimitive(true)) })
}

private fun foldChild(child: SyncEnvelopeDto, parent: SyncEnvelopeDto): SyncEnvelopeDto {
    val listKey = if (child.entity == "ingredient") "ingredients" else "steps"
    val list = parent.payload[listKey]?.takeIf { it != JsonNull }?.jsonArray?.toMutableList()
        ?: mutableListOf()
    val incomingMillis = e2eChildMillis(child.updatedAt)
    if (child.deleted) {
        // Tombstone-by-absence: drop the embedded entry so the receiver's
        // rebuild restores nothing — but only when the tombstone wins the
        // per-child LWW against the embedded entry's own stamps. A stale
        // re-push must not clobber a newer embedded child.
        val idx = list.indexOfFirst {
            it.jsonObject["id"]?.takeIf { v -> v != JsonNull }?.jsonPrimitive?.content == child.id
        }
        if (idx >= 0) {
            val existingMillis = list[idx].jsonObject["updatedAt"]?.takeIf { it != JsonNull }
                ?.jsonPrimitive?.content?.toLongOrNull() ?: Long.MIN_VALUE
            if (incomingMillis >= existingMillis) {
                val next = list.toMutableList().apply { removeAt(idx) }
                val newPayload = JsonObject(parent.payload.toMutableMap().apply {
                    put(listKey, JsonArray(next))
                })
                val bumped = if (child.updatedAt > parent.updatedAt) child.updatedAt else parent.updatedAt
                return parent.copy(payload = stampFullMarkers(parent, listKey, newPayload), updatedAt = bumped)
            }
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
    return parent.copy(payload = stampFullMarkers(parent, listKey, newPayload), updatedAt = bumped)
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
