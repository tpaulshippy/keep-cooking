package com.keepcooking.app.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccessTime
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.FormatListBulleted
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import com.keepcooking.app.AppContainer
import com.keepcooking.app.cook.fractionDisplayString
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Recipe editor — Android parity with the iOS "Edit Recipe" sheet.
 * Dark modal styling: red-tinted X cancel, centered title, blue circular
 * save check; collapsible sections (all default expanded) in one dark card
 * style: Info (title, Photos count + thumbnail, interactive Rating stars,
 * Servings stepper + number field, source domain + URL field with link icon,
 * Difficulty dropdown, Categories field, display-only Cookbook row), Times
 * (Prep / Cook / Total), Description, Ingredients (free text, group headers
 * preserved), Directions (free text), Notes (free text) and Nutrition
 * (Text/Table segmented + Extract to Table + free text).
 *
 * Draft state lives in remember/mutableState; persisting goes through the
 * caller-supplied [onSave] (NavGraph's Room + sync-outbox write, the same
 * DAO/sync path detail uses). Photo capture is out of scope — the Photos
 * row is display-only. Difficulty / Notes / Nutrition text have no Room
 * columns (Paprika/server-contract extension fields), so they round-trip in
 * the sync envelope payload but are not stored locally — no DB migration.
 * TODO: add nullable Room columns (notes, nutritionText, difficulty) when
 * the sync read path learns them, and hydrate the draft from Room instead
 * of starting them unset/empty.
 */
data class RecipeEditDraft(
    val title: String = "",
    val description: String = "",
    val servings: Double = 4.0,
    val prepMinutes: Int? = null,
    val cookMinutes: Int? = null,
    val rating: Double? = null,
    val source: String = "",
    val sourceUrl: String = "",
    val categories: List<String> = emptyList(),
    /** Paprika free-text difficulty (e.g. Easy). Null = unset. */
    val difficulty: String? = null,
    val photoOriginal: String? = null,
    val photoThumb: String? = null,
    /** One ingredient per line; lines ending in ":" are group headers. */
    val ingredientsText: String = "",
    /** Steps as paragraphs separated by blank lines. */
    val directionsText: String = "",
    /** TODO: envelope-only until a nullable Room column lands. */
    val notes: String = "",
    /** TODO: envelope-only until a nullable Room column lands. */
    val nutritionText: String = "",
)

val RecipeDifficultyOptions = listOf("Easy", "Medium", "Hard")

/** A trimmed line ending in ":" is a group header, not an ingredient. */
fun isIngredientHeaderLine(line: String): Boolean = line.trim().endsWith(":")

/** "25 min" / "1 hr 25 min" / "2 hr"; null/negative renders blank. */
fun formatMinutes(mins: Int?): String {
    if (mins == null || mins < 0) return ""
    if (mins == 0) return "0 min"
    val h = mins / 60
    val m = mins % 60
    return when {
        h == 0 -> "$m min"
        m == 0 -> "$h hr"
        else -> "$h hr $m min"
    }
}

/** Loads the current Room row (+ children) into an edit draft. */
suspend fun loadRecipeEditDraft(container: AppContainer, recipeId: String): RecipeEditDraft? {
    val r = container.db.recipes().byId(recipeId) ?: return null
    val cats = runCatching {
        Json.parseToJsonElement(r.categoriesJson).jsonArray.map { it.jsonPrimitive.content }
    }.getOrDefault(emptyList())
    val ingredients = container.db.ingredients().forRecipe(recipeId)
    val steps = container.db.steps().forRecipe(recipeId)
    return RecipeEditDraft(
        title = r.title,
        description = r.recipeDescription,
        servings = r.servings,
        prepMinutes = r.prepMinutes,
        cookMinutes = r.cookMinutes,
        rating = r.rating,
        source = r.source,
        sourceUrl = r.sourceUrl,
        categories = cats,
        difficulty = null, // No Room column (see kdoc) — always starts unset.
        photoOriginal = r.photoOriginal,
        photoThumb = r.photoThumb,
        ingredientsText = ingredients.map { it.display.ifBlank { it.name } }.joinToString("\n"),
        directionsText = steps.map { it.text }.joinToString("\n\n"),
        notes = "", // TODO: hydrate from Room once a nullable notes column exists.
        nutritionText = "", // TODO: hydrate from Room once a nullable column exists.
    )
}

/** Display host for a source URL, falling back to the source name. */
fun recipeDomainOf(sourceUrl: String, source: String): String {
    val host = runCatching { Uri.parse(sourceUrl.trim()).host }.getOrNull()
    if (!host.isNullOrBlank()) return host.removePrefix("www.")
    if (source.isNotBlank()) return source
    if (sourceUrl.isNotBlank()) return sourceUrl
    return ""
}

fun isHttpUrl(url: String): Boolean {
    val s = url.trim().lowercase()
    return s.startsWith("http://") || s.startsWith("https://")
}

/** Parses "Key: value" nutrition lines into table rows. */
fun parseNutritionRows(text: String): List<Pair<String, String>> =
    text.lines().mapNotNull { line ->
        val idx = line.indexOf(":")
        if (idx <= 0) return@mapNotNull null
        val key = line.substring(0, idx).trim()
        val value = line.substring(idx + 1).trim()
        if (key.isEmpty() || value.isEmpty()) null else key to value
    }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecipeEditorScreen(
    container: AppContainer,
    recipeId: String,
    onCancel: () -> Unit = {},
    /** Persists the draft (Room + sync outbox). Throws on failure. */
    onSave: suspend (RecipeEditDraft) -> Unit = {},
    onSaved: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var draft by remember { mutableStateOf<RecipeEditDraft?>(null) }
    var loadFailed by remember { mutableStateOf(false) }
    var infoExpanded by remember { mutableStateOf(true) }
    var timesExpanded by remember { mutableStateOf(true) }
    var descriptionExpanded by remember { mutableStateOf(true) }
    var ingredientsExpanded by remember { mutableStateOf(true) }
    var directionsExpanded by remember { mutableStateOf(true) }
    var notesExpanded by remember { mutableStateOf(true) }
    var nutritionExpanded by remember { mutableStateOf(true) }
    var nutritionTable by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }

    LaunchedEffect(recipeId) {
        draft = runCatching { loadRecipeEditDraft(container, recipeId) }.getOrNull()
        loadFailed = draft == null
    }

    Scaffold(containerColor = MaterialTheme.colorScheme.background) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            // Header: red-tinted X | "Edit Recipe" | blue circular check.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                        .clickable(onClick = onCancel),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "Cancel",
                        tint = Color(0xFFE57373),
                        modifier = Modifier.size(26.dp),
                    )
                }
                Text(
                    "Edit Recipe",
                    style = MaterialTheme.typography.titleLarge,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF5B9BD5))
                        .clickable(enabled = !saving) {
                            val d = draft ?: return@clickable
                            if (d.title.isBlank()) {
                                error = "Title is required."
                                return@clickable
                            }
                            error = null
                            saving = true
                            scope.launch {
                                runCatching { onSave(d) }
                                    .onSuccess { onSaved() }
                                    .onFailure { e ->
                                        error = "Couldn't save (${e.message ?: "unknown error"})."
                                        saving = false
                                    }
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Filled.Check,
                        contentDescription = "Save",
                        tint = Color.White,
                        modifier = Modifier.size(26.dp),
                    )
                }
            }

            Spacer(Modifier.height(20.dp))

            val d = draft
            if (d == null) {
                Text(
                    if (loadFailed) "Recipe not found." else "Loading…",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 24.dp),
                )
                return@Column
            }

            // ---------- Info ----------
            EditorSectionHeader(title = "Info", expanded = infoExpanded, onToggle = { infoExpanded = !infoExpanded })
            if (infoExpanded) {
                EditorCard {
                    // Title.
                    EditorTextField(
                        value = d.title,
                        onValueChange = { draft = d.copy(title = it) },
                        textStyle = MaterialTheme.typography.titleLarge,
                    )
                    EditorDivider()

                    // Photos (display-only): count + thumbnail/placeholder.
                    val hasPhoto = !d.photoThumb.isNullOrBlank() || !d.photoOriginal.isNullOrBlank()
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("Photos", style = MaterialTheme.typography.titleMedium)
                            Text(
                                if (hasPhoto) "1 photo" else "0 photos",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        val thumb = d.photoThumb ?: d.photoOriginal
                        if (!thumb.isNullOrBlank()) {
                            AsyncImage(
                                model = thumb,
                                contentDescription = "Recipe photo",
                                contentScale = ContentScale.Crop,
                                placeholder = rememberVectorPainter(Icons.Filled.Image),
                                error = rememberVectorPainter(Icons.Filled.Image),
                                modifier = Modifier.size(96.dp).clip(RoundedCornerShape(16.dp))
                                    .background(MaterialTheme.colorScheme.surfaceContainerHighest),
                            )
                        } else {
                            Box(
                                modifier = Modifier.size(96.dp).clip(RoundedCornerShape(16.dp))
                                    .background(MaterialTheme.colorScheme.surfaceContainerHighest),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    Icons.Filled.Image,
                                    contentDescription = "No photo",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(36.dp),
                                )
                            }
                        }
                    }
                    EditorDivider()

                    // Rating: interactive stars (tap again to clear).
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Rating",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f),
                        )
                        val stars = d.rating?.toInt()?.coerceIn(0, 5) ?: 0
                        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                            for (i in 1..5) {
                                IconButton(
                                    onClick = {
                                        draft = d.copy(
                                            rating = if (stars == i) null else i.toDouble(),
                                        )
                                    },
                                    modifier = Modifier.size(36.dp),
                                ) {
                                    Icon(
                                        Icons.Filled.Star,
                                        contentDescription = "$i star${if (i > 1) "s" else ""}",
                                        tint = if (i <= stars) Color(0xFFF59E0B)
                                        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f),
                                        modifier = Modifier.size(26.dp),
                                    )
                                }
                            }
                        }
                    }
                    EditorDivider()

                    // Servings: stepper + number field.
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Servings",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(
                            onClick = {
                                val next = (d.servings - 1).coerceAtLeast(0.25)
                                draft = d.copy(servings = next)
                            },
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(Icons.Filled.Remove, contentDescription = "Fewer servings")
                        }
                        var servingsText by remember(d.servings) {
                            mutableStateOf(fractionDisplayString(d.servings))
                        }
                        TextField(
                            value = servingsText,
                            onValueChange = { text ->
                                servingsText = text
                                text.toDoubleOrNull()?.let {
                                    if (it in 0.25..100.0) draft = d.copy(servings = it)
                                }
                            },
                            singleLine = true,
                            textStyle = MaterialTheme.typography.titleMedium.copy(
                                textAlign = TextAlign.Center,
                            ),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            colors = transparentFieldColors(),
                            modifier = Modifier.width(72.dp),
                        )
                        IconButton(
                            onClick = {
                                val next = (d.servings + 1).coerceAtMost(100.0)
                                draft = d.copy(servings = next)
                            },
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(Icons.Filled.Add, contentDescription = "More servings")
                        }
                    }
                    EditorDivider()

                    // Source domain + link icon; URL editable below.
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            recipeDomainOf(d.sourceUrl, d.source).ifBlank { "Add source" },
                            style = MaterialTheme.typography.titleMedium,
                            color = if (recipeDomainOf(d.sourceUrl, d.source).isBlank()) {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            } else {
                                MaterialTheme.colorScheme.onSurface
                            },
                            modifier = Modifier.weight(1f),
                        )
                        val canOpen = isHttpUrl(d.sourceUrl)
                        IconButton(
                            onClick = {
                                if (canOpen) {
                                    runCatching {
                                        context.startActivity(
                                            Intent(Intent.ACTION_VIEW, Uri.parse(d.sourceUrl.trim())),
                                        )
                                    }
                                }
                            },
                            enabled = canOpen,
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(
                                Icons.Filled.Link,
                                contentDescription = "Open source",
                                tint = if (canOpen) Color(0xFF5B9BD5)
                                else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f),
                            )
                        }
                    }
                    EditorTextField(
                        value = d.sourceUrl,
                        onValueChange = { draft = d.copy(sourceUrl = it) },
                        placeholder = "Source URL",
                        singleLine = true,
                        keyboardType = KeyboardType.Uri,
                        textStyle = MaterialTheme.typography.bodyMedium,
                    )
                    EditorDivider()

                    // Difficulty dropdown (envelope-only, no Room column).
                    var difficultyExpanded by remember { mutableStateOf(false) }
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Difficulty",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f),
                        )
                        ExposedDropdownMenuBox(
                            expanded = difficultyExpanded,
                            onExpandedChange = { difficultyExpanded = !difficultyExpanded },
                        ) {
                            TextField(
                                value = d.difficulty ?: "",
                                onValueChange = {},
                                readOnly = true,
                                placeholder = { Text("Unset") },
                                singleLine = true,
                                textStyle = MaterialTheme.typography.bodyLarge.copy(
                                    textAlign = TextAlign.End,
                                ),
                                trailingIcon = {
                                    ExposedDropdownMenuDefaults.TrailingIcon(difficultyExpanded)
                                },
                                colors = transparentFieldColors(),
                                modifier = Modifier.menuAnchor().width(160.dp),
                            )
                            ExposedDropdownMenu(
                                expanded = difficultyExpanded,
                                onDismissRequest = { difficultyExpanded = false },
                            ) {
                                DropdownMenuItem(
                                    text = { Text("Unset") },
                                    onClick = {
                                        draft = d.copy(difficulty = null)
                                        difficultyExpanded = false
                                    },
                                )
                                RecipeDifficultyOptions.forEach { option ->
                                    DropdownMenuItem(
                                        text = { Text(option) },
                                        onClick = {
                                            draft = d.copy(difficulty = option)
                                            difficultyExpanded = false
                                        },
                                    )
                                }
                            }
                        }
                    }
                    EditorDivider()

                    // Categories (comma-separated; "Uncategorized" placeholder).
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Filled.FormatListBulleted,
                            contentDescription = null,
                            tint = Color(0xFFE57373),
                            modifier = Modifier.size(28.dp),
                        )
                        Spacer(Modifier.width(12.dp))
                        Text(
                            "Categories",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    var categoriesText by remember(d.categories) {
                        mutableStateOf(d.categories.joinToString(", "))
                    }
                    EditorTextField(
                        value = categoriesText,
                        onValueChange = { text ->
                            categoriesText = text
                            draft = d.copy(
                                categories = text.split(",").map { it.trim() }
                                    .filter { it.isNotEmpty() },
                            )
                        },
                        placeholder = "Uncategorized",
                        singleLine = true,
                        textStyle = MaterialTheme.typography.bodyLarge.copy(
                            textAlign = TextAlign.End,
                        ),
                    )
                    EditorDivider()

                    // Cookbook row (display-only: cookbooks live in memory, no Room column).
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Filled.Book,
                            contentDescription = null,
                            tint = Color(0xFFE57373),
                            modifier = Modifier.size(28.dp),
                        )
                        Spacer(Modifier.width(12.dp))
                        Text(
                            "Cookbook",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            "My Cookbook",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            Icons.Filled.UnfoldMore,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            // ---------- Times ----------
            EditorSectionHeader(
                icon = Icons.Filled.AccessTime,
                title = "Times",
                expanded = timesExpanded,
                onToggle = { timesExpanded = !timesExpanded },
            )
            if (timesExpanded) {
                EditorCard {
                    TimeRow(
                        icon = Icons.Filled.Restaurant,
                        label = "Prep Time",
                        minutes = d.prepMinutes,
                        onMinutesChange = { draft = d.copy(prepMinutes = it) },
                    )
                    EditorDivider()
                    TimeRow(
                        icon = Icons.Filled.LocalFireDepartment,
                        label = "Cook Time",
                        minutes = d.cookMinutes,
                        onMinutesChange = { draft = d.copy(cookMinutes = it) },
                    )
                    EditorDivider()
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Filled.History,
                            contentDescription = null,
                            tint = Color(0xFFE57373),
                            modifier = Modifier.size(28.dp),
                        )
                        Spacer(Modifier.width(12.dp))
                        Text(
                            "Total Time",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f),
                        )
                        val total = when {
                            d.prepMinutes == null && d.cookMinutes == null -> null
                            else -> (d.prepMinutes ?: 0) + (d.cookMinutes ?: 0)
                        }
                        Text(
                            formatMinutes(total),
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Spacer(Modifier.width(8.dp))
                        Icon(
                            Icons.Filled.AccessTime,
                            contentDescription = null,
                            tint = Color(0xFF5B9BD5),
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
            }

            // ---------- Description ----------
            EditorSectionHeader(
                icon = Icons.Filled.Description,
                title = "Description",
                expanded = descriptionExpanded,
                onToggle = { descriptionExpanded = !descriptionExpanded },
            )
            if (descriptionExpanded) {
                EditorCard {
                    EditorTextField(
                        value = d.description,
                        onValueChange = { draft = d.copy(description = it) },
                        singleLine = false,
                        minLines = 4,
                        placeholder = "Describe this recipe…",
                        textStyle = MaterialTheme.typography.bodyLarge,
                    )
                }
            }

            // ---------- Ingredients ----------
            EditorSectionHeader(
                icon = Icons.Filled.FormatListBulleted,
                title = "Ingredients",
                expanded = ingredientsExpanded,
                onToggle = { ingredientsExpanded = !ingredientsExpanded },
            )
            if (ingredientsExpanded) {
                EditorCard {
                    EditorTextField(
                        value = d.ingredientsText,
                        onValueChange = { draft = d.copy(ingredientsText = it) },
                        singleLine = false,
                        minLines = 6,
                        placeholder = "One ingredient per line — lines ending in “:” stay group headers.",
                        textStyle = MaterialTheme.typography.bodyLarge,
                    )
                }
            }

            // ---------- Directions ----------
            EditorSectionHeader(
                icon = Icons.Filled.FormatListNumbered,
                title = "Directions",
                expanded = directionsExpanded,
                onToggle = { directionsExpanded = !directionsExpanded },
            )
            if (directionsExpanded) {
                EditorCard {
                    EditorTextField(
                        value = d.directionsText,
                        onValueChange = { draft = d.copy(directionsText = it) },
                        singleLine = false,
                        minLines = 6,
                        placeholder = "One step per paragraph (blank line between steps)…",
                        textStyle = MaterialTheme.typography.bodyLarge,
                    )
                }
            }

            // ---------- Notes ----------
            EditorSectionHeader(
                icon = Icons.Filled.Notes,
                title = "Notes",
                expanded = notesExpanded,
                onToggle = { notesExpanded = !notesExpanded },
            )
            if (notesExpanded) {
                EditorCard {
                    EditorTextField(
                        value = d.notes,
                        onValueChange = { draft = d.copy(notes = it) },
                        singleLine = false,
                        minLines = 2,
                        textStyle = MaterialTheme.typography.bodyLarge,
                    )
                }
            }

            // ---------- Nutrition ----------
            EditorSectionHeader(
                icon = Icons.Filled.Restaurant,
                title = "Nutrition",
                expanded = nutritionExpanded,
                onToggle = { nutritionExpanded = !nutritionExpanded },
            )
            if (nutritionExpanded) {
                EditorCard {
                    SingleChoiceSegmentedButtonRow(
                        modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                    ) {
                        SegmentedButton(
                            selected = !nutritionTable,
                            onClick = { nutritionTable = false },
                            shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
                        ) { Text("Text") }
                        SegmentedButton(
                            selected = nutritionTable,
                            onClick = { nutritionTable = true },
                            shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                        ) { Text("Table") }
                    }
                    EditorDivider()
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Filled.TableChart,
                            contentDescription = null,
                            tint = Color(0xFF5B9BD5),
                            modifier = Modifier.size(28.dp),
                        )
                        TextButton(onClick = { nutritionTable = true }) {
                            Text("Extract to Table", color = Color(0xFF5B9BD5))
                        }
                    }
                    EditorDivider()
                    if (!nutritionTable) {
                        EditorTextField(
                            value = d.nutritionText,
                            onValueChange = { draft = d.copy(nutritionText = it) },
                            singleLine = false,
                            minLines = 5,
                            placeholder = "Calories: 130 calories\nServing Size: 1 Cookie\n…",
                            textStyle = MaterialTheme.typography.bodyLarge,
                        )
                    } else {
                        val rows = remember(d.nutritionText) {
                            parseNutritionRows(d.nutritionText)
                        }
                        Column(Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
                            if (rows.isEmpty()) {
                                Text(
                                    "No table rows yet — write “Label: value” lines in Text mode, then Extract to Table.",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            } else {
                                rows.forEach { (key, value) ->
                                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                        Text(
                                            key,
                                            style = MaterialTheme.typography.bodyLarge,
                                            modifier = Modifier.weight(1f),
                                        )
                                        Text(
                                            value,
                                            style = MaterialTheme.typography.bodyLarge,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            error?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 12.dp),
                )
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

/** Collapsible section header: neutral icon + label + chevron. */
@Composable
private fun EditorSectionHeader(
    title: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    icon: ImageVector? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp),
            )
            Spacer(Modifier.width(16.dp))
        }
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f).padding(start = if (icon == null) 8.dp else 0.dp),
        )
        Icon(
            if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
            contentDescription = if (expanded) "Collapse" else "Expand",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Dark rounded card shared by every editor section. */
@Composable
private fun EditorCard(content: @Composable () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        ),
    ) {
        Column(Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) {
            content()
            Spacer(Modifier.height(8.dp))
        }
    }
}

/** Prep/Cook row: red icon + label, numeric minutes field + "min" + blue clock. */
@Composable
private fun TimeRow(
    icon: ImageVector,
    label: String,
    minutes: Int?,
    onMinutesChange: (Int?) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = Color(0xFFE57373),
            modifier = Modifier.size(28.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            label,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f),
        )
        var text by remember(minutes) { mutableStateOf(minutes?.toString() ?: "") }
        TextField(
            value = text,
            onValueChange = { input ->
                text = input.filter { it.isDigit() }.take(4)
                onMinutesChange(text.toIntOrNull())
            },
            singleLine = true,
            textStyle = MaterialTheme.typography.titleMedium.copy(textAlign = TextAlign.End),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            colors = transparentFieldColors(),
            placeholder = { Text("") },
            modifier = Modifier.width(80.dp),
        )
        Text(
            "min",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.width(8.dp))
        Icon(
            Icons.Filled.AccessTime,
            contentDescription = null,
            tint = Color(0xFF5B9BD5),
            modifier = Modifier.size(24.dp),
        )
    }
}

@Composable
private fun EditorDivider() {
    HorizontalDivider(
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun transparentFieldColors() = TextFieldDefaults.colors(
    focusedContainerColor = Color.Transparent,
    unfocusedContainerColor = Color.Transparent,
    disabledContainerColor = Color.Transparent,
    errorContainerColor = Color.Transparent,
    focusedIndicatorColor = Color.Transparent,
    unfocusedIndicatorColor = Color.Transparent,
    disabledIndicatorColor = Color.Transparent,
    errorIndicatorColor = Color.Transparent,
)

@Composable
private fun EditorTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    singleLine: Boolean = true,
    minLines: Int = 1,
    keyboardType: KeyboardType = KeyboardType.Text,
    textStyle: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.bodyLarge,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = singleLine,
        minLines = minLines,
        textStyle = textStyle,
        placeholder = placeholder?.let { { Text(it) } },
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        colors = transparentFieldColors(),
        modifier = modifier.fillMaxWidth().padding(0.dp),
    )
}
