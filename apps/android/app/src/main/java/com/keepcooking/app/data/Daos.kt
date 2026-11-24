package com.keepcooking.app.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface RecipeDao {
    @Query("SELECT * FROM recipes WHERE deleted = 0 ORDER BY updatedAt DESC")
    suspend fun liveRecipes(): List<RecipeEntity>

    @Query("SELECT * FROM recipes WHERE id = :id LIMIT 1")
    suspend fun byId(id: String): RecipeEntity?

    @Query("SELECT COUNT(*) FROM recipes")
    suspend fun count(): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(rows: List<RecipeEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(row: RecipeEntity)
}

@Dao
interface IngredientDao {
    @Query("SELECT * FROM ingredients WHERE recipeId = :recipeId ORDER BY position ASC")
    suspend fun forRecipe(recipeId: String): List<IngredientEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(rows: List<IngredientEntity>)

    @Query("DELETE FROM ingredients WHERE recipeId = :recipeId")
    suspend fun deleteForRecipe(recipeId: String)
}

@Dao
interface StepDao {
    @Query("SELECT * FROM steps WHERE recipeId = :recipeId ORDER BY position ASC")
    suspend fun forRecipe(recipeId: String): List<StepEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(rows: List<StepEntity>)

    @Query("DELETE FROM steps WHERE recipeId = :recipeId")
    suspend fun deleteForRecipe(recipeId: String)
}

@Dao
interface ShoppingListDao {
    @Query("SELECT * FROM shopping_lists WHERE deleted = 0 ORDER BY updatedAt DESC")
    suspend fun liveLists(): List<ShoppingListEntity>

    /** Lookup including tombstones: LWW must compare against deletes, not just live rows. */
    @Query("SELECT * FROM shopping_lists WHERE id = :id LIMIT 1")
    suspend fun byIdIncludingDeleted(id: String): ShoppingListEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(rows: List<ShoppingListEntity>)
}

@Dao
interface ListItemDao {
    @Query("SELECT * FROM list_items WHERE listId = :listId")
    suspend fun forList(listId: String): List<ListItemEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(rows: List<ListItemEntity>)

    @Query("DELETE FROM list_items WHERE listId = :listId")
    suspend fun deleteForList(listId: String)
}

@Dao
interface PantryDao {
    @Query("SELECT * FROM pantry_items WHERE deleted = 0 ORDER BY updatedAt DESC")
    suspend fun liveItems(): List<PantryItemEntity>

    /** Lookup including tombstones: an older remote live envelope must not resurrect a delete. */
    @Query("SELECT * FROM pantry_items WHERE id = :id LIMIT 1")
    suspend fun byIdIncludingDeleted(id: String): PantryItemEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(rows: List<PantryItemEntity>)
}

@Dao
interface PlanDao {
    @Query("SELECT * FROM plans WHERE deleted = 0 ORDER BY date ASC")
    suspend fun livePlans(): List<PlanEntity>

    /** Lookup including tombstones for header LWW. */
    @Query("SELECT * FROM plans WHERE id = :id LIMIT 1")
    suspend fun byIdIncludingDeleted(id: String): PlanEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(rows: List<PlanEntity>)
}

@Dao
interface MenuDao {
    @Query("SELECT * FROM menus WHERE deleted = 0 ORDER BY updatedAt DESC")
    suspend fun liveMenus(): List<MenuEntity>

    /** Lookup including tombstones for header LWW. */
    @Query("SELECT * FROM menus WHERE id = :id LIMIT 1")
    suspend fun byIdIncludingDeleted(id: String): MenuEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(rows: List<MenuEntity>)
}

@Dao
interface OutboxDao {
    @Query("SELECT * FROM sync_outbox ORDER BY enqueuedAt ASC")
    suspend fun all(): List<OutboxRow>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun enqueue(row: OutboxRow)

    @Query("DELETE FROM sync_outbox WHERE id = :id")
    suspend fun remove(id: String)

    @Query("DELETE FROM sync_outbox")
    suspend fun clear()
}
