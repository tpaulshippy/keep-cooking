package com.keepcooking.app.ui.screens

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.keepcooking.app.AppContainer
import com.keepcooking.app.network.SyncEnvelopeDto
import com.keepcooking.app.cook.fractionDisplayString
import com.keepcooking.app.cook.scaledDisplay
import com.keepcooking.app.data.IngredientEntity
import com.keepcooking.app.library.AdvancedFilter
import com.keepcooking.app.library.Cookbook
import com.keepcooking.app.library.DuplicableRecipe
import com.keepcooking.app.library.LibraryRecipe
import com.keepcooking.app.library.SavedSearch
import com.keepcooking.app.library.DuplicateMergePlan
import com.keepcooking.app.library.filterRecipes
import com.keepcooking.app.library.findDuplicateGroups
import com.keepcooking.app.library.planMerge
import com.keepcooking.app.library.totalMinutes
import java.time.Instant
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Library tab — parity with iOS Features/Library/LibraryViews.swift.
 * Sections: Search (query + advanced filter + saved searches), Categories,
 * Cookbooks (list/detail), Duplicates (badge + review/merge).
 *
 * Recipes are supplied by the caller (Room flows); cookbooks / saved
 * searches / dismissed dupe groups live in memory here until Room tables
 * land — every button performs a real action on that state.
 */

data class LibraryRecipeRow(
    override val recipeId: String,
    override val title: String,
    override val recipeDescription: String = "",
    override val servings: Double = 4.0,
    override val prepMinutes: Int? = null,
    override val cookMinutes: Int? = null,
    override val rating: Double? = null,
    override val isFavorite: Boolean = false,
    override val source: String = "",
    override val categories: List<String> = emptyList(),
    override val ingredientNames: List<String> = emptyList(),
    override val stepTexts: List<String> = emptyList(),
    override val photoOriginal: String? = null,
    override val photoThumb: String? = null,
) : LibraryRecipe, DuplicableRecipe

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    recipes: List<LibraryRecipeRow> = emptyList(),
    onRecipeClick: (String) -> Unit = {},
    onMerge: (List<LibraryRecipeRow>, DuplicateMergePlan) -> Unit = { _, _ -> },
) {
    var tab by remember { mutableStateOf(0) }
    val tabs = listOf("Search", "Cookbooks", "Duplicates", "Saved")
    var filter by remember { mutableStateOf(AdvancedFilter()) }
    var showAdvanced by remember { mutableStateOf(false) }
    val cookbooks = remember { mutableStateListOf<Cookbook>() }
    val saved = remember { mutableStateListOf<SavedSearch>() }
    val dismissed = remember { mutableStateOf(setOf<String>()) }
    var showSaveDialog by remember { mutableStateOf(false) }
    var saveName by remember { mutableStateOf("") }
    var selectedCookbook by remember { mutableStateOf<Cookbook?>(null) }

    val results = remember(recipes, filter) { filterRecipes(recipes, filter) }
    val groups = remember(recipes, dismissed.value) {
        findDuplicateGroups(recipes).filter { g ->
            g.map { it.recipeId }.sorted().joinToString("+") !in dismissed.value
        }
    }
    val categories = remember(recipes) {
        val counts = mutableMapOf<String, Int>()
        val display = mutableMapOf<String, String>()
        for (r in recipes) for (c in r.categories) {
            val key = c.lowercase()
            counts[key] = (counts[key] ?: 0) + 1
            display.putIfAbsent(key, c)
        }
        counts.map { (display[it.key] ?: it.key) to it.value }.sortedBy { it.first.lowercase() }
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Library") }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            TabRow(selectedTabIndex = tab) {
                tabs.forEachIndexed { i, t ->
                    Tab(
                        selected = tab == i,
                        onClick = { tab = i },
                        text = {
                            Text(
                                if (t == "Duplicates" && groups.isNotEmpty()) "Duplicates (${groups.size})"
                                else t,
                            )
                        },
                    )
                }
            }
            when (tab) {
                0 -> LazyColumn(
                    modifier = Modifier.fillMaxSize().padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    item {
                        OutlinedTextField(
                            value = filter.query,
                            onValueChange = { filter = filter.copy(query = it) },
                            label = { Text("Search title, ingredient, category…") },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                        )
                        Spacer(Modifier.height(8.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Advanced filters")
                            Spacer(Modifier.width(8.dp))
                            Checkbox(checked = showAdvanced, onCheckedChange = { showAdvanced = it })
                        }
                        if (showAdvanced) {
                            AdvancedFilterForm(filter = filter, onChange = { filter = it })
                        }
                        Spacer(Modifier.height(8.dp))
                        if (categories.isNotEmpty()) {
                            Text("Categories", style = MaterialTheme.typography.labelLarge)
                            categories.forEach { (name, count) ->
                                val selected = filter.categories.contains(name)
                                FilterChip(
                                    selected = selected,
                                    onClick = {
                                        filter = if (selected) filter.copy(categories = filter.categories - name)
                                        else filter.copy(categories = filter.categories + name)
                                    },
                                    label = { Text("$name ($count)") },
                                    modifier = Modifier.padding(end = 4.dp),
                                )
                            }
                        }
                        Spacer(Modifier.height(8.dp))
                        Button(
                            onClick = { showSaveDialog = true },
                            enabled = !filter.isEmpty,
                        ) { Text("Save this search") }
                        Spacer(Modifier.height(8.dp))
                        Text("Results (${results.size})", style = MaterialTheme.typography.titleSmall)
                    }
                    if (results.isEmpty()) {
                        item { Text("No matches. Loosen a filter.", style = MaterialTheme.typography.bodyMedium) }
                    } else {
                        items(results, key = { it.recipeId }) { r ->
                            Card(modifier = Modifier.fillMaxWidth().clickable { onRecipeClick(r.recipeId) }) {
                                Column(Modifier.padding(12.dp)) {
                                    Text(r.title, style = MaterialTheme.typography.titleMedium)
                                    Text(summaryLine(r), style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        }
                    }
                }
                1 -> {
                    if (selectedCookbook != null) {
                        CookbookDetail(
                            cookbook = selectedCookbook!!,
                            recipes = recipes,
                            onBack = { selectedCookbook = null },
                            onRemove = { book, id ->
                                val idx = cookbooks.indexOfFirst { it.id == book.id }
                                if (idx >= 0) cookbooks[idx] = book.copy(recipeIds = book.recipeIds - id)
                                selectedCookbook = selectedCookbook?.let { it.copy(recipeIds = it.recipeIds - id) }
                            },
                        )
                    } else {
                        CookbookList(
                            cookbooks = cookbooks.toList(),
                            recipes = recipes,
                            onOpen = { selectedCookbook = it },
                            onCreate = { name, ids -> cookbooks.add(Cookbook(householdId = "hh-demo", name = name, recipeIds = ids)) },
                        )
                    }
                }
                2 -> DuplicateReview(
                    groups = groups,
                    onMerge = { group, plan ->
                        onMerge(group, plan)
                        dismissed.value = dismissed.value + group.map { it.recipeId }.sorted().joinToString("+")
                    },
                    onDismiss = { idx ->
                        dismissed.value = dismissed.value + groups[idx].map { it.recipeId }.sorted().joinToString("+")
                    },
                )
                3 -> SavedSearches(
                    saved = saved.toList(),
                    onApply = { filter = it.filter; tab = 0 },
                    onDelete = { id -> saved.removeAll { it.id == id } },
                )
            }
        }
        if (showSaveDialog) {
            AlertDialog(
                onDismissRequest = { showSaveDialog = false },
                title = { Text("Name this search") },
                text = {
                    OutlinedTextField(
                        value = saveName,
                        onValueChange = { saveName = it },
                        label = { Text("e.g. Quick vegetarian dinners") },
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        val name = saveName.trim()
                        if (name.isNotEmpty()) {
                            saved.add(SavedSearch(name = name, filter = filter))
                            saveName = ""
                            showSaveDialog = false
                        }
                    }) { Text("Save") }
                },
                dismissButton = { TextButton(onClick = { showSaveDialog = false }) { Text("Cancel") } },
            )
        }
    }
}

private fun summaryLine(r: LibraryRecipeRow): String {
    val bits = mutableListOf<String>()
    r.totalMinutes?.let { bits.add("$it min") }
    r.rating?.let { bits.add("★ %.1f".format(it)) }
    if (r.isFavorite) bits.add("♥ Favorite")
    if (r.source.isNotEmpty()) bits.add(r.source)
    if (r.categories.isNotEmpty()) bits.add(r.categories.joinToString(", "))
    return bits.joinToString(" · ")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedFilterForm(filter: AdvancedFilter, onChange: (AdvancedFilter) -> Unit) {
    var includeText by remember(filter.includeTerms) { mutableStateOf(filter.includeTerms.joinToString(", ")) }
    var excludeText by remember(filter.excludeTerms) { mutableStateOf(filter.excludeTerms.joinToString(", ")) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = includeText,
            onValueChange = {
                includeText = it
                onChange(filter.copy(includeTerms = it.split(",").map { t -> t.trim() }.filter { t -> t.isNotEmpty() }))
            },
            label = { Text("Must include (comma-separated)") },
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = excludeText,
            onValueChange = {
                excludeText = it
                onChange(filter.copy(excludeTerms = it.split(",").map { t -> t.trim() }.filter { t -> t.isNotEmpty() }))
            },
            label = { Text("Must exclude (comma-separated)") },
            modifier = Modifier.fillMaxWidth(),
        )
        TimeCapDropdown(filter.maxTotalMinutes) { onChange(filter.copy(maxTotalMinutes = it)) }
        RatingDropdown(filter.minRating) { onChange(filter.copy(minRating = it)) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = filter.favoritesOnly, onCheckedChange = { onChange(filter.copy(favoritesOnly = it)) })
            Spacer(Modifier.width(8.dp))
            Text("Favorites only")
        }
        OutlinedTextField(
            value = filter.sourceContains ?: "",
            onValueChange = { onChange(filter.copy(sourceContains = it.ifEmpty { null })) },
            label = { Text("Source contains…") },
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedButton(
            onClick = { onChange(AdvancedFilter(query = filter.query)) },
            enabled = filter.includeTerms.isNotEmpty() || filter.excludeTerms.isNotEmpty() ||
                filter.maxTotalMinutes != null || filter.minRating != null || filter.favoritesOnly ||
                !(filter.sourceContains ?: "").isEmpty() || filter.categories.isNotEmpty(),
        ) { Text("Clear all filters") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimeCapDropdown(selected: Int?, onSelect: (Int?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val options = listOf(null to "Any", 15 to "15 min", 30 to "30 min", 60 to "60 min")
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = !expanded }) {
        OutlinedTextField(
            value = options.firstOrNull { it.first == selected }?.second ?: "Any",
            onValueChange = {},
            readOnly = true,
            label = { Text("Max time") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            modifier = Modifier.menuAnchor().fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (v, label) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { onSelect(v); expanded = false })
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RatingDropdown(selected: Double?, onSelect: (Double?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val options = listOf(null to "Any", 3.0 to "3+", 4.0 to "4+", 4.5 to "4.5+")
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = !expanded }) {
        OutlinedTextField(
            value = options.firstOrNull { it.first == selected }?.second ?: "Any",
            onValueChange = {},
            readOnly = true,
            label = { Text("Min rating") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            modifier = Modifier.menuAnchor().fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { (v, label) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { onSelect(v); expanded = false })
            }
        }
    }
}

@Composable
private fun CookbookList(
    cookbooks: List<Cookbook>,
    recipes: List<LibraryRecipeRow>,
    onOpen: (Cookbook) -> Unit,
    onCreate: (String, List<String>) -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf(setOf<String>()) }
    LazyColumn(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(cookbooks, key = { it.id }) { book ->
            Card(modifier = Modifier.fillMaxWidth().clickable { onOpen(book) }) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(book.name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                    Text("${book.recipeIds.size}", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        item {
            Text("New cookbook", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Cookbook name") }, modifier = Modifier.fillMaxWidth())
            recipes.forEach { r ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable {
                    selected = if (selected.contains(r.recipeId)) selected - r.recipeId else selected + r.recipeId
                }) {
                    Checkbox(checked = selected.contains(r.recipeId), onCheckedChange = null)
                    Text(r.title)
                }
            }
            Button(onClick = {
                onCreate(name.ifEmpty { "Untitled" }, selected.toList())
                name = ""
                selected = emptySet()
            }) { Text("Create cookbook (${selected.size} selected)") }
        }
    }
}

@Composable
private fun CookbookDetail(
    cookbook: Cookbook,
    recipes: List<LibraryRecipeRow>,
    onBack: () -> Unit,
    onRemove: (Cookbook, String) -> Unit,
) {
    val members = remember(cookbook, recipes) {
        val ids = cookbook.recipeIds.toSet()
        recipes.filter { ids.contains(it.recipeId) }
    }
    LazyColumn(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            TextButton(onClick = onBack) { Text("← All cookbooks") }
            Text(cookbook.name, style = MaterialTheme.typography.headlineSmall)
        }
        if (members.isEmpty()) {
            item { Text("No recipes in this cookbook yet.", style = MaterialTheme.typography.bodyMedium) }
        } else {
            items(members, key = { it.recipeId }) { r ->
                Card(modifier = Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(r.title, modifier = Modifier.weight(1f))
                        TextButton(onClick = { onRemove(cookbook, r.recipeId) }) { Text("Remove") }
                    }
                }
            }
        }
    }
}

@Composable
private fun DuplicateReview(
    groups: List<List<LibraryRecipeRow>>,
    onMerge: (List<LibraryRecipeRow>, DuplicateMergePlan) -> Unit,
    onDismiss: (Int) -> Unit,
) {
    LazyColumn(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (groups.isEmpty()) {
            item { Text("No duplicates — fuzzy matching found no duplicate recipes.", style = MaterialTheme.typography.bodyMedium) }
        } else {
            groups.forEachIndexed { i, group ->
                item(key = "header-$i") { Text("Group ${i + 1}", style = MaterialTheme.typography.titleSmall) }
                items(group, key = { it.recipeId }) { r ->
                    Column(Modifier.padding(horizontal = 8.dp)) {
                        Text(r.title, style = MaterialTheme.typography.titleMedium)
                        Text(
                            "${r.ingredientNames.size} ingredients · ${r.stepTexts.size} steps · ${r.photoOriginal ?: "no photo"}",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                item(key = "actions-$i") {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        val plan = remember(group) { planMerge(group) }
                        if (plan != null) {
                            Button(onClick = { onMerge(group, plan) }) { Text("Merge into best (${plan.survivorTitle})") }
                        }
                        OutlinedButton(onClick = { onDismiss(i) }) { Text("Keep both") }
                    }
                }
            }
        }
    }
}

@Composable
private fun SavedSearches(
    saved: List<SavedSearch>,
    onApply: (SavedSearch) -> Unit,
    onDelete: (String) -> Unit,
) {
    LazyColumn(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (saved.isEmpty()) {
            item { Text("No saved searches yet — save one from the Search tab.", style = MaterialTheme.typography.bodyMedium) }
        } else {
            items(saved, key = { it.id }) { s ->
                Card(modifier = Modifier.fillMaxWidth().clickable { onApply(s) }) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(s.name, modifier = Modifier.weight(1f))
                        TextButton(onClick = { onDelete(s.id) }) { Text("Delete") }
                    }
                }
            }
        }
    }
}

/** Recipe detail — read-only. Loads the Room recipe with ingredients +
 * steps; Cook launches from here (Cook is not a tab), Edit opens the
 * recipe editor, Share fires a plain-text ACTION_SEND, Delete tombstones
 * via NavGraph's outbox write. Group-header ingredient rows (see editor)
 * render as section headers, never bullets. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecipeDetailScreen(
    container: AppContainer,
    recipeId: String,
    onBack: () -> Unit = {},
    onCook: (String) -> Unit = {},
    onEdit: (String) -> Unit = {},
    /** Tombstones the recipe. Throws on failure — the caller pops only on success. */
    onDelete: suspend (String) -> Unit = {},
    onDeleted: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { androidx.compose.material3.SnackbarHostState() }
    var title by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var ingredients by remember { mutableStateOf(listOf<IngredientEntity>()) }
    var steps by remember { mutableStateOf(listOf<String>()) }
    var servings by remember { mutableStateOf(4.0) }
    var isFavorite by remember { mutableStateOf(false) }
    var rating by remember { mutableStateOf<Double?>(null) }
    var prepMinutes by remember { mutableStateOf<Int?>(null) }
    var cookMinutes by remember { mutableStateOf<Int?>(null) }
    var source by remember { mutableStateOf("") }
    var sourceUrl by remember { mutableStateOf("") }
    var categories by remember { mutableStateOf(listOf<String>()) }
    var photoThumb by remember { mutableStateOf<String?>(null) }
    var showDelete by remember { mutableStateOf(false) }
    var deleteError by remember { mutableStateOf<String?>(null) }
    var nutritionText by remember { mutableStateOf("") }
    var nutritionExpanded by remember { mutableStateOf(true) }
    LaunchedEffect(recipeId) {
        val r = container.db.recipes().byId(recipeId)
        if (r != null) {
            title = r.title
            description = r.recipeDescription
            servings = r.servings
            isFavorite = r.isFavorite
            rating = r.rating
            prepMinutes = r.prepMinutes
            cookMinutes = r.cookMinutes
            source = r.source
            sourceUrl = r.sourceUrl
            nutritionText = r.nutritionText
            photoThumb = r.photoThumb?.takeIf { it.isNotBlank() } ?: r.photoOriginal
            categories = runCatching {
                kotlinx.serialization.json.Json.parseToJsonElement(r.categoriesJson)
                    .jsonArray.map { it.jsonPrimitive.content }
            }.getOrDefault(emptyList())
            ingredients = container.db.ingredients().forRecipe(recipeId)
            steps = container.db.steps().forRecipe(recipeId).map { it.text }
        }
    }
    fun shareRecipe() {
        val text = buildString {
            appendLine(title)
            appendLine("Serves ${fractionDisplayString(servings)}")
            if (sourceUrl.isNotBlank()) appendLine(sourceUrl)
            if (ingredients.isNotEmpty()) {
                appendLine()
                appendLine("Ingredients")
                ingredients.forEach { ing ->
                    val line = ingredientFullLine(ing.display, ing.name)
                    val header = isIngredientHeaderRow(ing.quantity, ing.unit, line)
                    appendLine(if (header) line else "• $line")
                }
            }
            steps.forEachIndexed { i, s ->
                if (i == 0) appendLine()
                if (i == 0) appendLine("Steps")
                appendLine("${i + 1}. $s")
            }
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, title)
            putExtra(Intent.EXTRA_TEXT, text)
        }
        context.startActivity(Intent.createChooser(send, "Share recipe"))
    }
    Scaffold(
        snackbarHost = { androidx.compose.material3.SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = { Text(title.ifBlank { "Recipe" }) },
                navigationIcon = {
                    androidx.compose.material3.IconButton(onClick = onBack) {
                        androidx.compose.material3.Icon(
                            Icons.Filled.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
                actions = {
                    androidx.compose.material3.IconButton(onClick = { onEdit(recipeId) }) {
                        androidx.compose.material3.Icon(Icons.Filled.Edit, contentDescription = "Edit")
                    }
                    androidx.compose.material3.IconButton(onClick = ::shareRecipe) {
                        androidx.compose.material3.Icon(Icons.Filled.Share, contentDescription = "Share")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).padding(16.dp).verticalScroll(rememberScrollState())) {
            if (title.isBlank()) {
                Text("Recipe not found.", style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = onBack) { Text("Back") }
                return@Column
            }
            // Signed resolution: R2 storage keys are minted into short-lived
            // download URLs (GET /photos/sign, cached until expiry), absolute
            // URIs pass through. While resolving (or on failure) show the
            // placeholder; a Coil error invalidates the entry and retries once.
            val photoCache = remember(container) { photoCacheFor(container) }
            var thumbUrl by remember(photoThumb) { mutableStateOf<String?>(null) }
            var resolveGen by remember(photoThumb) { mutableStateOf(0) }
            LaunchedEffect(photoThumb, resolveGen) {
                thumbUrl = photoThumb?.let { resolveRecipePhoto(container, it, photoCache) }
            }
            if (!photoThumb.isNullOrBlank()) {
                if (thumbUrl != null) {
                    AsyncImage(
                        model = thumbUrl,
                        contentDescription = "Recipe photo",
                        contentScale = ContentScale.Crop,
                        placeholder = rememberVectorPainter(Icons.Filled.Image),
                        error = rememberVectorPainter(Icons.Filled.Image),
                        onError = {
                            if (resolveGen == 0) {
                                invalidateSignedPhoto(photoThumb, photoCache)
                                resolveGen = 1
                            }
                        },
                        modifier = Modifier.fillMaxWidth().height(200.dp)
                            .clip(RoundedCornerShape(16.dp)),
                    )
                } else {
                    Box(
                        modifier = Modifier.fillMaxWidth().height(200.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(MaterialTheme.colorScheme.surfaceContainerHighest),
                        contentAlignment = Alignment.Center,
                    ) {
                        androidx.compose.material3.Icon(
                            Icons.Filled.Image,
                            contentDescription = "Loading photo",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(48.dp),
                        )
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
            if (description.isNotBlank()) Text(description, style = MaterialTheme.typography.bodyMedium)
            rating?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.material3.Icon(
                        Icons.Filled.Star,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("$it / 5", style = MaterialTheme.typography.labelMedium)
                }
            }
            val canOpen = sourceUrl.trim().lowercase().let {
                it.startsWith("http://") || it.startsWith("https://")
            }
            if (source.isNotBlank() || sourceUrl.isNotBlank()) {
                Text(
                    text = source.ifBlank { sourceUrl },
                    style = MaterialTheme.typography.labelMedium,
                    color = if (canOpen) MaterialTheme.colorScheme.primary
                    else MaterialTheme.typography.labelMedium.color,
                    modifier = if (canOpen) {
                        Modifier.clickable {
                            runCatching {
                                context.startActivity(
                                    Intent(
                                        Intent.ACTION_VIEW,
                                        android.net.Uri.parse(sourceUrl.trim()),
                                    ),
                                )
                            }
                        }
                    } else Modifier,
                )
            }
            if (categories.isNotEmpty()) {
                Text(
                    "Categories: ${categories.joinToString(", ")}",
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            Text(
                "Serves ${fractionDisplayString(servings)}",
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.padding(top = 8.dp, bottom = if (prepMinutes != null || cookMinutes != null) 0.dp else 8.dp),
            )
            if (prepMinutes != null || cookMinutes != null) {
                val total = (prepMinutes ?: 0) + (cookMinutes ?: 0)
                Text(
                    buildString {
                        prepMinutes?.let { append("Prep ${formatMinutes(it)}") }
                        if (prepMinutes != null && cookMinutes != null) append(" · ")
                        cookMinutes?.let { append("Cook ${formatMinutes(it)}") }
                        append(" · Total ${formatMinutes(total)}")
                    },
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = {
                    scope.launch {
                        val row = container.db.recipes().byId(recipeId) ?: return@launch
                        val now = System.currentTimeMillis()
                        val did = container.syncEngine.deviceId()
                        val updated = row.copy(isFavorite = !row.isFavorite, updatedAt = now, deviceId = did)
                        container.db.recipes().upsert(updated)
                        isFavorite = updated.isFavorite
                        // Complete snapshot (protocol: a non-shell recipe
                        // envelope is the sender's full snapshot). A sparse
                        // envelope would wipe the server's stored scalars,
                        // which default on absent keys.
                        val ings = container.db.ingredients().forRecipe(row.id)
                        val steps = container.db.steps().forRecipe(row.id)
                        val cats = runCatching {
                            Json.parseToJsonElement(row.categoriesJson).jsonArray
                        }.getOrDefault(JsonArray(emptyList()))
                        container.syncEngine.enqueue(
                            SyncEnvelopeDto(
                                id = row.id,
                                updatedAt = Instant.ofEpochMilli(now).toString(),
                                deviceId = did,
                                entity = "recipe",
                                payload = buildJsonObject {
                                    put("id", row.id)
                                    put("householdId", row.householdId)
                                    put("title", row.title)
                                    put("description", row.recipeDescription)
                                    put("servings", row.servings)
                                    updated.prepMinutes?.let { put("prepMinutes", it) }
                                    updated.cookMinutes?.let { put("cookMinutes", it) }
                                    updated.rating?.let { put("rating", it) }
                                    put("isFavorite", updated.isFavorite)
                                    put("source", row.source)
                                    put("sourceUrl", row.sourceUrl)
                                    put("categories", cats)
                                    put("photoKeys", buildJsonObject {
                                        put("original", row.photoOriginal ?: "")
                                        put("large1024", row.photoLarge1024 ?: "")
                                        put("thumb", row.photoThumb ?: "")
                                    })
                                    put("ingredients", JsonArray(ings.map { ing ->
                                        buildJsonObject {
                                            put("id", ing.id)
                                            put("name", ing.name)
                                            ing.quantity?.let { put("quantity", it) }
                                            put("unit", ing.unit)
                                            put("display", ing.display)
                                            put("position", ing.position)
                                        }
                                    }))
                                    put("steps", JsonArray(steps.map { st ->
                                        buildJsonObject {
                                            put("id", st.id)
                                            put("position", st.position)
                                            put("text", st.text)
                                            put("timers", runCatching {
                                                Json.parseToJsonElement(st.timersJson).jsonArray
                                            }.getOrDefault(JsonArray(emptyList())))
                                        }
                                    }))
                                },
                            ),
                        )
                    }
                }) {
                    Icon(
                        imageVector = if (isFavorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                        contentDescription = if (isFavorite) "Remove from favorites" else "Mark as favorite",
                    )
                }
                Text(if (isFavorite) "★ Favorite" else "Mark as favorite")
            }
            Button(onClick = { onCook(recipeId) }, modifier = Modifier.fillMaxWidth()) {
                Text("Start Cooking")
            }
            OutlinedButton(
                onClick = { onEdit(recipeId) },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            ) {
                Text("Edit")
            }
            Text("Ingredients", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 12.dp))
            ingredients.forEach { ing ->
                val line = ing.display.ifBlank { ing.name }
                if (isIngredientHeaderRow(ing.quantity, ing.unit, line)) {
                    Text(
                        line,
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                } else {
                    Text("• $line", style = MaterialTheme.typography.bodyMedium)
                }
            }
            Card(modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Nutrition", style = MaterialTheme.typography.titleSmall)
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = { nutritionExpanded = !nutritionExpanded }) {
                            Text(if (nutritionExpanded) "Hide" else "Show")
                        }
                    }
                    if (nutritionExpanded) {
                        Text(
                            nutritionText.ifBlank { "No nutrition info yet." },
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
            Text("Steps", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 12.dp))
            steps.forEachIndexed { i, s -> Text("${i + 1}. $s", style = MaterialTheme.typography.bodyMedium) }
            TextButton(
                onClick = { showDelete = true },
                modifier = Modifier.padding(top = 16.dp),
            ) {
                androidx.compose.material3.Icon(
                    Icons.Filled.Delete,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                )
                Spacer(Modifier.width(4.dp))
                Text("Delete recipe", color = MaterialTheme.colorScheme.error)
            }
        }
    }
    if (showDelete) {
        AlertDialog(
            onDismissRequest = { showDelete = false },
            title = { Text("Delete recipe?") },
            text = { Text("“$title” will be removed on this device and the delete will sync.") },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        // Pop only after a successful tombstone + enqueue so a
                        // failed delete stays visible; surface the failure.
                        runCatching { onDelete(recipeId) }
                            .onSuccess { showDelete = false; onDeleted() }
                            .onFailure { e ->
                                showDelete = false
                                deleteError = "Couldn't delete (${e.message ?: "unknown error"}). Try again."
                            }
                    }
                }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { showDelete = false }) { Text("Cancel") } },
        )
    }
    deleteError?.let { message ->
        LaunchedEffect(message) {
            snackbar.showSnackbar(message)
            deleteError = null
        }
    }
}
