package com.keepcooking.app

import com.keepcooking.app.data.MenuEntry
import com.keepcooking.app.plan.ExpandedMenuEntry
import com.keepcooking.app.plan.expandMenuEntries
import com.keepcooking.app.plan.filterSkipped
import com.keepcooking.app.plan.menuDayCount
import com.keepcooking.app.plan.menuMealSlots
import com.keepcooking.app.plan.normalizeMeal
import com.keepcooking.app.plan.validateDayCount
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure menu-planning helpers (MenuPlanning.kt): day counts, meal slots,
 * normalization, clamping, and skip-vs-overwrite apply semantics.
 */
class MenuPlanningTest {
    private fun entry(day: Int, meal: String, recipe: String = "r1", servings: Double = 4.0) =
        MenuEntry(dayOffset = day, meal = meal, recipeId = recipe, servings = servings)

    @Test
    fun dayCountIsMaxOffsetPlusOneMinOne() {
        assertEquals(1, menuDayCount(emptyList()))
        assertEquals(1, menuDayCount(listOf(entry(0, "dinner"))))
        assertEquals(3, menuDayCount(listOf(entry(0, "dinner"), entry(2, "lunch"))))
    }

    @Test
    fun mealSlotsDistinctNormalizedInOrder() {
        val entries = listOf(entry(0, "Dinner"), entry(1, "dinner"), entry(0, " Snacks "))
        assertEquals(listOf("dinner", "snack"), menuMealSlots(entries))
    }

    @Test
    fun mealSlotsEmptyFallsBackToDefaults() {
        assertEquals(
            listOf("breakfast", "lunch", "dinner", "snack"),
            menuMealSlots(emptyList()),
        )
        assertEquals(listOf("brunch"), menuMealSlots(emptyList(), listOf("brunch")))
    }

    @Test
    fun normalizeMealTrimsLowercasesAndFoldsSnacks() {
        assertEquals("dinner", normalizeMeal(" Dinner "))
        assertEquals("snack", normalizeMeal("snacks"))
        assertEquals("snack", normalizeMeal(" SNACKS "))
        assertEquals("brunch", normalizeMeal("Brunch"))
    }

    @Test
    fun dayCountClamp() {
        assertEquals(1, validateDayCount(0))
        assertEquals(1, validateDayCount(-5))
        assertEquals(28, validateDayCount(29))
        assertEquals(28, validateDayCount(500))
        assertEquals(7, validateDayCount(7))
    }

    @Test
    fun expandNormalizesMeals() {
        val out = expandMenuEntries(listOf(entry(1, " Snacks ")))
        assertEquals(1, out.size)
        assertEquals(1, out[0].dayOffset)
        assertEquals("snack", out[0].meal)
        assertEquals("r1", out[0].recipeId)
        assertEquals(4.0, out[0].servings ?: -1.0, 0.001)
    }

    @Test
    fun filterSkippedSkipsOccupied() {
        val weekStart = LocalDate.of(2026, 11, 23) // a Monday
        val expanded = listOf(
            ExpandedMenuEntry(0, "dinner", "r1", 4.0),
            ExpandedMenuEntry(1, "lunch", "r2", 2.0),
        )
        val occupied = setOf(weekStart to "dinner")
        val (toInsert, skipped) = filterSkipped(expanded, weekStart, occupied, skipFilled = true)
        assertEquals(1, toInsert.size)
        assertEquals("r2", toInsert[0].recipeId)
        assertEquals(1, skipped)
    }

    @Test
    fun filterOverwriteInsertsEverything() {
        val weekStart = LocalDate.of(2026, 11, 23)
        val expanded = listOf(
            ExpandedMenuEntry(0, "dinner", "r1", 4.0),
            ExpandedMenuEntry(1, "lunch", "r2", 2.0),
        )
        val occupied = setOf(weekStart to "dinner", weekStart.plusDays(1) to "lunch")
        val (toInsert, skipped) = filterSkipped(expanded, weekStart, occupied, skipFilled = false)
        assertEquals(2, toInsert.size)
        assertEquals(0, skipped)
    }

    @Test
    fun filterSkippedMatchesOccupiedByDateAndNormalizedMeal() {
        val weekStart = LocalDate.of(2026, 11, 23)
        val expanded = listOf(ExpandedMenuEntry(2, "snack", "r9", 1.0))
        // Occupied key stored with raw casing still matches after normalization.
        val occupied = setOf(weekStart.plusDays(2) to normalizeMeal("Snacks"))
        val (toInsert, skipped) = filterSkipped(expanded, weekStart, occupied, skipFilled = true)
        assertTrue(toInsert.isEmpty())
        assertEquals(1, skipped)
    }
}
