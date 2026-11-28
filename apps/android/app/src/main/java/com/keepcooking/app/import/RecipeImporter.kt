package com.keepcooking.app.import

import com.keepcooking.app.data.AppDatabase
import com.keepcooking.app.data.IngredientEntity
import com.keepcooking.app.data.MenuEntity
import com.keepcooking.app.data.RecipeEntity
import com.keepcooking.app.data.StepEntity
import com.keepcooking.app.network.SyncEnvelopeDto
import java.io.ByteArrayInputStream
import java.util.UUID
import java.util.zip.GZIPInputStream
import java.util.zip.ZipInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * File import — Paprika native (`.paprikarecipe`/`.paprikarecipes`), Paprika
 * YAML (`.yml`/`.yaml`, including JSON-as-YAML), plus best-effort P1
 * third-party formats Paprika itself imports (see
 * packages/contracts/openapi.yaml `POST /import` format enum and
 * api/src/import.ts: MX2/MXP/MZ2, MMF, FDX/FDXZ, Pepperplate ZIP, Copy Me That
 * ZIP, Yum XML, My CookBook MCB, Recipe Manager TXT).
 *
 * Parsing is pure (no Android APIs) so it runs in JVM unit tests and works
 * fully offline. The UI calls [importParsed] to upsert into Room.
 */

data class ParsedRecipe(
    val title: String,
    val description: String = "",
    val servings: Double = 4.0,
    val servingsRaw: String = "",
    val prepMinutes: Int? = null,
    val cookMinutes: Int? = null,
    val totalMinutes: Int? = null,
    val rating: Double? = null,
    val source: String = "",
    val sourceUrl: String = "",
    val categories: List<String> = emptyList(),
    val ingredients: List<String> = emptyList(),
    val steps: List<String> = emptyList(),
    val notes: String = "",
    val difficulty: String? = null,
    val nutritionalInfo: String = "",
    val paprikaUid: String = "",
    val cookbook: String = "",
    val photoBase64: String? = null,
    val photoFileName: String? = null,
)

data class ParsedFile(
    val recipes: List<ParsedRecipe> = emptyList(),
    val cookbooks: List<String> = emptyList(),
    val warnings: List<String> = emptyList(),
)

data class ImportResult(
    val imported: Int = 0,
    val updated: Int = 0,
    val warnings: List<String> = emptyList(),
)

private val lenientJson = Json { ignoreUnknownKeys = true; isLenient = true }

// P1 extensions Paprika imports (spec §4 table), accepted alongside the P0 set.
val P1_EXTENSIONS: Set<String> = setOf(
    "mx2", "mxp", "mz2", "mmf", "mm", "txt",
    "fdx", "fdxz", "zip", "db", "xml",
    "mcb", "hcb", "sqlite", "rbox", "mgourmet", "mgourmet3", "mgourmet4",
    "dvo", "ysr",
)
val IMPORT_EXTENSIONS: Set<String> = setOf(
    "paprikarecipe", "paprikarecipes", "yml", "yaml", "json", "md", "html", "htm",
) + P1_EXTENSIONS

object RecipeFileParser {

    fun parse(fileName: String, bytes: ByteArray): ParsedFile {
        val warnings = mutableListOf<String>()
        val ext = fileName.substringAfterLast('.', "").lowercase()
        if (bytes.isEmpty()) return ParsedFile(warnings = listOf("“$fileName” is empty."))
        return try {
            when {
                isZip(bytes) || ext in setOf("paprikarecipes", "mz2", "mcb", "zip") ->
                    parseZip(fileName, bytes, warnings)
                isGzip(bytes) || ext in setOf("paprikarecipe", "fdxz") ->
                    parseGzipMembers(fileName, bytes, warnings)
                else -> parsePlainText(fileName, ext, bytes.toString(Charsets.UTF_8), warnings)
            }
        } catch (e: Exception) {
            ParsedFile(warnings = warnings + "Could not read “$fileName”: ${e.message ?: "unknown error"}.")
        }
    }

    // --- containers ---

    private fun isZip(b: ByteArray) = b.size > 4 && b[0] == 0x50.toByte() && b[1] == 0x4B.toByte()
    private fun isGzip(b: ByteArray) = b.size > 2 && b[0] == 0x1F.toByte() && b[1] == 0x8B.toByte()

    private fun parseZip(fileName: String, bytes: ByteArray, warnings: MutableList<String>): ParsedFile {
        val recipes = mutableListOf<ParsedRecipe>()
        var entries = 0
        ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                if (!entry.isDirectory) {
                    entries++
                    val data = zip.readBytes()
                    val name = entry.name
                    val ext = name.substringAfterLast('.', "").lowercase()
                    // Paprika sometimes emits plain-JSON members: try gunzip,
                    // fall back to raw UTF-8 (spec §1.1).
                    val text = if (isGzip(data)) gunzipToString(data) else data.toString(Charsets.UTF_8)
                    val sub = parsePlainText(name, ext, text, warnings)
                    recipes += sub.recipes
                    warnings += sub.warnings
                    if (sub.recipes.isEmpty() && !isImageName(name)) {
                        warnings += "Skipped unrecognized entry “$name”."
                    }
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
        if (entries == 0) warnings += "“$fileName” contained no files."
        if (recipes.isEmpty() && warnings.none { it.startsWith("Skipped") }) {
            warnings += "No recipes found in “$fileName”."
        }
        return ParsedFile(recipes, warnings = warnings)
    }

    private fun isImageName(name: String): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext in setOf("jpg", "jpeg", "png", "webp", "gif")
    }

    private fun parseGzipMembers(fileName: String, bytes: ByteArray, warnings: MutableList<String>): ParsedFile {
        // Split concatenated gzip members (spec §1.1 legacy variant), try each.
        val members = splitGzipMembers(bytes)
        val recipes = mutableListOf<ParsedRecipe>()
        for (m in members) {
            val text = runCatching { gunzipToString(m) }.getOrNull()
            if (text != null) {
                val sub = parsePlainText(fileName, "json", text, warnings)
                recipes += sub.recipes
            } else {
                // Defensive: Paprika tooling sometimes re-exports decompressed
                // bare JSON under a .paprikarecipe name (spec §1.1).
                val sub = parsePlainText(fileName, "json", m.toString(Charsets.UTF_8), warnings)
                recipes += sub.recipes
            }
        }
        if (recipes.isEmpty()) {
            // Maybe a bare .fdxz XML payload rather than Paprika JSON.
            val text = runCatching { gunzipToString(bytes) }.getOrNull().orEmpty()
            if (text.trimStart().startsWith("<")) {
                return parsePlainText(fileName, "fdx", text, warnings)
            }
            warnings += "No recipes found in “$fileName”."
        }
        return ParsedFile(recipes, warnings = warnings)
    }

    private fun gunzipToString(data: ByteArray): String {
        GZIPInputStream(ByteArrayInputStream(data)).use { gz ->
            return gz.readBytes().toString(Charsets.UTF_8)
        }
    }

    private fun splitGzipMembers(bytes: ByteArray): List<ByteArray> {
        val starts = mutableListOf<Int>()
        var i = 0
        while (i + 2 < bytes.size) {
            if (bytes[i] == 0x1F.toByte() && bytes[i + 1] == 0x8B.toByte() && bytes[i + 2] == 0x08.toByte()) {
                starts += i
                i += 3
            } else i++
        }
        if (starts.isEmpty()) return listOf(bytes)
        return starts.mapIndexed { idx, s ->
            bytes.copyOfRange(s, if (idx + 1 < starts.size) starts[idx + 1] else bytes.size)
        }
    }

    // --- plain text dispatch ---

    private fun parsePlainText(
        fileName: String,
        ext: String,
        text: String,
        warnings: MutableList<String>,
    ): ParsedFile {
        val trimmed = text.trimStart()
        // 1. JSON (native Paprika object, Keep Cooking object, or array of either;
        //    JSON is also valid YAML so this covers JSON-as-YAML emission).
        if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
            val el = runCatching { lenientJson.parseToJsonElement(trimmed) }.getOrNull()
            if (el != null) return jsonToParsed(fileName, el, warnings)
            warnings += "“$fileName” looks like JSON but failed to parse."
        }
        // 2. YAML vendor shape (spec §2) — only for yml/yaml or paprika-ish text.
        if (ext in setOf("yml", "yaml") || looksLikeYaml(trimmed)) {
            val yaml = parseYamlText(trimmed, warnings)
            if (yaml.recipes.isNotEmpty()) return yaml
        }
        // 3. XML family: FDX / Yum / My CookBook inner XML (lenient tag scrape).
        if (trimmed.startsWith("<")) return ParsedFile(listOfNotNull(parseXmlRecipe(fileName, text, warnings)))
        // 4. HTML export: prefer embedded JSON-LD, fall back to headings.
        if (ext in setOf("html", "htm") || trimmed.contains("<html", ignoreCase = true)) {
            return ParsedFile(listOfNotNull(parseHtmlRecipe(fileName, text, warnings)))
        }
        // 5. P1 labeled/columnar text: MMF / MXP / Pepperplate TXT / Recipe Manager.
        val p1 = parseLabeledText(fileName, text)
        if (p1 != null) return ParsedFile(listOf(p1))
        warnings += "“$fileName” is not a recognized recipe format."
        return ParsedFile(warnings = warnings.toList())
    }

    private fun looksLikeYaml(t: String): Boolean =
        t.lines().take(20).any { it.matches(Regex("""(name|servings|ingredients|directions)\s*:.*""")) }

    // --- JSON → ParsedRecipe (Paprika keys per spec §1.2, KC keys as fallback) ---

    internal fun jsonToParsed(fileName: String, el: JsonElement, warnings: MutableList<String>): ParsedFile {
        val objs = when (el) {
            is JsonArray -> el.mapNotNull { it as? JsonObject }
            is JsonObject -> listOf(el)
            else -> emptyList()
        }
        if (objs.isEmpty()) {
            warnings += "“$fileName” contained no recipe objects."
            return ParsedFile(warnings = warnings.toList())
        }
        return ParsedFile(objs.map { jsonObjectToRecipe(it) }, warnings = warnings.toList())
    }

    private fun JsonObject.str(vararg keys: String): String {
        for (k in keys) {
            (this[k] as? JsonPrimitive)?.contentOrNull?.let { return it }
        }
        return ""
    }

    private fun jsonObjectToRecipe(o: JsonObject): ParsedRecipe {
        val title = o.str("name", "title").ifBlank { "Untitled recipe" }
        // ingredients: Paprika "\n"-string, KC [{display}], or YAML [lines].
        val ingLines: List<String> = when (val v = o["ingredients"]) {
            is JsonPrimitive -> v.contentOrNull?.split("\n")?.map { it.trim() }
                ?.filter { it.isNotEmpty() }.orEmpty()
            is JsonArray -> v.mapNotNull { item ->
                when (item) {
                    is JsonPrimitive -> item.contentOrNull?.trim()?.ifBlank { null }
                    is JsonObject -> (item["display"] as? JsonPrimitive)?.contentOrNull
                        ?: (item["name"] as? JsonPrimitive)?.contentOrNull
                    else -> null
                }
            }
            else -> emptyList()
        }
        // directions: Paprika "\n"-string (split on blank lines first, else lines),
        // KC [{text}], or YAML [lines].
        val dirRaw = (o["directions"] as? JsonPrimitive)?.contentOrNull
        val stepLines: List<String> = when {
            dirRaw != null -> splitDirections(dirRaw)
            o["steps"] is JsonArray -> (o["steps"] as JsonArray).mapNotNull { item ->
                when (item) {
                    is JsonPrimitive -> item.contentOrNull?.trim()?.ifBlank { null }
                    is JsonObject -> (item["text"] as? JsonPrimitive)?.contentOrNull
                    else -> null
                }
            }
            else -> emptyList()
        }
        val servingsRaw = o.str("servings")
        val ratingInt = (o["rating"] as? JsonPrimitive)?.intOrNull
        val photoData = (o["photo_data"] as? JsonPrimitive)?.contentOrNull
            ?: (o["photo"] as? JsonPrimitive)?.contentOrNull?.takeIf { looksLikeBase64(it) }
        val photoName = (o["photo"] as? JsonPrimitive)?.contentOrNull
            ?.takeIf { !looksLikeBase64(it) }
        val uid = o.str("uid")
        val photoFile = when {
            photoData.isNullOrBlank() -> null
            !photoName.isNullOrBlank() -> photoName
            // Synthesize — Paprika crashes on photo_data without a filename (spec §1.2 #19).
            else -> "${uid.ifBlank { UUID.randomUUID().toString().uppercase() }}.jpg"
        }
        val cats: List<String> = when (val v = o["categories"]) {
            is JsonArray -> v.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            is JsonPrimitive -> v.contentOrNull?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
            else -> emptyList()
        }
        return ParsedRecipe(
            title = title,
            description = o.str("description"),
            servings = parseServings(servingsRaw),
            servingsRaw = servingsRaw,
            prepMinutes = parseMinutes(o.str("prep_time")),
            cookMinutes = parseMinutes(o.str("cook_time")),
            totalMinutes = parseMinutes(o.str("total_time")),
            rating = if (ratingInt == null || ratingInt == 0) null else ratingInt.coerceIn(0, 5).toDouble(),
            source = o.str("source"),
            sourceUrl = o.str("source_url", "sourceUrl"),
            categories = cats,
            ingredients = ingLines,
            steps = stepLines,
            notes = o.str("notes"),
            difficulty = o.str("difficulty").ifBlank { null },
            nutritionalInfo = o.str("nutritional_info"),
            paprikaUid = uid,
            cookbook = o.str("cookbook"),
            photoBase64 = photoData?.replace("\\/", "/")?.trim()?.ifBlank { null },
            photoFileName = photoFile,
        )
    }

    private fun looksLikeBase64(s: String): Boolean {
        val t = s.trim().replace("\\/", "/")
        return t.length > 100 && t.all { it.isLetterOrDigit() || it in "+/=\n\r" }
    }

    internal fun splitDirections(raw: String): List<String> {
        val paras = raw.split(Regex("""\n\s*\n""")).map { it.trim() }.filter { it.isNotEmpty() }
        val chunks = if (paras.size > 1) paras else raw.lines().map { it.trim() }.filter { it.isNotEmpty() }
        return chunks.map { it.replace(Regex("""^\d+[.)]\s+"""), "") }
    }

    internal fun parseServings(raw: String): Double {
        if (raw.isBlank()) return 4.0
        // Leading number, fraction, or range ("4-6 servings" → 4, "1/2 pie" → 0.5, "1 pie" → 1).
        val head = raw.trim().split(Regex("""\s+""")).firstOrNull().orEmpty()
        val range = head.split("-")
        val first = range.firstOrNull().orEmpty()
        parseQuantity(first)?.let { return it }
        if (range.size == 2) parseQuantity(range[0])?.let { return it }
        return 4.0
    }

    private fun parseQuantity(s: String): Double? {
        val t = s.trim()
        t.toDoubleOrNull()?.let { return it }
        // fraction "1/2" or mixed "1 1/2"
        val mixed = t.split(" ")
        if (mixed.size == 2) {
            val whole = mixed[0].toDoubleOrNull()
            val frac = parseFraction(mixed[1])
            if (whole != null && frac != null) return whole + frac
        }
        return parseFraction(t)
    }

    private fun parseFraction(s: String): Double? {
        val parts = s.split("/")
        if (parts.size != 2) return null
        val n = parts[0].toDoubleOrNull() ?: return null
        val d = parts[1].toDoubleOrNull() ?: return null
        if (d == 0.0) return null
        return n / d
    }

    internal fun parseMinutes(raw: String): Int? {
        if (raw.isBlank()) return null
        raw.toIntOrNull()?.let { return it }
        var total = 0
        var found = false
        // "1 hr 15 min", "90 min", "2 hours", "45m"
        val re = Regex("""(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m)\b""", RegexOption.IGNORE_CASE)
        for (m in re.findAll(raw)) {
            val n = m.groupValues[1].toInt()
            total += if (m.groupValues[2].lowercase().startsWith("h")) n * 60 else n
            found = true
        }
        // "1:30" → 90
        if (!found) {
            val hm = Regex("""(\d+):(\d{1,2})""").find(raw)
            if (hm != null) return hm.groupValues[1].toInt() * 60 + hm.groupValues[2].toInt()
        }
        return if (found) total else null
    }

    // --- minimal YAML parser (vendor 15-field shape, single or list) ---

    private fun parseYamlText(text: String, warnings: MutableList<String>): ParsedFile {
        return try {
            val docs = splitYamlDocs(text)
            val recipes = docs.mapNotNull { yamlMapToRecipe(it) }
            if (recipes.isEmpty()) ParsedFile(warnings = warnings.toList())
            else ParsedFile(recipes, warnings = warnings.toList())
        } catch (e: Exception) {
            warnings += "YAML parse failed: ${e.message}."
            ParsedFile(warnings = warnings.toList())
        }
    }

    /** Split a (possibly multi-recipe `- name:` list) YAML doc into field maps. */
    private fun splitYamlDocs(text: String): List<Map<String, String>> {
        val lines = text.lines()
        val docs = mutableListOf<MutableMap<String, String>>()
        var current: MutableMap<String, String>? = null
        var blockKey: String? = null
        val block = StringBuilder()
        fun flushBlock() {
            if (blockKey != null && current != null && block.isNotEmpty()) {
                current!![blockKey!!] = block.toString().trimEnd('\n')
                block.clear()
            }
            blockKey = null
        }
        for (raw in lines) {
            val line = raw.trimEnd()
            if (line.trim().startsWith("#") || line.isBlank() && blockKey == null) continue
            val itemMatch = Regex("""^-\s+(\w+)\s*:\s*(.*)$""").find(line.trimStart())
            if (itemMatch != null) {
                flushBlock()
                current = mutableMapOf()
                docs += current!!
                val (k, v) = itemMatch.destructured
                if (v == "|" || v == ">") blockKey = k else current!![k] = unquoteYaml(v.trim())
                continue
            }
            if (current == null) {
                current = mutableMapOf()
                docs += current!!
            }
            if (blockKey != null) {
                if (line.startsWith(" ") || line.startsWith("\t") || line.isBlank()) {
                    block.append(line.trim()).append("\n")
                    continue
                } else flushBlock()
            }
            val kv = Regex("""^(\w+)\s*:\s*(.*)$""").find(line.trim())
            if (kv != null) {
                val (k, v) = kv.destructured
                if (v.trim() == "|" || v.trim() == ">") {
                    flushBlock()
                    blockKey = k
                } else current!![k] = unquoteYaml(v.trim())
            } else if (line.isNotBlank() && current!!.isEmpty()) {
                // Continuation of nothing recognizable — ignore.
            }
        }
        flushBlock()
        return docs.filter { it.isNotEmpty() }
    }

    private fun unquoteYaml(v: String): String {
        if (v.length >= 2 && ((v.startsWith("\"") && v.endsWith("\"")) || (v.startsWith("'") && v.endsWith("'")))) {
            return v.substring(1, v.length - 1)
        }
        return v
    }

    private fun yamlMapToRecipe(m: Map<String, String>): ParsedRecipe? {
        val name = m["name"] ?: return null
        // YAML ingredients/directions are pipe blocks (one item per line) or inline [a, b].
        fun lines(key: String): List<String> {
            val v = m[key] ?: return emptyList()
            return if (v.trimStart().startsWith("[")) {
                v.trim().removePrefix("[").removeSuffix("]")
                    .split(",").map { unquoteYaml(it.trim()) }.filter { it.isNotEmpty() }
            } else splitDirections(v)
        }
        val servingsRaw = m["servings"].orEmpty()
        val ratingInt = m["rating"]?.toIntOrNull()
        val photo = m["photo"]?.takeIf { looksLikeBase64(it) }
        return ParsedRecipe(
            title = name,
            servings = parseServings(servingsRaw),
            servingsRaw = servingsRaw,
            prepMinutes = m["prep_time"]?.let { parseMinutes(it) },
            cookMinutes = m["cook_time"]?.let { parseMinutes(it) },
            rating = if (ratingInt == null || ratingInt == 0) null else ratingInt.coerceIn(0, 5).toDouble(),
            source = m["source"].orEmpty(),
            sourceUrl = m["source_url"].orEmpty(),
            categories = m["categories"]?.let { inlineList(it) }.orEmpty(),
            ingredients = lines("ingredients"),
            steps = lines("directions"),
            notes = m["notes"].orEmpty(),
            difficulty = m["difficulty"]?.ifBlank { null },
            nutritionalInfo = m["nutritional_info"].orEmpty(),
            photoBase64 = photo?.replace("\\/", "/"),
            photoFileName = photo?.let { "${UUID.randomUUID()}.jpg" },
        )
    }

    private fun inlineList(v: String): List<String> {
        val t = v.trim()
        if (t.startsWith("[")) {
            return t.removePrefix("[").removeSuffix("]").split(",")
                .map { unquoteYaml(it.trim()) }.filter { it.isNotEmpty() }
        }
        return t.split(",").map { it.trim() }.filter { it.isNotEmpty() }
    }

    // --- P1 best-effort: XML family ---

    private fun parseXmlRecipe(fileName: String, text: String, warnings: MutableList<String>): ParsedRecipe? {
        fun tag(name: String): String {
            // Lenient: first <name>…</name>, attributes tolerated, CDATA unwrapped.
            val m = Regex("""<$name\b[^>]*>(.*?)</$name>""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE))
                .find(text) ?: return ""
            return m.groupValues[1].replace(Regex("""<!\[CDATA\[(.*?)]]>""", RegexOption.DOT_MATCHES_ALL), "$1").trim()
        }
        fun tags(name: String): List<String> =
            Regex("""<$name\b[^>]*>(.*?)</$name>""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE))
                .findAll(text).map {
                    it.groupValues[1].replace(Regex("""<!\[CDATA\[(.*?)]]>""", RegexOption.DOT_MATCHES_ALL), "$1").trim()
                }.filter { it.isNotEmpty() }.toList()
        val title = tag("title").ifBlank { tag("name") }
        if (title.isBlank()) {
            warnings += "“$fileName”: XML has no <title>/<name>; skipped."
            return null
        }
        warnings += "“$fileName”: XML import is best-effort (FDX/Yum/Cookmate shape)."
        val ingredients = tags("ingredient").ifEmpty { tags("ing") }.ifEmpty { tags("li") }
        val steps = tags("recipetext").ifEmpty { tags("procedure") }.ifEmpty { tags("step") }
            .flatMap { splitDirections(it) }
        return ParsedRecipe(
            title = title,
            description = tag("description"),
            servings = parseServings(tag("quantity").ifBlank { tag("yield").ifBlank { tag("servings") } }),
            prepMinutes = parseMinutes(tag("preptime")),
            cookMinutes = parseMinutes(tag("cooktime")),
            totalMinutes = parseMinutes(tag("totaltime")),
            source = tag("source"),
            sourceUrl = tag("url"),
            categories = tags("category"),
            ingredients = ingredients,
            steps = steps,
            notes = tag("comments"),
            nutritionalInfo = tag("nutrition"),
            rating = tag("rating").toDoubleOrNull(),
        )
    }

    // --- P1 best-effort: HTML (JSON-LD → headings) ---

    private fun parseHtmlRecipe(fileName: String, text: String, warnings: MutableList<String>): ParsedRecipe? {
        // 1. schema.org JSON-LD Recipe block.
        val ld = Regex(
            """<script[^>]*application/ld\+json[^>]*>(.*?)</script>""",
            setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE),
        ).findAll(text).mapNotNull { runCatching { lenientJson.parseToJsonElement(it.groupValues[1]) }.getOrNull() }
            .firstOrNull { (it as? JsonObject)?.let { o -> o["@type"] == JsonPrimitive("Recipe") } == true }
            as? JsonObject
        if (ld != null) {
            warnings += "“$fileName”: imported from embedded recipe metadata."
            val ings = (ld["recipeIngredient"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
            val instr = when (val v = ld["recipeInstructions"]) {
                is JsonArray -> v.mapNotNull {
                    when (it) {
                        is JsonPrimitive -> it.contentOrNull
                        is JsonObject -> (it["text"] as? JsonPrimitive)?.contentOrNull
                        else -> null
                    }
                }
                is JsonPrimitive -> splitDirections(v.contentOrNull.orEmpty())
                else -> emptyList()
            }
            return ParsedRecipe(
                title = (ld["name"] as? JsonPrimitive)?.contentOrNull ?: fileName.substringBeforeLast('.'),
                description = (ld["description"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
                servings = parseServings((ld["recipeYield"] as? JsonPrimitive)?.contentOrNull.orEmpty()),
                ingredients = ings,
                steps = instr,
            )
        }
        // 2. Visible headings fallback.
        fun section(headings: List<String>): List<String> {
            for (h in headings) {
                val m = Regex(
                    """<h[1-4][^>]*>\s*$h.*?</h[1-4]>(.*?)(<h[1-4]|$)""",
                    setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE),
                ).find(text) ?: continue
                val items = Regex("""<li[^>]*>(.*?)</li>""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE))
                    .findAll(m.groupValues[1]).map { stripTags(it.groupValues[1]) }
                    .filter { it.isNotEmpty() }.toList()
                if (items.isNotEmpty()) return items
                val body = stripTags(m.groupValues[1]).lines().map { it.trim() }
                    .filter { it.isNotEmpty() }
                if (body.isNotEmpty()) return body
            }
            return emptyList()
        }
        val title = Regex("""<h1[^>]*>(.*?)</h1>""", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE))
            .find(text)?.let { stripTags(it.groupValues[1]) }.orEmpty()
            .ifBlank { fileName.substringBeforeLast('.') }
        val ings = section(listOf("Ingredients"))
        val steps = section(listOf("Directions", "Instructions", "Steps", "Method"))
        if (ings.isEmpty() && steps.isEmpty()) {
            warnings += "“$fileName”: no recipe sections found."
            return null
        }
        warnings += "“$fileName”: imported from visible headings (best-effort)."
        return ParsedRecipe(title = title, ingredients = ings, steps = steps)
    }

    private fun stripTags(s: String): String =
        s.replace(Regex("""<[^>]+>"""), "").replace("&amp;", "&").replace("&lt;", "<")
            .replace("&gt;", ">").replace("&quot;", "\"").trim()

    // --- P1 best-effort: labeled/columnar text (MMF / MXP / Pepperplate / Recipe Manager) ---

    private fun parseLabeledText(fileName: String, text: String): ParsedRecipe? {
        fun field(vararg names: String): String {
            for (n in names) {
                Regex("""(?im)^\s*$n\s*:\s*(.+)$""").find(text)?.let { return it.groupValues[1].trim() }
            }
            return ""
        }
        val title = field("Title", "Name", "Recipe")
            .ifBlank {
                // MealMaster header fallback: first non-decorative line.
                text.lines().map { it.trim() }
                    .firstOrNull { it.isNotEmpty() && !it.startsWith("M") && !it.startsWith("-") }
                    .orEmpty()
            }
            .ifBlank { fileName.substringBeforeLast('.') }
        val ings = sectionLines(text, listOf("Ingredients", "INGREDIENTS"))
        val steps = sectionLines(text, listOf("Instructions", "Directions", "Procedure", "Steps", "Method", "DIRECTIONS"))
        if (ings.isEmpty() && steps.isEmpty()) return null
        val servingsRaw = field("Servings", "Yield")
        return ParsedRecipe(
            title = title,
            servings = parseServings(servingsRaw),
            servingsRaw = servingsRaw,
            source = field("Source"),
            sourceUrl = field("Source URL", "URL"),
            categories = field("Categories").split(",").map { it.trim() }.filter { it.isNotEmpty() },
            ingredients = ings,
            steps = steps.flatMap { splitDirections(it) },
            notes = field("Notes", "Note"),
        )
    }

    /** Lines between a section heading and the next heading/blank-break/trailer. */
    private fun sectionLines(text: String, headings: List<String>): List<String> {
        val lines = text.lines()
        for (h in headings) {
            val start = lines.indexOfFirst { it.trim().equals(h, ignoreCase = true) || it.trim().startsWith(h, ignoreCase = true) && it.trim().length < h.length + 3 }
            if (start < 0) continue
            val out = mutableListOf<String>()
            for (i in start + 1 until lines.size) {
                val t = lines[i].trim()
                if (t.isEmpty()) {
                    if (out.isNotEmpty()) break else continue
                }
                if (t.startsWith("-----") || t.startsWith("MMMMM")) break
                if (t.endsWith(":") && t.length < 40 && !t.startsWith("-")) break
                // MealMaster continuation: "-…" appends to previous line.
                if ((t.startsWith("-") || t.startsWith(";")) && out.isNotEmpty()) {
                    out[out.lastIndex] = out.last() + " " + t.drop(1).trim()
                } else out += t.trimStart('-', ' ', '*', '•')
            }
            if (out.isNotEmpty()) return out
        }
        return emptyList()
    }
}

/**
 * Upserts parsed recipes into Room with title-based uid idempotency (update in
 * place when a live recipe with the same normalized title exists, else create),
 * mirroring Paprika's uid re-import = update behavior (spec §1.3) without a
 * schema migration for a stored paprikaUid column.
 *
 * @param targetCookbook menu/cookbook name to tag onto every recipe (folded
 *   into categories, per the Menu-or-categories fallback in spec §1.3).
 * @param importCookbooks when true, distinct `cookbook` values in the file
 *   create Menu rows (if missing) and are likewise folded into categories.
 * @param enqueue sync-outbox sink (SyncEngine::enqueue); null skips sync.
 */
suspend fun importParsed(
    db: AppDatabase,
    deviceId: String,
    parsed: ParsedFile,
    targetCookbook: String?,
    importCookbooks: Boolean,
    enqueue: (suspend (SyncEnvelopeDto) -> Unit)? = null,
): ImportResult {
    val warnings = parsed.warnings.toMutableList()
    var imported = 0
    var updated = 0
    val now = System.currentTimeMillis()
    val live = db.recipes().liveRecipes()
    val byTitle = live.associateBy { it.title.lowercase().trim() }
    val cookbooks = (parsed.cookbooks + parsed.recipes.mapNotNull { it.cookbook.ifBlank { null } })
        .map { it.trim() }.filter { it.isNotEmpty() }.distinct()
    if (importCookbooks) {
        val existingMenus = db.menus().liveMenus().map { it.name.lowercase() }.toSet()
        for (cb in cookbooks) {
            if (cb.lowercase() !in existingMenus) {
                val id = UUID.randomUUID().toString()
                db.menus().upsertAll(
                    listOf(
                        MenuEntity(
                            id = id, householdId = "hh-demo", name = cb,
                            updatedAt = now, deviceId = deviceId,
                        ),
                    ),
                )
            }
        }
    } else if (cookbooks.isNotEmpty()) {
        warnings += "File lists cookbook(s) ${cookbooks.joinToString()}; enable “Import cookbooks” to create them."
    }
    for (r in parsed.recipes) {
        if (r.title.isBlank()) {
            warnings += "Skipped a recipe with no title."
            continue
        }
        val tags = (r.categories + listOfNotNull(targetCookbook?.ifBlank { null }) +
            if (importCookbooks) listOfNotNull(r.cookbook.ifBlank { null }) else emptyList())
            .map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        val existing = byTitle[r.title.lowercase().trim()]
        val recipeId = existing?.id ?: UUID.randomUUID().toString()
        db.recipes().upsert(
            RecipeEntity(
                id = recipeId,
                householdId = existing?.householdId ?: "hh-demo",
                title = r.title,
                recipeDescription = if (r.description.isNotBlank()) r.description
                else if (r.notes.isNotBlank()) r.notes else existing?.recipeDescription.orEmpty(),
                servings = r.servings,
                prepMinutes = r.prepMinutes ?: existing?.prepMinutes,
                cookMinutes = r.cookMinutes ?: existing?.cookMinutes,
                rating = r.rating ?: existing?.rating,
                source = r.source.ifBlank { existing?.source.orEmpty() },
                sourceUrl = r.sourceUrl.ifBlank { existing?.sourceUrl.orEmpty() },
                categoriesJson = JsonArray(tags.map { JsonPrimitive(it) }).toString(),
                nutritionText = r.nutritionalInfo.ifBlank { existing?.nutritionText.orEmpty() },
                updatedAt = now,
                deviceId = deviceId,
            ),
        )
        if (existing != null) {
            db.ingredients().deleteForRecipe(recipeId)
            db.steps().deleteForRecipe(recipeId)
            updated++
        } else imported++
        db.ingredients().upsertAll(
            r.ingredients.mapIndexed { i, line ->
                IngredientEntity(
                    id = UUID.randomUUID().toString(), recipeId = recipeId,
                    name = line, display = line, position = i,
                    updatedAt = now, deviceId = deviceId,
                )
            },
        )
        db.steps().upsertAll(
            r.steps.mapIndexed { i, line ->
                StepEntity(
                    id = UUID.randomUUID().toString(), recipeId = recipeId,
                    position = i, text = line, updatedAt = now, deviceId = deviceId,
                )
            },
        )
        enqueue?.let { send ->
            runCatching {
                send(
                    SyncEnvelopeDto(
                        id = recipeId,
                        updatedAt = java.time.Instant.ofEpochMilli(now).toString(),
                        deviceId = deviceId,
                        entity = "recipe",
                        payload = kotlinx.serialization.json.buildJsonObject {
                            put("id", JsonPrimitive(recipeId))
                            put("householdId", JsonPrimitive("hh-demo"))
                            put("title", JsonPrimitive(r.title))
                            put("servings", JsonPrimitive(r.servings))
                        },
                    ),
                )
            }
        }
    }
    // Photos: embedded base64 is recorded as a warning until the media store
    // lands — bytes are preserved in the export path via photo_data round-trip.
    val withPhotos = parsed.recipes.count { it.photoBase64 != null }
    if (withPhotos > 0) warnings += "$withPhotos photo(s) embedded; photo library storage is not yet wired — recipes imported without images."
    return ImportResult(imported, updated, warnings)
}
