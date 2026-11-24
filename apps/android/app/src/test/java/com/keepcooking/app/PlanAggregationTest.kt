package com.keepcooking.app

import com.keepcooking.app.plan.PlanGroceryInput
import com.keepcooking.app.plan.aggregateWeekToList
import com.keepcooking.app.plan.planFeedSubscribeUrl
import com.keepcooking.app.shop.ExpiryStatus
import com.keepcooking.app.shop.aisleGroupedNames
import com.keepcooking.app.shop.aisleSortKey
import com.keepcooking.app.shop.expiryStatus
import com.keepcooking.app.shop.isLowStock
import com.keepcooking.app.shop.normalizedAisleKey
import com.keepcooking.app.shop.recipeLinesToList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Plan aggregation + shop helper tests, mirroring the aggregation/aisle/
 * pantry section of apps/ios/Features/Cook/CookTests.swift.
 */
class PlanAggregationTest {
    // MARK: - Aggregation (plan -> list, scaled)

    @Test
    fun aggregationScaledMerge() {
        // Two plans, same flour: 2 cups @4 servings as-written + 2 cups @4
        // servings scaled to 6 (1.5x -> 3 cups) = 5 cups total.
        val inputs = listOf(
            PlanGroceryInput("Flour", 2.0, "cups", baseServings = 4.0, targetServings = 4.0, recipeId = "r1"),
            PlanGroceryInput("flour", 2.0, "cups", baseServings = 4.0, targetServings = 6.0, recipeId = "r2"),
        )
        val out = aggregateWeekToList(inputs)
        assertEquals(1, out.size)
        assertEquals(5.0, out[0].totalQuantity ?: -1.0, 0.001)
        assertEquals("5 cups Flour", out[0].display)
    }

    @Test
    fun aggregationUnmeasuredPassthrough() {
        val inputs = listOf(
            PlanGroceryInput("Salt", null, "", baseServings = 4.0, targetServings = 6.0),
        )
        val out = aggregateWeekToList(inputs)
        assertEquals(1, out.size)
        assertNull(out[0].totalQuantity)
        assertEquals("Salt", out[0].display)
    }

    @Test
    fun recipeLinesToListMatchesAggregation() {
        val inputs = listOf(
            PlanGroceryInput("Flour", 2.0, "cups", baseServings = 4.0, targetServings = 6.0),
        )
        val out = recipeLinesToList(inputs)
        assertEquals(1, out.size)
        assertEquals(3.0, out[0].totalQuantity ?: -1.0, 0.001)
    }

    @Test
    fun planFeedSubscribeUrlRewritesToWebcal() {
        val url = planFeedSubscribeUrl("https://api.example.com", "h1")
        assertEquals("webcal://api.example.com/plans/feed.ics?householdId=h1", url)
    }

    // MARK: - Shop helpers

    @Test
    fun aisleSortProduceBeforeDairy() {
        val kp = aisleSortKey("produce", "x")
        val kd = aisleSortKey("dairy", "x")
        assertTrue(kp.first < kd.first)
        // Unknown aisles sort after known ones.
        val ku = aisleSortKey("zebra", "x")
        assertTrue(kd.first < ku.first)
    }

    @Test
    fun aisleGroupedNamesNormalizesCaseAndWhitespace() {
        data class Item(val aisle: String, val name: String)
        val items = listOf(
            Item("Produce", "Apples"),
            Item("produce ", "Carrots"),
            Item("PRODUCE", "Bananas"),
            Item("dairy", "Milk"),
            Item("", "Mystery"),
            Item("  ", "Other mystery"),
        )
        val groups = aisleGroupedNames(items, aisleOf = { it.aisle }, nameOf = { it.name })
        assertEquals(3, groups.size) // produce + dairy + unfiled, not 6
        assertEquals(setOf("produce", "dairy", ""), groups.map { normalizedAisleKey(it) }.toSet())
    }

    @Test
    fun normalizedAisleKey() {
        assertEquals("produce", normalizedAisleKey(" Produce "))
        assertEquals("dairy", normalizedAisleKey("DAIRY"))
        assertEquals("", normalizedAisleKey(""))
    }

    @Test
    fun expiryStatusCases() {
        val now = System.currentTimeMillis()
        assertEquals(ExpiryStatus.EXPIRED, expiryStatus(now - 10_000, now))
        assertEquals(ExpiryStatus.EXPIRING_SOON, expiryStatus(now + 3L * 86400000, now))
        assertEquals(ExpiryStatus.FRESH, expiryStatus(now + 30L * 86400000, now))
        assertEquals(ExpiryStatus.NO_DATE, expiryStatus(null, now))
    }

    @Test
    fun lowStock() {
        assertTrue(isLowStock("1", "2"))
        assertTrue(!isLowStock("3", "2"))
        assertTrue(!isLowStock("anything", "")) // no threshold
        assertTrue(isLowStock("", "2")) // nothing left
    }
}
