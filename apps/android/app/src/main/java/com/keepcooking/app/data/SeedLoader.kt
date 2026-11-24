package com.keepcooking.app.data

import android.content.Context
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Loads bundled seed recipes from src/main/assets/seed/*.json into Room.
 * Parity with iOS SeedLoader: one-shot, idempotent, airplane-mode friendly.
 */
class SeedLoader(
    private val context: Context,
    private val db: AppDatabase,
    private val deviceId: String = "seed",
) {
    data class Result(val loaded: Int, val skipped: Int)

    private val json = Json { ignoreUnknownKeys = true }

    suspend fun seedIfNeeded(): Result {
        if (db.recipes().count() > 0) return Result(0, 0)
        var loaded = 0
        var skipped = 0
        val files = (context.assets.list("seed") ?: emptyArray()).sorted()
        for (file in files) {
            if (!file.endsWith(".json")) continue
            try {
                val text = context.assets.open("seed/$file").bufferedReader().use { it.readText() }
                if (insertSeed(text)) loaded++ else skipped++
            } catch (_: Exception) {
                skipped++
            }
        }
        return Result(loaded, skipped)
    }

    private suspend fun insertSeed(text: String): Boolean {
        val root = json.parseToJsonElement(text).jsonObject
        val id = root.string("id") ?: UUID.randomUUID().toString()
        if (db.recipes().byId(id) != null) return false
        val now = root.string("updatedAt")?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
            ?: System.currentTimeMillis()

        val recipe = RecipeEntity(
            id = id,
            householdId = root.string("householdId") ?: "hh-demo",
            title = root.string("title") ?: "Untitled",
            recipeDescription = root.string("description") ?: "",
            servings = root.double("servings") ?: 4.0,
            prepMinutes = root.int("prepMinutes"),
            cookMinutes = root.int("cookMinutes"),
            rating = root.double("rating"),
            source = root.string("source") ?: "",
            sourceUrl = root.string("sourceUrl") ?: "",
            categoriesJson = root["categories"]?.jsonArray.toStringListJson(),
            photoOriginal = root.jsonObject["photoKeys"]?.jsonObject?.string("original"),
            photoLarge1024 = root.jsonObject["photoKeys"]?.jsonObject?.string("large1024"),
            photoThumb = root.jsonObject["photoKeys"]?.jsonObject?.string("thumb"),
            updatedAt = now,
            deviceId = root.string("deviceId") ?: deviceId,
            deleted = root.bool("deleted") ?: false,
        )
        db.recipes().upsert(recipe)

        val ingredients = root["ingredients"]?.jsonArray.orEmpty().mapIndexed { i, el ->
            val o = el.jsonObject
            IngredientEntity(
                id = o.string("id") ?: UUID.randomUUID().toString(),
                recipeId = id,
                name = o.string("name") ?: "",
                quantity = o.double("quantity"),
                unit = o.string("unit") ?: "",
                display = o.string("display") ?: "",
                position = o.int("position") ?: i,
                updatedAt = now,
                deviceId = recipe.deviceId,
            )
        }
        db.ingredients().upsertAll(ingredients)

        val steps = root["steps"]?.jsonArray.orEmpty().mapIndexed { i, el ->
            val o = el.jsonObject
            StepEntity(
                id = o.string("id") ?: UUID.randomUUID().toString(),
                recipeId = id,
                position = o.int("position") ?: i,
                text = o.string("text") ?: "",
                timersJson = (o["timers"]?.jsonArray ?: JsonArray(emptyList())).toString(),
                updatedAt = now,
                deviceId = recipe.deviceId,
            )
        }
        db.steps().upsertAll(steps)
        return true
    }

    // --- small JSON helpers (never throw) ---
    private fun JsonObject.string(key: String): String? =
        this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.let {
            runCatching { it.content }.getOrNull()
        }

    private fun JsonObject.double(key: String): Double? =
        this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.doubleOrNull

    private fun JsonObject.int(key: String): Int? =
        this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.intOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.let {
            runCatching { it.content.toBooleanStrictOrNull() }.getOrNull()
        }

    private fun JsonArray?.toStringListJson(): String {
        val arr = this ?: return "[]"
        val names = arr.mapNotNull { runCatching { it.jsonPrimitive.content }.getOrNull() }
        return buildJsonObject { }.let {
            Json.encodeToString(
                kotlinx.serialization.builtins.ListSerializer(kotlinx.serialization.builtins.serializer<String>()),
                names,
            )
        }
    }
}

@Serializable
data class SeedPhotoKeys(
    val original: String = "",
    @SerialName("large1024") val large1024: String = "",
    val thumb: String = "",
)
