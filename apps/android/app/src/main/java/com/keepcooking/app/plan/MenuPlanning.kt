package com.keepcooking.app.plan

import com.keepcooking.app.data.MenuEntry
import java.time.LocalDate

/**
 * Pure menu helpers (no Room/Compose) — unit-tested in MenuPlanningTest.
 * Occupied keys are (date, plan meal) pairs; plan meals come from
 * [planMealForMenuSlot] so they always satisfy the plans contract.
 */

/** Plan-contract meals: plans allow only these four (anything else → dinner). */
val PLAN_MEALS = setOf("breakfast", "lunch", "dinner", "snack")

/** Valid menu apply offsets: day 1..28 of the menu grid. */
const val MAX_MENU_DAY_OFFSET = 27

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

/**
 * Maps a menu slot label to a plans-contract meal: a normalized meal in
 * breakfast/lunch/dinner/snack maps to itself, anything else (custom labels
 * like "brunch", or empty) maps to "dinner". The plans contract allows only
 * the four slots, so custom menu labels must never reach [PlanEntity]-style
 * writes — applyMenu maps through here for occupied keys, conflict matching,
 * and inserted mealRaw alike.
 */
fun planMealForMenuSlot(raw: String): String {
    val n = normalizeMeal(raw)
    return if (n in PLAN_MEALS) n else "dinner"
}

fun validateDayCount(n: Int): Int = n.coerceIn(1, 28)

/**
 * Entry-backed day count, clamped to 1..28 (consistent with iOS): empty or
 * all-negative offsets → 1; offsets past day 28 clamp to 28 (apply ignores
 * dayOffset < 0 or > 27).
 */
fun menuDayCount(entries: List<MenuEntry>): Int =
    validateDayCount((entries.maxOfOrNull { it.dayOffset } ?: -1) + 1)

/**
 * Distinct normalized non-empty slot labels in first-appearance order, or
 * [defaultSlots] when no usable label exists. Empty/blank labels are ignored
 * (they can never form a grid cell or a plan write).
 */
fun menuMealSlots(
    entries: List<MenuEntry>,
    defaultSlots: List<String> = listOf("breakfast", "lunch", "dinner", "snack"),
): List<String> {
    val seen = LinkedHashSet<String>()
    for (e in entries) {
        val meal = normalizeMeal(e.meal)
        if (meal.isNotEmpty()) seen += meal
    }
    return if (seen.isEmpty()) defaultSlots else seen.toList()
}

/**
 * Normalizes entries for apply, dropping rows that can never be written:
 * empty normalized meals and out-of-range offsets (dayOffset < 0 or > 27).
 * Callers surface the drop count as `entries.size - expandMenuEntries(...).size`.
 */
fun expandMenuEntries(entries: List<MenuEntry>): List<ExpandedMenuEntry> =
    entries.mapNotNull { e ->
        val meal = normalizeMeal(e.meal)
        if (meal.isEmpty() || e.dayOffset < 0 || e.dayOffset > MAX_MENU_DAY_OFFSET) return@mapNotNull null
        ExpandedMenuEntry(
            dayOffset = e.dayOffset,
            meal = meal,
            recipeId = e.recipeId,
            servings = e.servings,
        )
    }

/**
 * Splits expanded entries into (toInsert, skippedCount) against occupied
 * (date, plan-meal) keys. weekStart anchors dayOffset -> date. Map expanded
 * meals through [planMealForMenuSlot] (and build occupied keys the same way)
 * before calling so custom labels match their dinner fallback. When
 * [skipFilled] is false every entry inserts (overwrite path tombstones
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
