package com.keepcooking.app

import androidx.room.Room
import com.keepcooking.app.data.AppDatabase
import com.keepcooking.app.data.ShoppingListEntity
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * Room DAO tombstone test (robolectric, in-memory DB): header LWW must compare
 * against DELETED rows, so [byIdIncludingDeleted] has to return tombstones
 * while the live lists hide them. Covered by `./gradlew :app:testDebugUnitTest`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class TombstoneDaoTest {

    private lateinit var db: AppDatabase

    @Before
    fun open() {
        db = Room.inMemoryDatabaseBuilder(
            RuntimeEnvironment.getApplication(),
            AppDatabase::class.java,
        ).allowMainThreadQueries().build()
    }

    @After
    fun close() {
        db.close()
    }

    @Test
    fun `byIdIncludingDeleted returns tombstones`() = runTest {
        val live = ShoppingListEntity(
            id = "l-live", householdId = "hh-demo", name = "Groceries",
            updatedAt = 100L, deviceId = "d1", deleted = false,
        )
        val tomb = ShoppingListEntity(
            id = "l-gone", householdId = "hh-demo", name = "Gone",
            updatedAt = 200L, deviceId = "d1", deleted = true,
        )
        db.shoppingLists().upsertAll(listOf(live, tomb))

        val found = db.shoppingLists().byIdIncludingDeleted("l-gone")
        assertNotNull(found)
        assertTrue(found!!.deleted)
        assertEquals(200L, found.updatedAt)

        // Live reads hide the tombstone but still see the live row.
        assertEquals(listOf("l-live"), db.shoppingLists().liveLists().map { it.id })
        assertNull(db.shoppingLists().byIdIncludingDeleted("l-missing"))
    }
}
