package com.keepcooking.app.ui.screens

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.keepcooking.app.AppContainer
import com.keepcooking.app.export.ExportFormat
import com.keepcooking.app.export.yamlFor
import kotlinx.coroutines.launch

/**
 * Export UI — parity with iOS multi-select Export/RecipeExportView.swift.
 * Multi-select recipe list + format chips + share file via ACTION_SEND.
 * Export is computed on-device from Room (works offline). No preview text
 * is shown in-app; the file content leaves via the share sheet only.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportScreen(container: AppContainer, initialRecipeId: String = "") {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var recipes by remember { mutableStateOf(listOf<Pair<String, String>>()) }
    var selectedIds by remember { mutableStateOf(setOf<String>()) }
    var initialized by remember { mutableStateOf(false) }
    var format by remember { mutableStateOf(ExportFormat.MD) }

    LaunchedEffect(Unit) {
        scope.launch {
            val live = container.db.recipes().liveRecipes()
            recipes = live.map { it.id to it.title }
            if (!initialized) {
                selectedIds = if (initialRecipeId.isNotBlank() && live.any { it.id == initialRecipeId }) {
                    setOf(initialRecipeId)
                } else {
                    live.map { it.id }.toSet()
                }
                initialized = true
            } else {
                // Drop ids that no longer exist (e.g. recipe deleted elsewhere).
                val valid = live.map { it.id }.toSet()
                selectedIds = selectedIds.intersect(valid)
            }
        }
    }

    val allSelected = recipes.isNotEmpty() && selectedIds.size == recipes.size

    Scaffold(topBar = { TopAppBar(title = { Text("Export") }) }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp).verticalScroll(rememberScrollState()),
        ) {
            Text("Recipes")
            if (recipes.isEmpty()) {
                Text("No recipes to export.", modifier = Modifier.padding(vertical = 8.dp))
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                ) {
                    Text(
                        "${selectedIds.size} of ${recipes.size} selected",
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = {
                        selectedIds = if (allSelected) emptySet() else recipes.map { it.first }.toSet()
                    }) {
                        Text(if (allSelected) "Clear" else "Select All")
                    }
                }
                recipes.forEach { (id, title) ->
                    val checked = selectedIds.contains(id)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().clickable {
                            selectedIds = if (checked) selectedIds - id else selectedIds + id
                        }.padding(vertical = 2.dp),
                    ) {
                        Checkbox(
                            checked = checked,
                            onCheckedChange = { on ->
                                selectedIds = if (on) selectedIds + id else selectedIds - id
                            },
                        )
                        Text(title, modifier = Modifier.padding(start = 8.dp))
                    }
                }
            }
            Row(
                Modifier.padding(vertical = 12.dp).horizontalScroll(rememberScrollState()),
            ) {
                ExportFormat.entries.forEach { f ->
                    FilterChip(
                        selected = format == f,
                        onClick = { format = f },
                        label = { Text(f.title) },
                        modifier = Modifier.padding(end = 8.dp),
                    )
                }
            }
            if (recipes.isNotEmpty() && selectedIds.isEmpty()) {
                Text("Select at least one recipe.", modifier = Modifier.padding(bottom = 8.dp))
            }
            Button(
                onClick = {
                    scope.launch {
                        val ids = selectedIds.toList()
                        if (ids.isEmpty()) return@launch
                        val loaded = ids.mapNotNull { container.recipeExporter.loadRecipe(container.db, it) }
                        if (loaded.isEmpty()) return@launch
                        val title = if (loaded.size == 1) loaded.first().title
                            else "export-${loaded.size}-recipes"
                        val file = if (format == ExportFormat.PAPRIKA) {
                            container.recipeExporter.writeCacheBytes(
                                format, title,
                                container.recipeExporter.toPaprikaZip(loaded),
                            )
                        } else {
                            val full = when (format) {
                                ExportFormat.JSON -> if (loaded.size == 1) {
                                    container.recipeExporter.toJson(loaded.first())
                                } else {
                                    "[" + loaded.joinToString(",") { container.recipeExporter.toJson(it) } + "]"
                                }
                                ExportFormat.HTML -> loaded.joinToString("\n<hr/>\n") {
                                    container.recipeExporter.toHtml(it)
                                }
                                ExportFormat.YAML -> if (loaded.size == 1) {
                                    container.recipeExporter.toYaml(loaded.first())
                                } else {
                                    loaded.joinToString(",", "[", "]") {
                                        yamlFor(it).trim().removePrefix("[").removeSuffix("]")
                                    }
                                }
                                ExportFormat.PAPRIKA -> "" // handled above
                                ExportFormat.MD -> loaded.joinToString("\n\n---\n\n") {
                                    container.recipeExporter.toMarkdown(it)
                                }
                            }
                            container.recipeExporter.writeCacheFile(format, title, full)
                        }
                        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = format.mime
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        context.startActivity(Intent.createChooser(send, "Share ${format.title} file"))
                    }
                },
                enabled = selectedIds.isNotEmpty(),
            ) { Text("Share file") }
        }
    }
}
