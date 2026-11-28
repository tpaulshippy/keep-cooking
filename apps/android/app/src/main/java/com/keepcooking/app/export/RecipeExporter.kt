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
        // Paprika round-trip uid: derived deterministically from the local
        // recipe id (see paprikaUidFor) since Room has no paprikaUid column.
        // Optional — existing call sites unaffected.
        val uid: String = "",
        val notes: String = "",
        val difficulty: String? = null,
        val nutritionalInfo: String = "",
        val totalMinutes: Int? = null,
        val servingsRaw: String = "",
        val created: String = "",
        val cookbook: String = "",
        val photoBase64: String? = null,
        val photoFileName: String? = null,
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
            // Stable uid: Room stores no paprikaUid, so derive it from the
            // local recipe id — re-exporting yields the same uid, and both
            // the server (uid upsert) and importParsed (title match) treat
            // re-imports as updates, not duplicates.
            uid = paprikaUidForId(recipe.id),
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

    /** JSON-LD Recipe snippet shared by single- and multi-recipe HTML docs. */
    fun jsonLdFor(r: ExportableRecipe): String {
        val steps = r.steps.sortedBy { it.position }
        return buildString {
            append("""{"@context":"https://schema.org","@type":"Recipe","name":${jsonStr(r.title)},""")
            append(""""recipeYield":${r.servings},"recipeIngredient":[${r.ingredients.joinToString(",") { jsonStr(it.text) }}],""")
            append(""""recipeInstructions":[${steps.joinToString(",") { """{"@type":"HowToStep","text":${jsonStr(it.text)}}""" } }]""")
            if (r.description.isNotEmpty()) append(""","description":${escJsonLd(jsonStr(r.description))}""")
            r.prepMinutes?.let { append(""","prepTime":"PT${it}M"""") }
            r.cookMinutes?.let { append(""","cookTime":"PT${it}M"""") }
            append("}")
        }.replace("<", "\\u003c")
    }

    fun toHtml(r: ExportableRecipe): String {
        val jsonLd = jsonLdFor(r)
        return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
            "<title>${escHtml(r.title)}</title>" +
            "<script type=\"application/ld+json\">$jsonLd</script>" +
            "<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}</style>" +
            "</head><body>${toHtmlBody(r)}</body></html>"
    }

    suspend fun exportHTML(db: AppDatabase, recipeId: String): String =
        loadRecipe(db, recipeId)?.let { toHtml(it) } ?: "<!doctype html><html><body>Not found</body></html>"

    suspend fun exportMarkdown(db: AppDatabase, recipeId: String): String = toMarkdown(db, recipeId)

    /** Single recipe → HTML article body (no document shell). */
    fun toHtmlBody(r: ExportableRecipe): String {
        val steps = r.steps.sortedBy { it.position }
        val ings = r.ingredients.joinToString("") { "<li>${escHtml(it.text)}</li>" }
        val stepsHtml = steps.joinToString("") { "<li>${escHtml(it.text)}</li>" }
        val desc = if (r.description.isEmpty()) "" else "<p>${escHtml(r.description)}</p>"
        return "<h1>${escHtml(r.title)}</h1>$desc" +
            "<p>Servings: ${escHtml(formatServings(r.servings))}</p>" +
            "<h2>Ingredients</h2><ul>$ings</ul><h2>Steps</h2><ol>$stepsHtml</ol>"
    }

    /** Multi-recipe → one HTML document, one <article> per recipe joined by <hr/>.
     *  Each article carries its own escaped JSON-LD Recipe script so imports
     *  recover every selected recipe, not just the first. */
    fun toHtmlPage(recipes: List<ExportableRecipe>): String {
        val bodies = recipes.joinToString("\n<hr/>\n") {
            "<article><script type=\"application/ld+json\">${jsonLdFor(it)}</script>${toHtmlBody(it)}</article>"
        }
        return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
            "<title>Keep Cooking export</title>" +
            "<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}</style>" +
            "</head><body><h1>Keep Cooking export</h1>$bodies</body></html>"
    }

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

    /** Writes raw bytes (e.g. Paprika ZIP) to the app cache dir for ACTION_SEND. */
    fun writeCacheBytes(format: ExportFormat, title: String, bytes: ByteArray): java.io.File {
        val file = java.io.File(context.cacheDir, fileNameFor(title, format.ext))
        file.writeBytes(bytes)
        return file
    }

    // --- Paprika (.paprikarecipes ZIP of gzipped JSON) + YAML (JSON-as-YAML) ---

    /** Single recipe → Paprika JSON string (single-recipe Paprika JSON shape). */
    fun toPaprikaJson(r: ExportableRecipe): String = paprikaJsonFor(r)

    /** Single recipe → `.paprikarecipes` ZIP bytes (one gzip member). */
    fun toPaprikaZip(r: ExportableRecipe): ByteArray = paprikaZipFor(listOf(r))

    /** Recipe list → `.paprikarecipes` ZIP bytes (one gzip member per recipe). */
    fun toPaprikaZip(recipes: List<ExportableRecipe>): ByteArray = paprikaZipFor(recipes)

    /** Single recipe → YAML text (emitted as a JSON array: valid YAML). */
    fun toYaml(r: ExportableRecipe): String = yamlFor(r)

    fun shareText(markdown: String): String = markdown // callers wrap in ACTION_SEND chooser
}

enum class ExportFormat(val ext: String, val title: String, val mime: String) {
    JSON("json", "JSON", "application/json"),
    MD("md", "Markdown", "text/markdown"),
    HTML("html", "HTML (Schema.org)", "text/html"),
    PAPRIKA("paprikarecipes", "Paprika", "application/zip"),
    YAML("yml", "YAML", "text/yaml"),
}

/**
 * Stable Paprika uid: reuse the stored one, else derive a deterministic
 * uppercase UUID from the local recipe id (v3 name-based UUID over a
 * namespaced seed). Room has no paprikaUid column, so this derivation is the
 * stability guarantee: every export of the same recipe mints the SAME uid,
 * and the server's uid upsert (api/src/import.ts runImport: same uid →
 * update in place) plus the on-device title match treat re-imports as
 * updates rather than duplicates. (A random UUID here would mint a fresh
 * identity per export and duplicate on every re-import.)
 */
fun paprikaUidFor(r: RecipeExporter.ExportableRecipe): String =
    r.uid.ifBlank { paprikaUidForId(r.id) }

/** Deterministic uid for a local recipe id (uppercased v3 UUID). */
fun paprikaUidForId(recipeId: String): String =
    java.util.UUID.nameUUIDFromBytes("keepcooking:recipe:$recipeId".toByteArray(Charsets.UTF_8))
        .toString().uppercase(java.util.Locale.US)

/** Paprika `photo` filename: keep the stored one, else synthesize `${UID}.jpg`
 * when photo bytes are present — Paprika crashes mid-import on a `photo_data`
 * with a null/absent `photo` filename. */
fun paprikaPhotoNameFor(r: RecipeExporter.ExportableRecipe, uid: String): String? =
    if (r.photoBase64.isNullOrBlank()) null
    else r.photoFileName?.ifBlank { null } ?: "$uid.jpg"

/** Human duration Paprika expects ("20 minutes"), from integer minutes. */
internal fun paprikaMinutes(m: Int?): String? = m?.let { "$it minutes" }

/**
 * Keep Cooking recipe → Paprika recipe JSON object (single-recipe Paprika
 * JSON shape: uid/name/ingredients/directions/servings/categories/rating/
 * description/notes/difficulty/nutritional_info/source/source_url/created/
 * hash + optional prep_time/cook_time/total_time/cookbook/photo). Pure function
 * (no Context) so JVM unit tests can cover it without Robolectric.
 */
fun paprikaJsonFor(r: RecipeExporter.ExportableRecipe): String {
    val uid = paprikaUidFor(r)
    val photoName = paprikaPhotoNameFor(r, uid)
    val created = r.created.ifBlank { paprikaNow() }
    val parts = mutableListOf(
        "${jsonStr("uid")}:${jsonStr(uid)}",
        "${jsonStr("name")}:${jsonStr(r.title)}",
        "${jsonStr("ingredients")}:${jsonStr(r.ingredients.joinToString("\n") { it.text })}",
        "${jsonStr("directions")}:${jsonStr(r.steps.sortedBy { it.position }.joinToString("\n") { it.text })}",
        "${jsonStr("servings")}:${jsonStr(r.servingsRaw.ifBlank { formatServings(r.servings) })}",
        "${jsonStr("categories")}:${r.categories.joinToString(prefix = "[", postfix = "]") { jsonStr(it) }}",
        "${jsonStr("rating")}:${(r.rating?.toInt()?.coerceIn(0, 5)) ?: 0}",
        "${jsonStr("description")}:${jsonStr(r.description)}",
        "${jsonStr("notes")}:${jsonStr(r.notes)}",
        "${jsonStr("difficulty")}:${r.difficulty?.let { jsonStr(it) } ?: "null"}",
        "${jsonStr("nutritional_info")}:${jsonStr(r.nutritionalInfo)}",
        "${jsonStr("source")}:${jsonStr(r.source)}",
        "${jsonStr("source_url")}:${jsonStr(r.sourceUrl)}",
        "${jsonStr("created")}:${jsonStr(created)}",
        "${jsonStr("hash")}:${jsonStr("")}",
    )
    paprikaMinutes(r.prepMinutes)?.let { parts += "${jsonStr("prep_time")}:${jsonStr(it)}" }
    paprikaMinutes(r.cookMinutes)?.let { parts += "${jsonStr("cook_time")}:${jsonStr(it)}" }
    paprikaMinutes(r.totalMinutes)?.let { parts += "${jsonStr("total_time")}:${jsonStr(it)}" }
    if (r.cookbook.isNotBlank()) parts += "${jsonStr("cookbook")}:${jsonStr(r.cookbook)}"
    if (photoName != null) {
        parts += "${jsonStr("photo")}:${jsonStr(photoName)}"
        parts += "${jsonStr("photo_data")}:${jsonStr(r.photoBase64 ?: "")}"
    }
    return "{${parts.joinToString(",")}}"
}

/** GZIP a single Paprika JSON member (`.paprikarecipe` body, magic `1F 8B`). */
fun paprikaGzip(json: String): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    java.util.zip.GZIPOutputStream(out).use { it.write(json.toByteArray(Charsets.UTF_8)) }
    return out.toByteArray()
}

/**
 * Recipes → `.paprikarecipes` ZIP bytes: one `*.paprikarecipe` gzip member per
 * recipe. Unicode titles are sanitized to filesystem-safe names; names are
 * made unique with an index suffix so two recipes with the same (or
 * same-after-sanitizing) title never collide in one archive — a duplicate
 * entry name throws `ZipException` and aborts the whole export.
 */
fun paprikaZipFor(recipes: List<RecipeExporter.ExportableRecipe>): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val used = mutableSetOf<String>()
    java.util.zip.ZipOutputStream(out).use { zip ->
        recipes.forEachIndexed { i, r ->
            val safe = r.title.lowercase().map { if (it.isLetterOrDigit()) it else '-' }
                .joinToString("").take(40).ifBlank { "recipe-${i + 1}" }
            // First recipe keeps the clean name; later collisions get -2, -3…
            var entryName = "$safe.paprikarecipe"
            var n = 2
            while (!used.add(entryName)) {
                entryName = "$safe-$n.paprikarecipe"
                n++
            }
            zip.putNextEntry(java.util.zip.ZipEntry(entryName))
            zip.write(paprikaGzip(paprikaJsonFor(r)))
            zip.closeEntry()
        }
    }
    return out.toByteArray()
}

internal fun paprikaNow(): String {
    val cal = java.util.Calendar.getInstance()
    fun p(v: Int) = v.toString().padStart(2, '0')
    return "${cal.get(java.util.Calendar.YEAR)}-${p(cal.get(java.util.Calendar.MONTH) + 1)}-" +
        "${p(cal.get(java.util.Calendar.DAY_OF_MONTH))} " +
        "${p(cal.get(java.util.Calendar.HOUR_OF_DAY))}:${p(cal.get(java.util.Calendar.MINUTE))}:${p(cal.get(java.util.Calendar.SECOND))}"
}

/**
 * Recipe → YAML text. Emission strategy: the recipe as a JSON array
 * (`[{...}]`) with a `.yml` extension — JSON is valid YAML, so this avoids
 * all pipe-block indentation risk. Photo bytes reuse `photo_data`
 * semantics under the YAML `photo` key.
 */
fun yamlFor(r: RecipeExporter.ExportableRecipe): String {
    val parts = mutableListOf(
        "${jsonStr("name")}:${jsonStr(r.title)}",
        "${jsonStr("servings")}:${jsonStr(r.servingsRaw.ifBlank { formatServings(r.servings) })}",
        "${jsonStr("source")}:${jsonStr(r.source)}",
        "${jsonStr("source_url")}:${jsonStr(r.sourceUrl)}",
        "${jsonStr("categories")}:${r.categories.joinToString(prefix = "[", postfix = "]") { jsonStr(it) }}",
        "${jsonStr("rating")}:${(r.rating?.toInt()?.coerceIn(0, 5)) ?: 0}",
        "${jsonStr("notes")}:${jsonStr(r.notes)}",
        "${jsonStr("ingredients")}:${r.ingredients.joinToString(prefix = "[", postfix = "]") { jsonStr(it.text) }}",
        "${jsonStr("directions")}:${r.steps.sortedBy { it.position }.joinToString(prefix = "[", postfix = "]") { jsonStr(it.text) }}",
    )
    r.difficulty?.let { parts += "${jsonStr("difficulty")}:${jsonStr(it)}" }
    paprikaMinutes(r.prepMinutes)?.let { parts += "${jsonStr("prep_time")}:${jsonStr(it)}" }
    paprikaMinutes(r.cookMinutes)?.let { parts += "${jsonStr("cook_time")}:${jsonStr(it)}" }
    if (r.nutritionalInfo.isNotBlank()) parts += "${jsonStr("nutritional_info")}:${jsonStr(r.nutritionalInfo)}"
    if (r.photoBase64?.isNotBlank() == true) parts += "${jsonStr("photo")}:${jsonStr(r.photoBase64)}"
    return "[{${parts.joinToString(",")}}]"
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
