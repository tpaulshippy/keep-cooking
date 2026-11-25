package com.keepcooking.app.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM port of iOS IngredientParserTests (parser + detector + OCR splitter + clip host). */
class IngredientParserTest {

    @Test fun `unicode half`() {
        val p = IngredientParser.parse("½ cup sugar")
        assertEquals(0.5, p.quantity ?: -1.0, 0.001)
        assertEquals("cup", p.unit)
        assertEquals("sugar", p.name)
    }

    @Test fun `ascii fraction`() {
        val p = IngredientParser.parse("1/2 tsp salt")
        assertEquals(0.5, p.quantity ?: -1.0, 0.001)
        assertEquals("tsp", p.unit)
        assertEquals("salt", p.name)
    }

    @Test fun `mixed number`() {
        val p = IngredientParser.parse("1 1/2 cups flour")
        assertEquals(1.5, p.quantity ?: -1.0, 0.001)
        assertEquals("cup", p.unit)
        assertEquals("flour", p.name)
    }

    @Test fun `attached unicode`() {
        val p = IngredientParser.parse("1½ cups flour")
        assertEquals(1.5, p.quantity ?: -1.0, 0.001)
        assertEquals("cup", p.unit)
    }

    @Test fun `range cloves`() {
        val p = IngredientParser.parse("2-3 cloves garlic")
        assertEquals(2.5, p.quantity ?: -1.0, 0.001)
        assertEquals("clove", p.unit)
        assertEquals("garlic", p.name)
        assertEquals("2-3", p.quantityText)
    }

    @Test fun `tablespoon variants`() {
        for (line in listOf("2 tbsp miso", "2 tablespoon miso", "2 tablespoons miso")) {
            val p = IngredientParser.parse(line)
            assertEquals("tbsp", p.unit)
            assertEquals("miso", p.name)
        }
    }

    @Test fun `metric units`() {
        assertEquals("g", IngredientParser.parse("200 g salmon").unit)
        assertEquals("ml", IngredientParser.parse("250 ml cream").unit)
        assertEquals("oz", IngredientParser.parse("8 oz mushrooms").unit)
        assertEquals("cup", IngredientParser.parse("2 cups rice").unit)
        assertEquals("tsp", IngredientParser.parse("1 tsp salt").unit)
    }

    @Test fun `bare name`() {
        val p = IngredientParser.parse("salt to taste")
        assertNull(p.quantity)
        assertEquals("salt to taste", p.name)
        assertEquals("salt to taste", p.display)
    }

    @Test fun `empty line`() {
        val p = IngredientParser.parse("   ")
        assertNull(p.quantity)
        assertEquals("", p.name)
    }

    @Test fun `parse lines skips blanks`() {
        assertEquals(2, IngredientParser.parseLines("1 cup rice\n\n1 tsp salt\n").size)
    }

    @Test fun `fraction string`() {
        assertEquals("1 1/2", IngredientParser.fractionString(1.5))
        assertEquals("1/2", IngredientParser.fractionString(0.5))
        assertEquals("2", IngredientParser.fractionString(2.0))
    }

    @Test fun `detector finds url`() {
        assertNotNull(ClipboardDetector.firstUrl("check https://www.allrecipes.com/recipe/123 yum"))
        assertNull(ClipboardDetector.firstUrl("no link here"))
    }

    @Test fun `detector looks like recipe`() {
        assertTrue(ClipboardDetector.looksLikeRecipe("https://example.com/soup"))
        assertTrue(ClipboardDetector.looksLikeRecipe("1 cup rice\n2 eggs\n"))
        assertFalse(ClipboardDetector.looksLikeRecipe("hello world"))
    }

    @Test fun `ocr splitter`() {
        val draft = OcrSplitter.split(listOf("Cream of Mushroom", "8 oz mushrooms", "2 cups cream", "Simmer 20 minutes."))
        assertEquals("Cream of Mushroom", draft.title)
        assertEquals(2, draft.ingredientLines.size)
        assertEquals(listOf("Simmer 20 minutes."), draft.stepLines)
    }

    @Test fun `clip host`() {
        assertEquals("www.allrecipes.com", clipHost("https://www.allrecipes.com/recipe/123"))
        assertEquals("caption-only", clipHost(null))
    }
}
