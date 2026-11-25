package com.keepcooking.app

import com.keepcooking.app.data.MealSlot
import com.keepcooking.app.data.resolveSyncWinner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Unit tests for the sync merge contract (mirrors iOS SyncEngine semantics). */
class SyncMergeTest {

    @Test
    fun `later remote wins`() {
        assertTrue(resolveSyncWinner(localUpdatedAt = 100L, remoteUpdatedAt = 200L))
    }

    @Test
    fun `earlier remote loses`() {
        assertFalse(resolveSyncWinner(localUpdatedAt = 200L, remoteUpdatedAt = 100L))
    }

    @Test
    fun `ties break toward remote for determinism`() {
        assertTrue(resolveSyncWinner(localUpdatedAt = 100L, remoteUpdatedAt = 100L))
    }

    @Test
    fun `meal slot defaults to dinner on unknown raw`() {
        assertEquals(MealSlot.DINNER, MealSlot.fromRaw("brunch??"))
        assertEquals(MealSlot.LUNCH, MealSlot.fromRaw("lunch"))
    }
}
