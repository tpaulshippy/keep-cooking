package com.keepcooking.app

import com.keepcooking.app.export.RecipeExporter
import com.keepcooking.app.export.paprikaGzip
import com.keepcooking.app.export.paprikaJsonFor
import com.keepcooking.app.export.paprikaUidFor
import com.keepcooking.app.export.paprikaZipFor
import com.keepcooking.app.export.yamlFor
import com.keepcooking.app.import.RecipeFileParser
import java.io.ByteArrayInputStream
import java.util.zip.GZIPInputStream
import java.util.zip.ZipInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Paprika export/import parity: single-recipe Paprika JSON objects
 * (uid/name/ingredients/directions/servings/categories/rating/…) wrapped as
 * one gzip member per `.paprikarecipe` inside a `.paprikarecipes` ZIP, plus
 * YAML emitted as a JSON array (valid YAML) with a `.yml` extension.
 * Pure JVM tests, no Android.
 */
class RecipeExportImportTest {

    private fun sample() = RecipeExporter.ExportableRecipe(
        id = "kc-1",
        title = "Chili",
        description = "Hearty.",
        servings = 4.0,
        prepMinutes = 75,
        cookMinutes = 30,
        rating = 5.0,
        source = "Grandma",
        sourceUrl = "https://example.com/chili",
        categories = listOf("Dinner"),
        ingredients = listOf(
            RecipeExporter.ExportableIngredient("beef", "1 lb beef"),
            RecipeExporter.ExportableIngredient("beans", "2 cups beans"),
        ),
        steps = listOf(
            RecipeExporter.ExportableStep(0, "Brown the beef."),
            RecipeExporter.ExportableStep(1, "Simmer 30 min."),
        ),
        uid = "C918EB00-71BE-4AEE-A215-96173518F7A8",
        cookbook = "Weeknights",
    )

    private fun gunzip(b: ByteArray): String {
        GZIPInputStream(ByteArrayInputStream(b)).use { return it.readBytes().toString(Charsets.UTF_8) }
    }

    @Test fun `paprika json carries uid servings times and cookbook`() {
        val json = paprikaJsonFor(sample())
        assertTrue(json.contains("C918EB00-71BE-4AEE-A215-96173518F7A8"))
        assertTrue(json.contains("\"name\":\"Chili\""))
        assertTrue(json.contains("1 lb beef\\n2 cups beans"))
        assertTrue(json.contains("\"prep_time\":\"75 minutes\""))
        assertTrue(json.contains("\"cook_time\":\"30 minutes\""))
        assertTrue(json.contains("\"cookbook\":\"Weeknights\""))
        assertTrue(json.contains("\"rating\":5"))
    }

    @Test fun `photo filename synthesized when photo data lacks one`() {
        val r = sample().copy(photoBase64 = "aGVsbG8=" + "a".repeat(120), photoFileName = null)
        val json = paprikaJsonFor(r)
        assertTrue(json.contains("\"photo\":\"C918EB00-71BE-4AEE-A215-96173518F7A8.jpg\""))
        assertTrue(json.contains("\"photo_data\""))
    }

    @Test fun `uid minted when absent`() {
        val uid = paprikaUidFor(sample().copy(uid = ""))
        // Full UUID shape: 8-4-4-4-12 uppercase hex (v3 name-based).
        assertTrue(uid.matches(Regex("[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")))
    }

    @Test fun `uid is stable per recipe id`() {
        // Re-exporting the same recipe must mint the SAME uid, or re-import
        // duplicates (server uid upsert keys on it).
        val a = paprikaUidFor(sample().copy(uid = ""))
        val b = paprikaUidFor(sample().copy(uid = ""))
        assertEquals(a, b)
        val other = paprikaUidFor(sample().copy(id = "kc-2", uid = ""))
        assertTrue(other.matches(Regex("[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")))
        assertTrue(a != other)
    }

    @Test fun `zip entry names stay unique for duplicate titles`() {
        val dupes = listOf(sample(), sample(), sample().copy(title = "CHILI!!"))
        val zipBytes = paprikaZipFor(dupes)
        val names = mutableListOf<String>()
        ZipInputStream(ByteArrayInputStream(zipBytes)).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                names += entry.name
                entry = zip.nextEntry
            }
        }
        assertEquals(3, names.size)
        assertEquals(3, names.toSet().size)
        assertTrue(names.all { it.endsWith(".paprikarecipe") })
        // Round-trips: all three members still parse.
        val parsed = RecipeFileParser.parse("lib.paprikarecipes", zipBytes)
        assertEquals(3, parsed.recipes.size)
    }

    @Test fun `zip wraps gzipped json member`() {
        val zipBytes = paprikaZipFor(listOf(sample()))
        assertEquals(0x50.toByte(), zipBytes[0])
        assertEquals(0x4B.toByte(), zipBytes[1])
        ZipInputStream(ByteArrayInputStream(zipBytes)).use { zip ->
            val entry = zip.nextEntry!!
            assertTrue(entry.name.endsWith(".paprikarecipe"))
            val member = zip.readBytes()
            assertEquals(0x1F.toByte(), member[0])
            assertEquals(0x8B.toByte(), member[1])
            val json = gunzip(member)
            assertTrue(json.contains("\"name\":\"Chili\""))
        }
    }

    @Test fun `zip round-trips through parser`() {
        val parsed = RecipeFileParser.parse("lib.paprikarecipes", paprikaZipFor(listOf(sample())))
        assertEquals(1, parsed.recipes.size)
        val r = parsed.recipes[0]
        assertEquals("Chili", r.title)
        assertEquals(listOf("1 lb beef", "2 cups beans"), r.ingredients)
        assertEquals(listOf("Brown the beef.", "Simmer 30 min."), r.steps)
        assertEquals(4.0, r.servings, 0.001)
        assertEquals(75, r.prepMinutes)
        assertEquals(5.0, r.rating!!, 0.001)
        assertEquals("C918EB00-71BE-4AEE-A215-96173518F7A8", r.paprikaUid)
        assertEquals("Weeknights", r.cookbook)
        assertTrue(parsed.warnings.isEmpty())
    }

    @Test fun `single gzip paprikarecipe parses`() {
        val parsed = RecipeFileParser.parse("one.paprikarecipe", paprikaGzip(paprikaJsonFor(sample())))
        assertEquals(1, parsed.recipes.size)
        assertEquals("Chili", parsed.recipes[0].title)
    }

    @Test fun `yaml vendor shape parses`() {
        val yaml = """
            name: My Tasty Recipe
            servings: 4-6 servings
            prep_time: 10 min
            cook_time: 1 hr 15 min
            rating: 5
            categories: [Dinner, Holiday]
            notes: |
              This is delicious!!!
            ingredients: |
              1/2 lb meat
              salt
            directions: |
              Mix things together.
              Eat.
        """.trimIndent()
        val parsed = RecipeFileParser.parse("r.yml", yaml.toByteArray())
        assertEquals(1, parsed.recipes.size)
        val r = parsed.recipes[0]
        assertEquals("My Tasty Recipe", r.title)
        assertEquals(4.0, r.servings, 0.001)
        assertEquals(10, r.prepMinutes)
        assertEquals(75, r.cookMinutes)
        assertEquals(listOf("Dinner", "Holiday"), r.categories)
        assertEquals("This is delicious!!!", r.notes)
        assertEquals(2, r.ingredients.size)
        assertEquals(2, r.steps.size)
    }

    @Test fun `yaml emission is json array and re-parses`() {
        val yml = yamlFor(sample())
        assertTrue(yml.trimStart().startsWith("["))
        val parsed = RecipeFileParser.parse("chili.yml", yml.toByteArray())
        assertEquals(1, parsed.recipes.size)
        assertEquals("Chili", parsed.recipes[0].title)
        assertEquals(2, parsed.recipes[0].ingredients.size)
    }

    @Test fun `rating zero maps to unrated`() {
        val parsed = RecipeFileParser.parse(
            "r.json",
            """{"name":"X","rating":0,"ingredients":"","directions":"Do it."}""".toByteArray(),
        )
        assertEquals(1, parsed.recipes.size)
        assertNull(parsed.recipes[0].rating)
    }

    @Test fun `p1 labeled text parses`() {
        val mmf = """
            Title: Chili
            Categories: Dinner, Spicy
            Servings: 6
            Ingredients:
            1 lb beef
            2 cups beans
            Instructions:
            Brown the beef.
            Simmer 30 min.
        """.trimIndent()
        val parsed = RecipeFileParser.parse("chili.mmf", mmf.toByteArray())
        assertEquals(1, parsed.recipes.size)
        val r = parsed.recipes[0]
        assertEquals("Chili", r.title)
        assertEquals(6.0, r.servings, 0.001)
        assertEquals(2, r.ingredients.size)
        assertEquals(2, r.steps.size)
    }

    @Test fun `unsupported file warns`() {
        val parsed = RecipeFileParser.parse("blob.xyz", "~~~not a recipe~~~".toByteArray())
        assertTrue(parsed.recipes.isEmpty())
        assertTrue(parsed.warnings.isNotEmpty())
    }

    @Test fun `photo data without filename synthesizes on parse`() {
        val json = """{"name":"P","uid":"ABC","ingredients":"x","directions":"y","photo_data":"${"b".repeat(150)}"}"""
        val parsed = RecipeFileParser.parse("p.paprikarecipe", json.toByteArray())
        assertEquals("ABC.jpg", parsed.recipes[0].photoFileName)
    }
}
