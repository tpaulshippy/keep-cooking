package com.keepcooking.app.data

import androidx.room.Database
import androidx.room.RoomDatabase

/** Offline-first store. Local Room is the source of truth (mirrors iOS SwiftData container). */
@Database(
    entities = [
        RecipeEntity::class,
        IngredientEntity::class,
        StepEntity::class,
        ShoppingListEntity::class,
        ListItemEntity::class,
        PantryItemEntity::class,
        PlanEntity::class,
        MenuEntity::class,
        OutboxRow::class,
    ],
    version = 1,
    exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun recipes(): RecipeDao
    abstract fun ingredients(): IngredientDao
    abstract fun steps(): StepDao
    abstract fun shoppingLists(): ShoppingListDao
    abstract fun listItems(): ListItemDao
    abstract fun pantry(): PantryDao
    abstract fun plans(): PlanDao
    abstract fun menus(): MenuDao
    abstract fun outbox(): OutboxDao
}
