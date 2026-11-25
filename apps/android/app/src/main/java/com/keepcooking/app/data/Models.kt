package com.keepcooking.app.data

import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable

/**
 * Room entities 1:1 with packages/contracts/schema.sql (v0.1.0),
 * ported from apps/ios/Core/Models.swift.
 *
 * Sync contract (all top-level entities):
 *   id TEXT PK (uuid) · updatedAt ISO8601 · deviceId TEXT · deleted 0/1 tombstone
 *   Last-write-wins on updatedAt. Deleted tombstones win like any other write.
 *   Child rows (Ingredient / Step / ListItem) version through their parent
 *   envelope but also carry sync fields so they can merge standalone.
 */

enum class SyncEntityName(val raw: String) {
    RECIPE("recipe"),
    INGREDIENT("ingredient"),
    STEP("step"),
    LIST("list"),
    PANTRY_ITEM("pantryItem"),
    PLAN("plan"),
    MENU("menu"),
}

enum class MealSlot(val raw: String) {
    BREAKFAST("breakfast"),
    LUNCH("lunch"),
    DINNER("dinner"),
    SNACK("snack"),
    ;

    companion object {
        fun fromRaw(raw: String?): MealSlot = entries.firstOrNull { it.raw == raw } ?: DINNER
    }
}

/** Pure last-write-wins: later updatedAt wins; ties break toward remote. */
fun resolveSyncWinner(localUpdatedAt: Long, remoteUpdatedAt: Long): Boolean =
    remoteUpdatedAt >= localUpdatedAt // true = take remote

@Serializable
data class StepTimer(val seconds: Int, val label: String = "")

@Serializable
data class MenuEntry(
    val dayOffset: Int,
    val meal: String,
    val recipeId: String,
    val servings: Double,
)

interface Syncable {
    val syncId: String
    val syncUpdatedAt: Long // epoch millis; ISO8601 on the wire
    val syncDeviceId: String
    val syncDeleted: Boolean
    val syncEntity: SyncEntityName
}

@Entity(tableName = "recipes")
data class RecipeEntity(
    @PrimaryKey val id: String,
    val householdId: String,
    val title: String,
    val recipeDescription: String = "",
    val servings: Double = 4.0,
    val prepMinutes: Int? = null,
    val cookMinutes: Int? = null,
    val rating: Double? = null,
    val source: String = "",
    val sourceUrl: String = "",
    val categoriesJson: String = "[]", // [String] encoded
    val photoOriginal: String? = null,
    val photoLarge1024: String? = null,
    val photoThumb: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) : Syncable {
    override val syncId get() = id
    override val syncUpdatedAt get() = updatedAt
    override val syncDeviceId get() = deviceId
    override val syncDeleted get() = deleted
    override val syncEntity get() = SyncEntityName.RECIPE
}

@Entity(tableName = "ingredients")
data class IngredientEntity(
    @PrimaryKey val id: String,
    val recipeId: String,
    val name: String,
    val quantity: Double? = null,
    val unit: String = "",
    val display: String = "",
    val position: Int = 0,
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) : Syncable {
    override val syncId get() = id
    override val syncUpdatedAt get() = updatedAt
    override val syncDeviceId get() = deviceId
    override val syncDeleted get() = deleted
    override val syncEntity get() = SyncEntityName.INGREDIENT
}

@Entity(tableName = "steps")
data class StepEntity(
    @PrimaryKey val id: String,
    val recipeId: String,
    val position: Int = 0,
    val text: String = "",
    val timersJson: String = "[]", // [StepTimer] encoded
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) : Syncable {
    override val syncId get() = id
    override val syncUpdatedAt get() = updatedAt
    override val syncDeviceId get() = deviceId
    override val syncDeleted get() = deleted
    override val syncEntity get() = SyncEntityName.STEP
}

@Entity(tableName = "shopping_lists")
data class ShoppingListEntity(
    @PrimaryKey val id: String,
    val householdId: String,
    val name: String,
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) : Syncable {
    override val syncId get() = id
    override val syncUpdatedAt get() = updatedAt
    override val syncDeviceId get() = deviceId
    override val syncDeleted get() = deleted
    override val syncEntity get() = SyncEntityName.LIST
}

@Entity(tableName = "list_items")
data class ListItemEntity(
    @PrimaryKey val id: String,
    val listId: String,
    val name: String,
    val quantity: String = "",
    val aisle: String = "",
    val checked: Boolean = false,
    val recipeId: String? = null,
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) : Syncable {
    override val syncId get() = id
    override val syncUpdatedAt get() = updatedAt
    override val syncDeviceId get() = deviceId
    override val syncDeleted get() = deleted
    override val syncEntity get() = SyncEntityName.LIST
}

@Entity(tableName = "pantry_items")
data class PantryItemEntity(
    @PrimaryKey val id: String,
    val householdId: String,
    val name: String,
    val quantity: String = "",
    val location: String = "",
    val expiresAt: Long? = null, // epoch millis; server TEXT 'YYYY-MM-DD' UTC
    val lowThreshold: String = "",
    val barcode: String = "",
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) : Syncable {
    override val syncId get() = id
    override val syncUpdatedAt get() = updatedAt
    override val syncDeviceId get() = deviceId
    override val syncDeleted get() = deleted
    override val syncEntity get() = SyncEntityName.PANTRY_ITEM
}

@Entity(tableName = "plans")
data class PlanEntity(
    @PrimaryKey val id: String,
    val householdId: String,
    val date: Long = 0L, // day precision, UTC midnight epoch millis
    val mealRaw: String = MealSlot.DINNER.raw,
    val recipeId: String? = null,
    val note: String = "",
    val servings: Double? = null,
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) : Syncable {
    override val syncId get() = id
    override val syncUpdatedAt get() = updatedAt
    override val syncDeviceId get() = deviceId
    override val syncDeleted get() = deleted
    override val syncEntity get() = SyncEntityName.PLAN

    val meal: MealSlot get() = MealSlot.fromRaw(mealRaw)
}

@Entity(tableName = "menus")
data class MenuEntity(
    @PrimaryKey val id: String,
    val householdId: String,
    val name: String,
    val entriesJson: String = "[]", // [MenuEntry] encoded
    val updatedAt: Long = System.currentTimeMillis(),
    val deviceId: String = "",
    val deleted: Boolean = false,
) : Syncable {
    override val syncId get() = id
    override val syncUpdatedAt get() = updatedAt
    override val syncDeviceId get() = deviceId
    override val syncDeleted get() = deleted
    override val syncEntity get() = SyncEntityName.MENU
}

/** Outbox row for pending pushes — drains through SyncEngine. */
@Entity(tableName = "sync_outbox")
data class OutboxRow(
    @PrimaryKey val id: String, // envelope id + entity, e.g. "recipe:abc"
    val entity: String,
    val envelopeJson: String,
    val enqueuedAt: Long = System.currentTimeMillis(),
)
