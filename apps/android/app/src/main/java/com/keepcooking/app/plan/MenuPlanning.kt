package com.keepcooking.app.plan

import com.keepcooking.app.data.MenuEntry
import java.time.LocalDate

/**
 * Pure menu helpers (no Room/Compose) — unit-tested in MenuPlanningTest.
 * Occupied keys are (date, normalized meal) pairs.
 */

data class ExpandedMenuEntry(
    val dayOffset: Int,
    val meal: String,
    val recipeId: String,
    val servings: Double?,
)

fun normalizeMeal(raw: String): String {
    val t = raw.trim().lowercase()
    return if (t == "snacks") "snack" else t
}

fun validateDayCount(n: Int): Int = n.coerceIn(1, 28)

fun menuDayCount(entries: List<MenuEntry>): Int {
    val max = entries.maxOfOrNull { it.dayOffset } ?: return 1
    return maxOf(1, max + 1)
}

fun menuMealSlots(
    entries: List<MenuEntry>,
    defaultSlots: List<String> = listOf("breakfast", "lunch", "dinner", "snack"),
): List<String> {
    if (entries.isEmpty()) return defaultSlots
    val seen = LinkedHashSet<String>()
    for (e in entries) seen += normalizeMeal(e.meal)
    return seen.toList()
}

fun expandMenuEntries(entries: List<MenuEntry>): List<ExpandedMenuEntry> =
    entries.map { e ->
        ExpandedMenuEntry(
            dayOffset = e.dayOffset,
            meal = normalizeMeal(e.meal),
            recipeId = e.recipeId,
            servings = e.servings,
        )
    }

/**
 * Splits expanded entries into (toInsert, skippedCount) against occupied
 * (date, normalized-meal) keys. weekStart anchors dayOffset -> date.
 * When [skipFilled] is false every entry inserts (overwrite path tombstones
 * conflicts separately in PlanScreen).
 */
fun filterSkipped(
    expanded: List<ExpandedMenuEntry>,
    weekStart: LocalDate,
    occupiedKeys: Set<Pair<LocalDate, String>>,
    skipFilled: Boolean,
): Pair<List<ExpandedMenuEntry>, Int> {
    if (!skipFilled) return expanded to 0
    val insert = mutableListOf<ExpandedMenuEntry>()
    var skipped = 0
    for (e in expanded) {
        val key = weekStart.plusDays(e.dayOffset.toLong()) to e.meal
        if (key in occupiedKeys) skipped++ else insert += e
    }
    return insert to skipped
}
