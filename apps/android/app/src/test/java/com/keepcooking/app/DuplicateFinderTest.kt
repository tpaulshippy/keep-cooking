package com.keepcooking.app.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM port of iOS DuplicateFinderTests. */
class DuplicateFinderTest {

    data class Stub(
        override val recipeId: String,
        override val title: String,
        override val ingredientNames: List<String> = listOf("1 tsp salt"),
        override val stepTexts: List<String> = listOf("Cook and serve."),
        override val rating: Double? = 4.0,
        override val categories: List<String> = listOf("dinner"),
        override val photoOriginal: String? = null,
        override val photoThumb: String? = photoOriginal?.let { "thumb.jpg" },
    ) : DuplicableRecipe

    private fun seeds() = listOf(
        Stub("..000001", "Weeknight Miso Salmon", categories = listOf("dinner", "fish"), photoOriginal = "photos/..000001/original.jpg"),
        Stub("..000002", "Margherita Pizza"),
        Stub("..000003", "Chicken Tikka Masala"),
        Stub("..000004", "Avocado Toast"),
        Stub("..000005", "Blueberry Pancakes"),
        Stub("..000006", "Caesar Salad"),
        Stub("..000007", "Beef Tacos"),
        Stub("..000008", "Tomato Basil Soup"),
        Stub("..000009", "Chocolate Chip Cookies", categories = listOf("dessert", "baking"), photoOriginal = "photos/..000009/original.jpg"),
        Stub("..000010", "Banana Bread"),
        Stub("..000011", "Garlic Butter Pasta"),
        Stub("..000012", "Greek Grain Bowl"),
        Stub("..000013", "dup of 09"),
        Stub("..000014", "Miso Salmon Weeknight"),
        Stub("..000015", "Choc Chip Cookies"),
    )

    @Test fun `catches all three seeded dupes`() {
        val groups = findDuplicateGroups(seeds())
        val clustered = groups.flatMap { it.map { r -> r.recipeId } }.toSet()
        assertTrue(clustered.contains("..000013"))
        assertTrue(clustered.contains("..000014"))
        assertTrue(clustered.contains("..000015"))
        fun groupOf(id: String) = groups.firstOrNull { g -> g.any { it.recipeId == id } }?.map { it.recipeId }?.toSet() ?: emptySet()
        assertTrue(groupOf("..000014").contains("..000001"))
        assertTrue(groupOf("..000015").contains("..000009"))
        assertTrue(groupOf("..000013").contains("..000009"))
    }

    @Test fun `distinct seeds do not cluster`() {
        val mains = seeds().filter {
            it.recipeId in setOf("..000002", "..000003", "..000004", "..000006", "..000007", "..000008", "..000010", "..000011", "..000012")
        }
        assertTrue(findDuplicateGroups(mains).isEmpty())
    }

    @Test fun `self never matches`() {
        val r = Stub("..000009", "Chocolate Chip Cookies")
        assertFalse(isDuplicatePair(r, r))
    }

    @Test fun `merge keeps best photo and unions ingredients`() {
        val a = Stub("..000009", "Chocolate Chip Cookies", ingredientNames = listOf("2 cups flour", "1 tsp salt"), categories = listOf("dessert"), photoOriginal = "photos/short.jpg")
        val b = Stub("..000015", "Choc Chip Cookies", ingredientNames = listOf("1 TSP Salt", "1 cup choc chips"), categories = listOf("baking"), photoOriginal = "photos/a-much-longer-higher-resolution-key.jpg")
        val plan = planMerge(listOf(a, b)) ?: throw AssertionError("expected a merge plan")
        assertEquals("photos/a-much-longer-higher-resolution-key.jpg", plan.bestPhotoOriginal)
        assertEquals(3, plan.mergedIngredientNames.size)
        assertEquals(1, plan.mergedIngredientNames.count { it.lowercase().contains("salt") })
        assertEquals(setOf("baking", "dessert"), plan.mergedCategories.toSet())
        assertEquals(1, plan.absorbedIds.size)
        assertFalse(plan.absorbedIds.contains(plan.survivorId))
    }

    @Test fun `merge needs a pair`() {
        assertNull(planMerge(listOf(Stub("..000001", "Solo"))))
    }

    @Test fun `abbreviation normalization`() {
        assertEquals(listOf("chocolate", "chip", "cookies"), titleTokens("Choc-Chip Cookies!"))
        assertTrue(jaccard(titleTokens("Choc Chip Cookies"), titleTokens("Chocolate Chip Cookies")) >= 0.5)
    }

    @Test fun `reference signal`() {
        assertEquals("09", referenceFragment("dup of 09"))
        assertEquals("salsa", strippedCopyTitle("Salsa (1)"))
        assertEquals("salsa", strippedCopyTitle("Copy of Salsa"))
        val target = Stub("..000009", "Chocolate Chip Cookies")
        assertTrue(isDuplicatePair(Stub("..000013", "dup of 09"), target))
        assertFalse(isDuplicatePair(Stub("..000099", "dup of 42"), target))
    }
}
