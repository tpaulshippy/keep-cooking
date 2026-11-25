package com.keepcooking.app.shop

import com.keepcooking.app.plan.AggregatedItem
import com.keepcooking.app.plan.PlanGroceryInput
import com.keepcooking.app.plan.aggregateWeekToList

/**
 * Aisle sorting + pantry helpers — port of
 * apps/ios/Features/Shop/ShopHelpers.swift (pure).
 */

/** Canonical aisle order. Unknown aisles sort after known ones, alphabetically. */
private val canonicalAisles = listOf(
    "produce", "bakery", "deli", "meat", "seafood",
    "dairy", "frozen", "canned", "dry goods", "pasta",
    "baking", "spices", "snacks", "beverages", "household",
)

/** Sort key: (known-aisle rank, aisle name, item name), all lowercased. */
fun aisleSortKey(aisle: String, name: String): Triple<Int, String, String> {
    val a = aisle.trim().lowercase()
    if (a.isEmpty()) return Triple(Int.MAX_VALUE - 1, "", name.lowercase()) // unfiled: last-ish
    val rank = canonicalAisles.indexOf(a)
    if (rank >= 0) return Triple(rank, a, name.lowercase())
    return Triple(canonicalAisles.size, a, name.lowercase())
}

/** Normalized aisle key: trimmed + lowercased, so values differing only by case/whitespace group together. */
fun normalizedAisleKey(aisle: String): String = aisle.trim().lowercase()

fun <T> aisleGroupedNames(items: List<T>, aisleOf: (T) -> String, nameOf: (T) -> String): List<String> {
    // Dedupe on the normalized key; keep the first-seen raw value as the
    // section representative so identical inputs render byte-identically.
    val seen = LinkedHashMap<String, String>()
    for (item in items) {
        val raw = aisleOf(item)
        val key = normalizedAisleKey(raw)
        if (!seen.containsKey(key)) seen[key] = raw
    }
    return seen.values.sortedWith { l, r ->
        val kl = aisleSortKey(aisle = l, name = "")
        val kr = aisleSortKey(aisle = r, name = "")
        when {
            kl.first != kr.first -> kl.first.compareTo(kr.first)
            else -> kl.second.compareTo(kr.second)
        }
    }
}

enum class ExpiryStatus {
    EXPIRED,
    EXPIRING_SOON, // within 7 days
    FRESH,
    NO_DATE,
}

/**
 * Classifies an expiry date relative to [nowMillis] (default: today).
 * Times are epoch millis.
 */
fun expiryStatus(expiresAtMillis: Long?, nowMillis: Long = System.currentTimeMillis()): ExpiryStatus {
    if (expiresAtMillis == null) return ExpiryStatus.NO_DATE
    if (expiresAtMillis < nowMillis) return ExpiryStatus.EXPIRED
    val weekOut = nowMillis + 7L * 24 * 60 * 60 * 1000
    if (expiresAtMillis <= weekOut) return ExpiryStatus.EXPIRING_SOON
    return ExpiryStatus.FRESH
}

/**
 * True when [quantity] is at/below the low-stock [threshold].
 * Both are free-text ("2", "500g"); compares numeric prefixes when possible,
 * otherwise falls back to non-empty equality (any stock beats empty).
 */
fun isLowStock(quantity: String, threshold: String): Boolean {
    val q = quantity.trim()
    val t = threshold.trim()
    if (t.isEmpty()) return false // no threshold set
    if (q.isEmpty()) return true // nothing left
    val qn = q.takeWhile { it.isDigit() || it == '.' }.toDoubleOrNull()
    val tn = t.takeWhile { it.isDigit() || it == '.' }.toDoubleOrNull()
    if (qn != null && tn != null && (qn > 0 || tn > 0)) {
        return qn <= tn
    }
    return false
}

/**
 * Adds one recipe's ingredients to a list, scaled to target servings.
 * Pure helper so the sheet + tests share logic.
 */
fun recipeLinesToList(inputs: List<PlanGroceryInput>): List<AggregatedItem> =
    aggregateWeekToList(inputs)
