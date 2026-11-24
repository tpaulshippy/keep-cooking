package com.keepcooking.app.shortcuts

import android.content.Context
import com.keepcooking.app.data.AppDatabase
import com.keepcooking.app.data.IngredientEntity
import com.keepcooking.app.data.ListItemEntity
import com.keepcooking.app.data.RecipeEntity
import com.keepcooking.app.data.ShoppingListEntity
import com.keepcooking.app.data.StepEntity
import java.util.UUID

/**
 * App shortcuts + assistant actions — parity with iOS
 * Intents/KeepCookingIntents.swift (Add Recipe, Start Timer, Add to List,
 * Next/Prev step as handoff).
 *
 * Manifest wiring: res/xml/shortcuts.xml lists the five static shortcuts;
 * MainActivity handles their intent actions via [handleShortcutAction].
 * Cook-nav intents are handoff-based (same limitation as iOS: the shortcut
 * process has no access to the live Cook session), so Next/Previous/Repeat
 * write `cook.pendingCommand` ("next" / "previous" / "repeat" /
 * "crossoff:<name>") for the Cook screen to consume + clear on open.
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
     * Executes a shortcut action against Room (offline; sync picks it up via
     * the outbox on next launch/refresh). Returns a human-readable result for
     * the assistant dialog / toast. Unknown actions return null.
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
                "Added $title to Keep Cooking."
            }
            ACTION_START_TIMER -> {
                val minutes = (extras[EXTRA_MINUTES] as? Int) ?: 0
                if (minutes <= 0 || minutes > 720) return "Keep timers between 1 minute and 12 hours."
                val label = (extras[EXTRA_LABEL] as? String)?.trim().orEmpty()
                    .ifEmpty { "$minutes-minute timer" }
                ensureShortcutTimersRecipe(db, deviceId, label, minutes * 60, now)
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
    ) {
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
        db.recipes().upsert(recipe.copy(updatedAt = now))
    }

    private fun String.quote(): String =
        "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
