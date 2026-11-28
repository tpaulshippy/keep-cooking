package com.keepcooking.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.keepcooking.app.AppContainer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Recipes tab — parity with iOS PhoneTabView Recipes tab.
 * Browse + search the Room recipe collection; tap through to the detail,
 * from which Cook launches. Clipping lives behind the + action.
 */
suspend fun loadLibraryRows(container: AppContainer): List<LibraryRecipeRow> {
    val live = container.db.recipes().liveRecipes()
    return live.map { r ->
        val ings = container.db.ingredients().forRecipe(r.id)
        val steps = container.db.steps().forRecipe(r.id)
        val cats = runCatching {
            Json.parseToJsonElement(r.categoriesJson).jsonArray.map { it.jsonPrimitive.content }
        }.getOrDefault(emptyList())
        LibraryRecipeRow(
            recipeId = r.id,
            title = r.title,
            recipeDescription = r.recipeDescription,
            servings = r.servings,
            prepMinutes = r.prepMinutes,
            cookMinutes = r.cookMinutes,
            rating = r.rating,
            isFavorite = r.isFavorite,
            source = r.source,
            categories = cats,
            ingredientNames = ings.map { it.name },
            stepTexts = steps.map { it.text },
            photoOriginal = r.photoOriginal,
            photoThumb = r.photoThumb,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecipesScreen(
    container: AppContainer,
    onRecipeClick: (String) -> Unit = {},
    onAddRecipe: () -> Unit = {},
) {
    var rows by remember { mutableStateOf(listOf<LibraryRecipeRow>()) }
    var query by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { rows = loadLibraryRows(container) }
    val shown = remember(rows, query) {
        val q = query.trim().lowercase()
        if (q.isBlank()) rows
        else rows.filter {
            it.title.lowercase().contains(q) ||
                it.recipeDescription.lowercase().contains(q) ||
                it.categories.any { c -> c.lowercase().contains(q) } ||
                it.ingredientNames.any { n -> n.lowercase().contains(q) }
        }
    }
    Scaffold(
        topBar = { TopAppBar(title = { Text("Recipes") }) },
        floatingActionButton = {
            FloatingActionButton(onClick = onAddRecipe) { Icon(Icons.Filled.Add, contentDescription = "Clip a recipe") }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text("Search recipes") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            if (shown.isEmpty()) {
                Text(
                    if (rows.isEmpty()) "No recipes yet — clip one with +."
                    else "No matches.",
                    modifier = Modifier.padding(top = 16.dp),
                )
            } else {
                LazyColumn(Modifier.fillMaxSize().padding(top = 8.dp)) {
                    items(shown, key = { it.recipeId }) { r ->
                        Card(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp)
                                .clickable { onRecipeClick(r.recipeId) },
                        ) {
                            Column(Modifier.padding(16.dp)) {
                                Text(
                                    if (r.isFavorite) "♥ ${r.title}" else r.title,
                                    style = MaterialTheme.typography.titleMedium,
                                )
                                if (r.recipeDescription.isNotBlank()) {
                                    Text(
                                        r.recipeDescription.take(120),
                                        style = MaterialTheme.typography.bodyMedium,
                                        maxLines = 2,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
