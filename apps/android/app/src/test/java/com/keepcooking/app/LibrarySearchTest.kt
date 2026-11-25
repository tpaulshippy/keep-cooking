package com.keepcooking.app.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM port of iOS IngredientParserTests…Ingredients split via parseLines; OCR + clip-host covered in Ingest tests. */
class LibrarySearchTest {

    data class Stub(
        override val recipeId: String,
        override val title: String,
        override val categories: List<String> = emptyList(),
        override val ingredientNames: List<String> = emptyList(),
        override val stepTexts: List<String> = emptyList(),
        override val recipeDescription: String = "",
        override val servings: Double = 4.0,
        override val prepMinutes: Int? = null,
        override val cookMinutes: Int? = null,
        override val rating: Double? = null,
        override val source: String = "",
    ) : LibraryRecipe

    private fun recipes() = listOf(
        Stub("r1", "Weeknight Miso Salmon", listOf("dinner", "fish"), listOf("salmon", "miso", "rice"), listOf("Bake 20 minutes.")),
        Stub("r2", "Miso Soup", listOf("Dinner"), listOf("miso", "tofu"), listOf("Simmer gently.")),
        Stub("r3", "Blueberry Pancakes", listOf("breakfast"), listOf("flour", "blueberries"), listOf("Flip once.")),
    )

    @Test fun `query matches across fields`() {
        val out = filterRecipes(recipes(), AdvancedFilter(query = "miso"))
        assertEquals(listOf("r1", "r2"), out.map { it.recipeId }.sorted())
    }

    @Test fun `query matches steps-only term`() {
        val out = filterRecipes(recipes(), AdvancedFilter(query = "bake"))
        assertEquals(listOf("r1"), out.map { it.recipeId })
    }

    @Test fun `query tokens are ANDed`() {
        val out = filterRecipes(recipes(), AdvancedFilter(query = "miso salmon"))
        assertEquals(listOf("r1"), out.map { it.recipeId })
    }

    @Test fun `capitalized query folds case`() {
        val out = filterRecipes(recipes(), AdvancedFilter(query = "MISO Salmon"))
        assertEquals(listOf("r1"), out.map { it.recipeId })
    }

    @Test fun `single category chip narrows case-insensitively`() {
        val out = filterRecipes(recipes(), AdvancedFilter(categories = listOf("dinner")))
        assertEquals(listOf("r1", "r2"), out.map { it.recipeId }.sorted())
    }

    @Test fun `query plus category combines`() {
        val out = filterRecipes(recipes(), AdvancedFilter(query = "miso", categories = listOf("fish")))
        assertEquals(listOf("r1"), out.map { it.recipeId })
    }

    @Test fun `empty filter returns all title-sorted`() {
        val out = filterRecipes(recipes(), AdvancedFilter())
        assertEquals(listOf("Blueberry Pancakes", "Miso Soup", "Weeknight Miso Salmon"), out.map { it.title })
    }

    @Test fun `exclude terms and time caps apply`() {
        val withTime = listOf(
            Stub("a", "Quick Soup", cookMinutes = 10, ingredientNames = listOf("miso")),
            Stub("b", "Slow Soup", cookMinutes = 90, ingredientNames = listOf("miso")),
        )
        assertEquals(listOf("a"), filterRecipes(withTime, AdvancedFilter(query = "miso", maxTotalMinutes = 30)).map { it.recipeId })
        assertEquals(listOf("b"), filterRecipes(withTime, AdvancedFilter(query = "soup", excludeTerms = listOf("quick"))).map { it.recipeId })
        assertTrue(filterRecipes(withTime, AdvancedFilter()).isNotEmpty())
        assertTrue(AdvancedFilter().isEmpty)
        assertFalse(AdvancedFilter(query = "miso").isEmpty)
    }
}
