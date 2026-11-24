package com.keepcooking.app.plan

import com.keepcooking.app.cook.scaleFactor
import com.keepcooking.app.cook.scaledDisplay
import com.keepcooking.app.cook.scaledQuantity

/**
 * Week aggregation + webcal feed — port of
 * apps/ios/Features/Plan/PlanAggregation.swift (pure).
 *   - [aggregateWeekToList]: plans for a week -> merged shopping-list lines,
 *     quantities scaled (plan.servings vs recipe.servings) and summed by
 *     (lowercased name + unit). Display strings use scaler fractions.
 *   - [planFeedSubscribeUrl]: https://.../plans/feed.ics -> webcal:// subscribe URL.
 */

/** One recipe's contribution to a shopping list. */
data class PlanGroceryInput(
    val name: String,
    val quantity: Double?,
    val unit: String,
    /** Servings the recipe as written makes. */
    val baseServings: Double,
    /** Servings the plan entry calls for (null = as written). */
    val targetServings: Double? = null,
    val recipeId: String? = null,
)

/** One merged shopping-list line. */
data class AggregatedItem(
    val name: String, // display-cased from first occurrence
    val unit: String,
    val totalQuantity: Double?, // null when all inputs unmeasured
    val recipeIds: List<String> = emptyList(),
) {
    /** "1½ cups flour" / "Salt" when unmeasured. */
    val display: String
        get() {
            val q = totalQuantity ?: return name
            return scaledDisplay(name = name, quantity = q, unit = unit, factor = 1.0)
        }
}

/**
 * Aggregates a week's grocery inputs into merged list lines.
 * Same (name.lowercased(), unit.lowercased()) merge; unmeasured inputs
 * contribute a nil-quantity line that never absorbs measured ones.
 */
fun aggregateWeekToList(inputs: List<PlanGroceryInput>): List<AggregatedItem> {
    val measured = LinkedHashMap<String, AggregatedItem>()
    val unmeasured = mutableListOf<AggregatedItem>()

    for (input in inputs) {
        val target = input.targetServings ?: input.baseServings
        val factor = scaleFactor(baseServings = input.baseServings, targetServings = target)
        val key = "${input.name.lowercase()}\u001F${input.unit.lowercase()}"
        val q = scaledQuantity(input.quantity, factor)
        if (q == null) {
            if (unmeasured.none { it.name.lowercase() == input.name.lowercase() }) {
                unmeasured.add(
                    AggregatedItem(
                        name = input.name,
                        unit = input.unit,
                        totalQuantity = null,
                        recipeIds = input.recipeId?.let { listOf(it) } ?: emptyList(),
                    ),
                )
            }
            continue
        }
        val existing = measured[key]
        if (existing != null) {
            val ids = existing.recipeIds.toMutableList()
            if (input.recipeId != null && input.recipeId !in ids) ids.add(input.recipeId)
            measured[key] = existing.copy(
                totalQuantity = (existing.totalQuantity ?: 0.0) + q,
                recipeIds = ids,
            )
        } else {
            measured[key] = AggregatedItem(
                name = input.name,
                unit = input.unit,
                totalQuantity = q,
                recipeIds = input.recipeId?.let { listOf(it) } ?: emptyList(),
            )
        }
    }
    return measured.values.toList() + unmeasured
}

/**
 * Builds the subscribe URL for Lane 1 GET /plans/feed.ics.
 * `https://api.example.com/plans/feed.ics?...` -> `webcal://...` so a
 * calendar app offers a subscribe sheet.
 */
fun planFeedSubscribeUrl(baseUrl: String, householdId: String): String? {
    val trimmed = baseUrl.trimEnd('/')
    if (trimmed.isEmpty() || householdId.isEmpty()) return null
    val https = "$trimmed/plans/feed.ics?householdId=$householdId"
    return when {
        https.startsWith("https://") -> "webcal://" + https.removePrefix("https://")
        https.startsWith("http://") -> "webcal://" + https.removePrefix("http://")
        else -> null
    }
}
