package com.keepcooking.app.export

import android.content.Context
import com.keepcooking.app.data.AppDatabase
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Recipe export — parity with apps/ios/Export/RecipeExporter.swift and
 * Lane 1 `api/src/export.ts`:
 *   JSON (full recipe object) · Markdown · self-contained Schema.org HTML.
 * Transport-agnostic; callers wrap the string in ACTION_SEND or write a file.
 */
class RecipeExporter(private val context: Context) {

    data class ExportableIngredient(val name: String, val display: String) {
        val text: String get() = display.ifBlank { name }
    }

    data class ExportableStep(val position: Int, val text: String)

    data class ExportableRecipe(
        val id: String,
        val title: String,
        val description: String,
        val servings: Double,
        val prepMinutes: Int?,
        val cookMinutes: Int?,
        val rating: Double?,
        val source: String,
        val sourceUrl: String,
        val categories: List<String>,
        val ingredients: List<ExportableIngredient>,
        val steps: List<ExportableStep>,
    )

    suspend fun loadRecipe(db: AppDatabase, recipeId: String): ExportableRecipe? {
        val recipe = db.recipes().byId(recipeId) ?: return null
        val ingredients = db.ingredients().forRecipe(recipeId).sortedBy { it.position }
            .map { ExportableIngredient(it.name, it.display.ifBlank { it.name }) }
        val steps = db.steps().forRecipe(recipeId).sortedBy { it.position }
            .map { ExportableStep(it.position, it.text) }
        val categories = runCatching {
            kotlinx.serialization.json.Json.parseToJsonElement(recipe.categoriesJson)
                .jsonArray.map { it.jsonPrimitive.content }
        }.getOrDefault(emptyList())
        return ExportableRecipe(
            id = recipe.id, title = recipe.title, description = recipe.recipeDescription,
            servings = recipe.servings, prepMinutes = recipe.prepMinutes,
            cookMinutes = recipe.cookMinutes, rating = recipe.rating,
            source = recipe.source, sourceUrl = recipe.sourceUrl,
            categories = categories, ingredients = ingredients, steps = steps,
        )
    }

    // --- JSON (full-fidelity, matches GET /export/{id}.json shape) ---

    fun toJson(r: ExportableRecipe): String {
        val obj = buildJsonObject {
            put("id", r.id)
            put("title", r.title)
            put("description", r.description)
            put("servings", r.servings)
            put("categories", r.categories.joinToString(prefix = "[", postfix = "]") { "\"${it.replace("\"", "\\\"")}\"" })
            put("source", r.source)
            put("sourceUrl", r.sourceUrl)
            put("ingredients", r.ingredients.joinToString(prefix = "[", postfix = "]") {
                """{"name":${jsonStr(it.name)},"display":${jsonStr(it.text)}}"""
            })
            put("steps", r.steps.sortedBy { it.position }.mapIndexed { i, s ->
                """{"position":${s.position},"text":${jsonStr(s.text)}}"""
            }.joinToString(prefix = "[", postfix = "]"))
            r.prepMinutes?.let { put("prepMinutes", it) }
            r.cookMinutes?.let { put("cookMinutes", it) }
            r.rating?.let { put("rating", it) }
        }
        // Emit stable pretty JSON manually (keeps key order readable like iOS).
        return prettyJson(obj)
    }

    suspend fun exportJSON(db: AppDatabase, recipeId: String): String =
        loadRecipe(db, recipeId)?.let { toJson(it) } ?: "{}"

    // --- Markdown (matches Lane 1 recipeToMarkdown line-for-line style) ---

    fun toMarkdown(r: ExportableRecipe): String {
        val lines = mutableListOf("# ${r.title}", "")
        if (r.description.isNotEmpty()) { lines += r.description; lines += "" }
        lines += "Servings: ${formatServings(r.servings)}"
        if (r.prepMinutes != null || r.cookMinutes != null) {
            lines += "Time: prep ${r.prepMinutes?.toString() ?: "?"} min · cook ${r.cookMinutes?.toString() ?: "?"} min"
        }
        lines += listOf("", "## Ingredients", "")
        for (ing in r.ingredients) lines += "- ${ing.text}"
        lines += listOf("", "## Steps", "")
        r.steps.sortedBy { it.position }.forEachIndexed { i, s -> lines += "${i + 1}. ${s.text}" }
        lines += ""
        return lines.joinToString("\n")
    }

    suspend fun toMarkdown(db: AppDatabase, recipeId: String): String {
        val r = loadRecipe(db, recipeId) ?: return "# Recipe not found"
        return toMarkdown(r)
    }

    // --- HTML (self-contained Schema.org, offline-safe) ---

    fun toHtml(r: ExportableRecipe): String {
        val steps = r.steps.sortedBy { it.position }
        val jsonLd = buildString {
            append("""{"@context":"https://schema.org","@type":"Recipe","name":${jsonStr(r.title)},""")
            append(""""recipeYield":${r.servings},"recipeIngredient":[${r.ingredients.joinToString(",") { jsonStr(it.text) }}],""")
            append(""""recipeInstructions":[${steps.joinToString(",") { """{"@type":"HowToStep","text":${jsonStr(it.text)}}""" } }]""")
            if (r.description.isNotEmpty()) append(""","description":${escJsonLd(jsonStr(r.description))}""")
            r.prepMinutes?.let { append(""","prepTime":"PT${it}M"""") }
            r.cookMinutes?.let { append(""","cookTime":"PT${it}M"""") }
            append("}")
        }.replace("<", "\\u003c")
        val ings = r.ingredients.joinToString("") { "<li>${escHtml(it.text)}</li>" }
        val stepsHtml = steps.joinToString("") { "<li>${escHtml(it.text)}</li>" }
        val desc = if (r.description.isEmpty()) "" else "<p>${escHtml(r.description)}</p>"
        return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
            "<title>${escHtml(r.title)}</title>" +
            "<script type=\"application/ld+json\">$jsonLd</script>" +
            "<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}</style>" +
            "</head><body><h1>${escHtml(r.title)}</h1>$desc" +
            "<p>Servings: ${escHtml(formatServings(r.servings))}</p>" +
            "<h2>Ingredients</h2><ul>$ings</ul><h2>Steps</h2><ol>$stepsHtml</ol></body></html>"
    }

    suspend fun exportHTML(db: AppDatabase, recipeId: String): String =
        loadRecipe(db, recipeId)?.let { toHtml(it) } ?: "<!doctype html><html><body>Not found</body></html>"

    suspend fun exportMarkdown(db: AppDatabase, recipeId: String): String = toMarkdown(db, recipeId)

    /** Stable filename for a recipe export (mirrors iOS writeTempFile). */
    fun fileNameFor(title: String, ext: String): String {
        val safe = title.lowercase().map { if (it.isLetterOrDigit()) it else '-' }.joinToString("").take(40)
        return "keep-cooking-$safe.$ext"
    }

    /** Writes the export to the app cache dir and returns the file (for ACTION_SEND). */
    fun writeCacheFile(format: ExportFormat, title: String, text: String): java.io.File {
        val file = java.io.File(context.cacheDir, fileNameFor(title, format.ext))
        file.writeText(text, Charsets.UTF_8)
        return file
    }

    fun shareText(markdown: String): String = markdown // callers wrap in ACTION_SEND chooser
}

enum class ExportFormat(val ext: String, val title: String, val mime: String) {
    JSON("json", "JSON", "application/json"),
    MD("md", "Markdown", "text/markdown"),
    HTML("html", "HTML (Schema.org)", "text/html"),
}

internal fun formatServings(s: Double): String =
    if (s % 1.0 == 0.0) s.toInt().toString() else s.toString()

internal fun escHtml(s: String): String =
    s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

internal fun escJsonLd(s: String): String = s // already JSON-quoted; `<` escaped at document level

internal fun jsonStr(s: String): String = buildString {
    append('"')
    for (c in s) {
        when (c) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (c < ' ') append("\\u%04x".format(c.code)) else append(c)
        }
    }
    append('"')
}

private fun prettyJson(obj: JsonObject): String = buildString {
    append("{\n")
    val entries = obj.entries.toList()
    entries.forEachIndexed { i, (k, v) ->
        append("  ${jsonStr(k)}: ${v.toString().trim()}")
        if (i < entries.size - 1) append(",")
        append("\n")
    }
    append("}")
}
