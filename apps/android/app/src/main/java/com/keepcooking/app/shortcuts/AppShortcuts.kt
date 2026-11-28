package com.keepcooking.app.shortcuts

import android.content.Context
import com.keepcooking.app.cook.CookActivityStub
import com.keepcooking.app.cook.CookSession
import com.keepcooking.app.cook.ParsedTimer
import com.keepcooking.app.data.AppDatabase
import com.keepcooking.app.data.IngredientEntity
import com.keepcooking.app.data.ListItemEntity
import com.keepcooking.app.data.OutboxRow
import com.keepcooking.app.data.RecipeEntity
import com.keepcooking.app.data.ShoppingListEntity
import com.keepcooking.app.data.StepEntity
import com.keepcooking.app.data.SyncEntityName
import com.keepcooking.app.network.SyncEnvelopeDto
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray

/**
 * App shortcuts + assistant actions — parity with iOS
 * Intents/KeepCookingIntents.swift (Add Recipe, Start Timer, Add to List,
 * Next/Prev step as handoff).
 *
 * Manifest wiring: res/xml/shortcuts.xml lists the five static shortcuts;
 * MainActivity handles their intent actions via [handleShortcutAction].
 *
 * Pending cook-command flow (handoff — the shortcut process has no access to
 * the live Cook session, same limitation as iOS):
 *   1. NEXT/PREV actions write "next"/"previous" via [writePendingCommand].
 *   2. The Cook screen, on open (and on resume), calls
 *      [consumePendingCookCommand] exactly once and applies the result via
 *      [applyPendingCookCommand]: "next"/"previous" move the [CookSession],
 *      "repeat" stays (the caller re-announces the current step), and
 *      "crossoff:<name>" is resolved against visible ingredients by the
 *      caller ([applyPendingCookCommand] returns false for it).
 *
 * Every Room write here also enqueues a sync envelope into the outbox (same
 * id format as SyncEngine.enqueue: "<entity>:<id>"), so shortcut-created
 * recipes/items sync on the next push instead of waiting for a later write.
 */
object AppShortcuts {
    const val ACTION_ADD_RECIPE = "com.keepcooking.app.ADD_RECIPE"
    const val ACTION_START_TIMER = "com.keepcooking.app.START_TIMER"
    const val ACTION_ADD_TO_LIST = "com.keepcooking.app.ADD_TO_LIST"
    const val ACTION_NEXT_STEP = "com.keepcooking.app.NEXT_STEP"
    const val ACTION_PREV_STEP = "com.keepcooking.app.PREV_STEP"

    const val EXTRA_TITLE = "title"
    const val EXTRA_INGREDIENTS = "ingredients"
    const val EXTRA_MINUTES = "minutes"
    const val EXTRA_LABEL = "label"
    const val EXTRA_ITEM = "item"
    const val EXTRA_QUANTITY = "quantity"

    const val PENDING_PREFS = "keepcooking_cook_handoff"
    const val PENDING_KEY = "cook.pendingCommand"

    fun writePendingCommand(context: Context, value: String) {
        context.getSharedPreferences(PENDING_PREFS, Context.MODE_PRIVATE)
            .edit().putString(PENDING_KEY, value).apply()
    }

    /** Consume + clear the pending cook command (Cook screen, on open). */
    fun consumePendingCommand(context: Context): String? {
        val prefs = context.getSharedPreferences(PENDING_PREFS, Context.MODE_PRIVATE)
        val value = prefs.getString(PENDING_KEY, null)
        if (value != null) prefs.edit().remove(PENDING_KEY).apply()
        return value
    }

    /**
     * Canonical consume entry point for the Cook screen (call on open / on
     * resume, exactly once per open). See the object KDoc for the full flow.
     */
    fun consumePendingCookCommand(context: Context): String? = consumePendingCommand(context)

    /**
     * Applies a consumed pending command to [session] for cook navigation.
     * "next"/"previous" move the session, "repeat" stays (caller re-announces
     * the current step). Returns false for "crossoff:<name>" (resolved against
     * visible ingredients by the caller) and unknown values.
     */
    fun applyPendingCookCommand(session: CookSession, command: String?): Boolean {
        when (command) {
            "next" -> session.next()
            "previous" -> session.previous()
            "repeat" -> Unit // stay: caller re-announces the current step
            else -> return false
        }
        return true
    }

    /**
     * Executes a shortcut action against Room and enqueues the matching sync
     * envelopes into the outbox, so sync picks them up on next push.
     * Returns a human-readable result for the assistant dialog / toast.
     * Unknown actions return null.
     */
    suspend fun handleShortcutAction(
        context: Context,
        db: AppDatabase,
        deviceId: String,
        action: String?,
        extras: Map<String, Any?> = emptyMap(),
    ): String? {
        val now = System.currentTimeMillis()
        return when (action) {
            ACTION_ADD_RECIPE -> {
                val title = (extras[EXTRA_TITLE] as? String)?.trim().orEmpty()
                if (title.isEmpty()) return "Give the recipe a title first."
                val recipe = RecipeEntity(
                    id = UUID.randomUUID().toString(), householdId = "hh-demo",
                    title = title, updatedAt = now, deviceId = deviceId,
                )
                db.recipes().upsert(recipe)
                val lines = (extras[EXTRA_INGREDIENTS] as? String).orEmpty()
                    .split("\n").map { it.trim() }.filter { it.isNotEmpty() }
                db.ingredients().upsertAll(lines.mapIndexed { i, line ->
                    IngredientEntity(
                        id = UUID.randomUUID().toString(), recipeId = recipe.id,
                        name = line, display = line, position = i,
                        updatedAt = now, deviceId = deviceId,
                    )
                })
                val ings = db.ingredients().forRecipe(recipe.id)
                enqueueEnvelope(db, recipeEnvelope(recipe, ings, emptyList(), deviceId))
                "Added $title to Keep Cooking."
            }
            ACTION_START_TIMER -> {
                val minutes = (extras[EXTRA_MINUTES] as? Int) ?: 0
                if (minutes <= 0 || minutes > 720) return "Keep timers between 1 minute and 12 hours."
                val label = (extras[EXTRA_LABEL] as? String)?.trim().orEmpty()
                    .ifEmpty { "$minutes-minute timer" }
                val seconds = minutes * 60
                val recipe = ensureShortcutTimersRecipe(db, deviceId, label, seconds, now)
                enqueueEnvelope(db, recipeEnvelope(recipe, db.ingredients().forRecipe(recipe.id), db.steps().forRecipe(recipe.id), deviceId))
                // Same timer path Cook uses: arms a real device alarm, so the
                // success message below honestly claims a live timer.
                CookActivityStub.schedule(context, listOf(ParsedTimer(seconds, label)))
                "Timer set for $minutes minutes: $label."
            }
            ACTION_ADD_TO_LIST -> {
                val name = (extras[EXTRA_ITEM] as? String)?.trim().orEmpty()
                if (name.isEmpty()) return "Tell me what to add to the list."
                val lists = db.shoppingLists().liveLists()
                val list = lists.firstOrNull() ?: ShoppingListEntity(
                    id = UUID.randomUUID().toString(), householdId = "hh-demo",
                    name = "Shopping", updatedAt = now, deviceId = deviceId,
                ).also { db.shoppingLists().upsertAll(listOf(it)) }
                db.listItems().upsertAll(listOf(
                    ListItemEntity(
                        id = UUID.randomUUID().toString(), listId = list.id, name = name,
                        quantity = (extras[EXTRA_QUANTITY] as? String)?.trim().orEmpty(),
                        updatedAt = now, deviceId = deviceId,
                    ),
                ))
                db.shoppingLists().upsertAll(listOf(list.copy(updatedAt = now)))
                val updated = list.copy(updatedAt = now)
                enqueueEnvelope(db, listEnvelope(updated, db.listItems().forList(list.id), deviceId))
                "Added $name to ${list.name}."
            }
            ACTION_NEXT_STEP -> {
                writePendingCommand(context, "next")
                "Opening Keep Cooking to go to the next step."
            }
            ACTION_PREV_STEP -> {
                writePendingCommand(context, "previous")
                "Opening Keep Cooking to go back a step."
            }
            else -> null
        }
    }

    private suspend fun ensureShortcutTimersRecipe(
        db: AppDatabase,
        deviceId: String,
        label: String,
        seconds: Int,
        now: Long,
    ): RecipeEntity {
        val existing = db.recipes().liveRecipes().firstOrNull { it.title == "Shortcut Timers" }
        val recipe = existing ?: RecipeEntity(
            id = UUID.randomUUID().toString(), householdId = "hh-demo",
            title = "Shortcut Timers", updatedAt = now, deviceId = deviceId,
        ).also { db.recipes().upsert(it) }
        val position = (db.steps().forRecipe(recipe.id).maxOfOrNull { it.position } ?: -1) + 1
        db.steps().upsertAll(listOf(
            StepEntity(
                id = UUID.randomUUID().toString(), recipeId = recipe.id,
                position = position, text = label,
                timersJson = """[{"seconds":$seconds,"label":${label.quote()}}]""",
                updatedAt = now, deviceId = deviceId,
            ),
        ))
        val updated = recipe.copy(updatedAt = now)
        db.recipes().upsert(updated)
        return updated
    }

    // --- Sync outbox (parity with SyncEngine.enqueue + iOS recipeEnvelope/listEnvelope) ---

    private val outboxJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

    /** Enqueues one envelope using the same "<entity>:<id>" row id as SyncEngine.enqueue. */
    private suspend fun enqueueEnvelope(db: AppDatabase, envelope: SyncEnvelopeDto) {
        db.outbox().enqueue(
            OutboxRow(
                id = "${envelope.entity}:${envelope.id}",
                entity = envelope.entity,
                envelopeJson = outboxJson.encodeToString(SyncEnvelopeDto.serializer(), envelope),
            ),
        )
    }

    /** Recipe envelope with embedded ingredients + steps (payload keys match iOS recipeEnvelope). */
    private fun recipeEnvelope(
        recipe: RecipeEntity,
        ingredients: List<IngredientEntity>,
        steps: List<StepEntity>,
        deviceId: String,
    ): SyncEnvelopeDto {
        val categories = runCatching { outboxJson.parseToJsonElement(recipe.categoriesJson).jsonArray }
            .getOrDefault(JsonArray(emptyList()))
        return SyncEnvelopeDto(
            id = recipe.id,
            updatedAt = Instant.ofEpochMilli(recipe.updatedAt).toString(),
            deviceId = deviceId,
            deleted = false,
            entity = SyncEntityName.RECIPE.raw,
            payload = buildJsonObject {
                put("householdId", JsonPrimitive(recipe.householdId))
                put("title", JsonPrimitive(recipe.title))
                put("description", JsonPrimitive(recipe.recipeDescription))
                put("servings", JsonPrimitive(recipe.servings))
                put("isFavorite", JsonPrimitive(recipe.isFavorite))
                put("source", JsonPrimitive(recipe.source))
                put("sourceUrl", JsonPrimitive(recipe.sourceUrl))
                put("categories", categories)
                put("photoKeys", buildJsonObject {
                    put("original", JsonPrimitive(recipe.photoOriginal ?: ""))
                    put("large1024", JsonPrimitive(recipe.photoLarge1024 ?: ""))
                    put("thumb", JsonPrimitive(recipe.photoThumb ?: ""))
                })
                if (recipe.prepMinutes != null) if (recipe.prepMinutes != null) put("prepMinutes", JsonPrimitive(recipe.prepMinutes))
                if (recipe.cookMinutes != null) if (recipe.cookMinutes != null) put("cookMinutes", JsonPrimitive(recipe.cookMinutes))
                if (recipe.rating != null) if (recipe.rating != null) put("rating", JsonPrimitive(recipe.rating))
                put("nutritionText", JsonPrimitive(recipe.nutritionText))
                put("ingredients", JsonArray(ingredients.map { ing ->
                    buildJsonObject {
                        put("id", JsonPrimitive(ing.id))
                        put("name", JsonPrimitive(ing.name))
                        if (ing.quantity != null) if (ing.quantity != null) put("quantity", JsonPrimitive(ing.quantity))
                        put("unit", JsonPrimitive(ing.unit))
                        put("display", JsonPrimitive(ing.display))
                        put("position", JsonPrimitive(ing.position))
                        put("recipeId", JsonPrimitive(recipe.id))
                    }
                }))
                put("steps", JsonArray(steps.map { st ->
                    buildJsonObject {
                        put("id", JsonPrimitive(st.id))
                        put("position", JsonPrimitive(st.position))
                        put("text", JsonPrimitive(st.text))
                        val timers = runCatching { outboxJson.parseToJsonElement(st.timersJson).jsonArray }
                            .getOrDefault(JsonArray(emptyList()))
                        put("timers", timers)
                        put("recipeId", JsonPrimitive(recipe.id))
                    }
                }))
            },
        )
    }

    /** List envelope with embedded items (payload keys match iOS listEnvelope). */
    private fun listEnvelope(
        list: ShoppingListEntity,
        items: List<ListItemEntity>,
        deviceId: String,
    ): SyncEnvelopeDto = SyncEnvelopeDto(
        id = list.id,
        updatedAt = Instant.ofEpochMilli(list.updatedAt).toString(),
        deviceId = deviceId,
        deleted = false,
        entity = SyncEntityName.LIST.raw,
        payload = buildJsonObject {
            put("householdId", JsonPrimitive(list.householdId))
            put("name", JsonPrimitive(list.name))
            put("items", JsonArray(items.filterNot { it.deleted }.map { item ->
                buildJsonObject {
                    put("id", JsonPrimitive(item.id))
                    put("name", JsonPrimitive(item.name))
                    put("quantity", JsonPrimitive(item.quantity))
                    put("aisle", JsonPrimitive(item.aisle))
                    put("checked", JsonPrimitive(item.checked))
                    if (item.recipeId != null) put("recipeId", JsonPrimitive(item.recipeId))
                }
            }))
        },
    )

    private fun String.quote(): String =
        "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
