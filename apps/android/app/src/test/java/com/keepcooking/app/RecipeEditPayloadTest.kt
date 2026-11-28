package com.keepcooking.app

import com.keepcooking.app.data.IngredientEntity
import com.keepcooking.app.data.RecipeEntity
import com.keepcooking.app.data.StepEntity
import com.keepcooking.app.navigation.buildRecipeEditPayload
import com.keepcooking.app.navigation.effectiveTotalMinutes
import com.keepcooking.app.ui.screens.formatMinutes
import com.keepcooking.app.ui.screens.hostOfUrl
import com.keepcooking.app.ui.screens.ingredientFullLine
import com.keepcooking.app.ui.screens.isIngredientHeaderRow
import com.keepcooking.app.ui.screens.resolvePhotoUrl
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Envelope-shape regression tests for the recipe editor save path (cubic review). */
class RecipeEditPayloadTest {

    private fun recipe() = RecipeEntity(
        id = "r1",
        householdId = "hh-demo",
        title = "Soup",
        recipeDescription = "Tasty.",
        servings = 4.0,
        prepMinutes = 10,
        cookMinutes = 20,
        rating = 4.0,
        isFavorite = true,
        source = "example.com",
        sourceUrl = "https://example.com/soup",
        photoOriginal = "photos/r1/original.jpg",
        photoLarge1024 = null,
        photoThumb = "",
    )

    private fun payload() = buildRecipeEditPayload(
        recipe = recipe(),
        categories = listOf("dinner"),
        difficulty = "Easy",
        notes = "Extra salt.",
        nutritionText = "Calories: 100",
        totalMinutes = 30,
        ingredients = listOf(
            IngredientEntity(
                id = "i1", recipeId = "r1", name = "white miso",
                quantity = 1.0, unit = "tsp", display = "1 tsp", position = 0,
            ),
            IngredientEntity(
                id = "i2", recipeId = "r1", name = "Topping:",
                quantity = null, unit = "", display = "Topping:", position = 1,
            ),
        ),
        steps = listOf(
            StepEntity(
                id = "s1", recipeId = "r1", position = 0, text = "Boil.",
                timersJson = """[{"seconds":60,"label":"boil"}]""",
            ),
            StepEntity(id = "s2", recipeId = "r1", position = 1, text = "Serve."),
        ),
    )

    @Test
    fun `description uses the sync wire key`() {
        val p = payload()
        assertEquals("Tasty.", p["description"]!!.jsonPrimitive.content)
        assertFalse(p.containsKey("recipeDescription"))
    }

    @Test
    fun `photoKeys object carries all stored keys`() {
        val keys = payload()["photoKeys"]!!.jsonObject
        assertEquals("photos/r1/original.jpg", keys["original"]!!.jsonPrimitive.content)
        assertEquals("", keys["large1024"]!!.jsonPrimitive.content)
        assertEquals("", keys["thumb"]!!.jsonPrimitive.content)
        assertFalse(payload().containsKey("photoOriginal"))
        assertFalse(payload().containsKey("photoThumb"))
    }

    @Test
    fun `ingredients carry quantity and unit`() {
        val first = payload()["ingredients"]!!.jsonArray[0].jsonObject
        assertEquals("white miso", first["name"]!!.jsonPrimitive.content)
        assertEquals(1.0, first["quantity"]!!.jsonPrimitive.double, 0.0)
        assertEquals("tsp", first["unit"]!!.jsonPrimitive.content)
        assertEquals("1 tsp", first["display"]!!.jsonPrimitive.content)
    }

    @Test
    fun `header ingredient keeps empty quantity and unit`() {
        val header = payload()["ingredients"]!!.jsonArray[1].jsonObject
        assertFalse(header.containsKey("quantity"))
        assertEquals("", header["unit"]!!.jsonPrimitive.content)
        assertEquals("Topping:", header["display"]!!.jsonPrimitive.content)
    }

    @Test
    fun `steps carry timers parsed from timersJson`() {
        val steps = payload()["steps"]!!.jsonArray
        val timers = steps[0].jsonObject["timers"]!!.jsonArray
        assertEquals(1, timers.size)
        assertEquals(60, timers[0].jsonObject["seconds"]!!.jsonPrimitive.int)
        assertTrue(steps[1].jsonObject["timers"]!!.jsonArray.isEmpty())
    }

    @Test
    fun `snapshot scalars are complete`() {
        val p = payload()
        assertEquals(true, p["isFavorite"]!!.jsonPrimitive.boolean)
        assertEquals(30, p["totalMinutes"]!!.jsonPrimitive.int)
        assertEquals(10, p["prepMinutes"]!!.jsonPrimitive.int)
        assertEquals(20, p["cookMinutes"]!!.jsonPrimitive.int)
        assertEquals("Easy", p["difficulty"]!!.jsonPrimitive.content)
        assertEquals("Extra salt.", p["notes"]!!.jsonPrimitive.content)
        assertEquals("Calories: 100", p["nutritionText"]!!.jsonPrimitive.content)
    }

    @Test
    fun `blank notes and nutrition are emitted as explicit clears`() {
        // Server semantics (api/src/store.ts ??): missing/null keys keep the
        // stored value, only "" clears — so blanks must be emitted, never omitted.
        val timeless = recipe().copy(prepMinutes = null, cookMinutes = null)
        val p = buildRecipeEditPayload(
            recipe = timeless, categories = emptyList(), difficulty = null,
            notes = "", nutritionText = "",
            totalMinutes = null,
            ingredients = emptyList(), steps = emptyList(),
        )
        assertEquals("", p["notes"]!!.jsonPrimitive.content)
        assertEquals("", p["nutritionText"]!!.jsonPrimitive.content)
        assertEquals("", p["difficulty"]!!.jsonPrimitive.content)
        assertFalse(p.containsKey("totalMinutes"))
    }

    @Test
    fun `effectiveTotalMinutes preserves overrides until times change`() {
        // Explicit synced total survives an unrelated edit.
        assertEquals(90, effectiveTotalMinutes(90, 10, 20, 10, 20))
        // Changing a time re-derives.
        assertEquals(35, effectiveTotalMinutes(90, 15, 20, 10, 20))
        assertEquals(20, effectiveTotalMinutes(90, null, 20, 10, 20))
        // No override: derive, or no key at all without times.
        assertEquals(30, effectiveTotalMinutes(null, 10, 20, 10, 25))
        assertNull(effectiveTotalMinutes(null, null, null, null, null))
    }

    @Test
    fun `hostOfUrl accepts real hosts including schemeless ones`() {
        assertEquals("example.com", hostOfUrl("https://example.com/dup"))
        assertEquals("example.com", hostOfUrl("https://www.example.com/"))
        assertEquals("example.com", hostOfUrl("example.com/x"))
        assertNull(hostOfUrl("not a url"))
        assertNull(hostOfUrl(""))
        assertNull(hostOfUrl("   "))
        assertNull(hostOfUrl("/just/a/path"))
    }

    @Test
    fun `ingredientFullLine appends missing names both directions`() {
        assertEquals("1 tsp white miso", ingredientFullLine("1 tsp", "white miso"))
        assertEquals("1 tsp white miso", ingredientFullLine("1 tsp white miso", "white miso"))
        assertEquals("white miso", ingredientFullLine("", "white miso"))
        assertEquals("salt", ingredientFullLine("salt", ""))
    }

    @Test
    fun `header predicate matches editor rows`() {
        assertTrue(isIngredientHeaderRow(null, "", "Topping:"))
        assertFalse(isIngredientHeaderRow(1.0, "tsp", "1 tsp"))
        assertFalse(isIngredientHeaderRow(null, "", "plain line"))
    }

    @Test
    fun `resolvePhotoUrl passes absolute URIs and nulls storage keys`() {
        assertEquals(
            "https://example.com/a.jpg",
            resolvePhotoUrl("https://example.com/a.jpg"),
        )
        assertNull(resolvePhotoUrl("photos/abc/thumb.jpg"))
        assertNull(resolvePhotoUrl(""))
        assertNull(resolvePhotoUrl(null))
        assertNull(resolvePhotoUrl("   "))
    }

    @Test
    fun `formatMinutes renders totals`() {
        assertEquals("25 min", formatMinutes(25))
        assertEquals("1 hr 25 min", formatMinutes(85))
        assertEquals("", formatMinutes(null))
    }
}
