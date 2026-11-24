package com.keepcooking.app.ui.screens

import android.content.Intent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.keepcooking.app.AppContainer
import com.keepcooking.app.export.ExportFormat
import kotlinx.coroutines.launch

/**
 * Export UI — parity with iOS Export/RecipeExportView.swift.
 * Recipe picker + format segmented chips + live preview + share/save via
 * ACTION_SEND. Export is computed on-device from Room (works offline).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportScreen(container: AppContainer, initialRecipeId: String = "") {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var recipes by remember { mutableStateOf(listOf<Pair<String, String>>()) }
    var selectedId by remember { mutableStateOf(initialRecipeId) }
    var format by remember { mutableStateOf(ExportFormat.MD) }
    var preview by remember { mutableStateOf("") }
    var expanded by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        scope.launch {
            val live = container.db.recipes().liveRecipes()
            recipes = live.map { it.id to it.title }
            if (selectedId.isBlank()) selectedId = live.firstOrNull()?.id.orEmpty()
        }
    }

    LaunchedEffect(selectedId, format) {
        scope.launch {
            val loaded = container.recipeExporter.loadRecipe(container.db, selectedId)
            preview = when {
                loaded == null -> ""
                format == ExportFormat.JSON -> container.recipeExporter.toJson(loaded)
                format == ExportFormat.HTML -> container.recipeExporter.toHtml(loaded)
                else -> container.recipeExporter.toMarkdown(loaded)
            }.take(4000)
        }
    }

    val selectedTitle = recipes.firstOrNull { it.first == selectedId }?.second ?: ""

    Scaffold(topBar = { TopAppBar(title = { Text("Export") }) }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp).verticalScroll(rememberScrollState()),
        ) {
            Text("Recipe")
            Box {
                OutlinedTextField(
                    value = selectedTitle.ifBlank { "No recipes to export." },
                    onValueChange = {},
                    readOnly = true,
                    trailingIcon = {
                        IconButton(onClick = { expanded = !expanded }) {
                            Text(if (expanded) "▴" else "▾")
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    recipes.forEach { (id, title) ->
                        DropdownMenuItem(text = { Text(title) }, onClick = {
                            selectedId = id
                            expanded = false
                        })
                    }
                }
            }
            Row(Modifier.padding(vertical = 12.dp)) {
                ExportFormat.entries.forEach { f ->
                    FilterChip(
                        selected = format == f,
                        onClick = { format = f },
                        label = { Text(f.title) },
                        modifier = Modifier.padding(end = 8.dp),
                    )
                }
            }
            Text("Preview", modifier = Modifier.padding(bottom = 4.dp))
            Text(preview.ifBlank { "Nothing to export." }, modifier = Modifier.padding(bottom = 12.dp))
            Row {
                Button(
                    onClick = {
                        scope.launch {
                            val loaded = container.recipeExporter.loadRecipe(container.db, selectedId) ?: return@launch
                            val full = when (format) {
                                ExportFormat.JSON -> container.recipeExporter.toJson(loaded)
                                ExportFormat.HTML -> container.recipeExporter.toHtml(loaded)
                                ExportFormat.MD -> container.recipeExporter.toMarkdown(loaded)
                            }
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_SUBJECT, loaded.title)
                                putExtra(Intent.EXTRA_TEXT, full.take(100_000))
                            }
                            context.startActivity(Intent.createChooser(send, "Share ${format.title}"))
                        }
                    },
                    enabled = selectedId.isNotBlank(),
                ) { Text("Share text") }
                androidx.compose.foundation.layout.Spacer(Modifier.padding(4.dp))
                Button(
                    onClick = {
                        scope.launch {
                            val loaded = container.recipeExporter.loadRecipe(container.db, selectedId) ?: return@launch
                            val full = when (format) {
                                ExportFormat.JSON -> container.recipeExporter.toJson(loaded)
                                ExportFormat.HTML -> container.recipeExporter.toHtml(loaded)
                                ExportFormat.MD -> container.recipeExporter.toMarkdown(loaded)
                            }
                            val file = container.recipeExporter.writeCacheFile(format, loaded.title, full)
                            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = format.mime
                                putExtra(Intent.EXTRA_STREAM, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            context.startActivity(Intent.createChooser(send, "Share ${format.title} file"))
                        }
                    },
                    enabled = selectedId.isNotBlank(),
                ) { Text("Share file") }
            }
        }
    }
}
