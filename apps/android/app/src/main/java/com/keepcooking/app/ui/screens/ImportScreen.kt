package com.keepcooking.app.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.keepcooking.app.AppContainer
import com.keepcooking.app.import.IMPORT_EXTENSIONS
import com.keepcooking.app.import.ParsedFile
import com.keepcooking.app.import.RecipeFileParser
import com.keepcooking.app.import.importParsed
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

/**
 * File import UI — Paprika native (`.paprikarecipe`/`.paprikarecipes`), Paprika
 * YAML, and the P1 third-party formats Paprika imports (spec
 * /tmp/paprika-spec.md §4).
 *
 * Flow: SAF picker ([ActivityResultContracts.OpenDocument]) → bytes → try the
 * API import endpoint ([com.keepcooking.app.network.ApiService.importPaprika]),
 * fall back to the offline on-device parser ([RecipeFileParser]) → upsert into
 * Room ([importParsed]) → result snackbar (imported / updated / warnings).
 * Cookbook destination folds into categories (Menu-or-categories fallback,
 * spec §1.3); “Import cookbooks” creates Menu rows for file cookbooks.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportScreen(container: AppContainer) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var fileName by remember { mutableStateOf("") }
    var menus by remember { mutableStateOf(listOf<Pair<String, String>>()) }
    var selectedMenuId by remember { mutableStateOf<String?>(null) }
    var menuExpanded by remember { mutableStateOf(false) }
    var importCookbooks by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var lastResult by remember { mutableStateOf("") }
    var lastWarnings by remember { mutableStateOf(listOf<String>()) }

    LaunchedEffect(Unit) {
        scope.launch {
            menus = container.db.menus().liveMenus().map { it.id to it.name }
        }
    }

    suspend fun readBytes(uri: Uri): Pair<String, ByteArray>? = withContext(Dispatchers.IO) {
        val name = uri.lastPathSegment?.substringAfterLast('/')
            ?.substringAfterLast("%2F")?.substringAfterLast(':')
            ?: "import"
        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: return@withContext null
        name to bytes
    }

    fun importBytes(name: String, bytes: ByteArray) {
        scope.launch {
            busy = true
            lastWarnings = emptyList()
            try {
                // 1. Prefer server-side import when the route exists…
                val viaApi = runCatching {
                    val req = buildJsonObject {
                        put("fileName", name)
                        put("contentBase64", Base64.getEncoder().encodeToString(bytes))
                        val menuId = selectedMenuId
                        menus.firstOrNull { (id, _) -> id == menuId }
                            ?.let { put("cookbook", it.second) }
                        put("importCookbooks", importCookbooks)
                    }
                    apiImport(container, req)
                }.getOrNull()
                // 2. …otherwise parse fully offline (works without connectivity).
                val parsed: ParsedFile = viaApi ?: withContext(Dispatchers.Default) {
                    RecipeFileParser.parse(name, bytes)
                }
                val targetCookbook = selectedMenuId?.let { id ->
                    menus.firstOrNull { (mid, _) -> mid == id }?.second
                }
                val result = importParsed(
                    db = container.db,
                    deviceId = container.syncEngine.deviceId(),
                    parsed = parsed,
                    targetCookbook = targetCookbook,
                    importCookbooks = importCookbooks,
                    enqueue = { container.syncEngine.enqueue(it) },
                )
                lastResult = "Imported ${result.imported}, updated ${result.updated} from $name."
                lastWarnings = result.warnings
                val warnSuffix = if (result.warnings.isEmpty()) "" else " (${result.warnings.size} warnings)"
                snackbar.showSnackbar(lastResult + warnSuffix)
            } catch (e: Exception) {
                lastResult = "Import failed: ${e.message ?: "unknown error"}."
                snackbar.showSnackbar(lastResult)
            } finally {
                busy = false
            }
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val ext = uri.lastPathSegment?.substringAfterLast('.', "")?.lowercase().orEmpty()
        if (ext.isNotBlank() && ext !in IMPORT_EXTENSIONS) {
            scope.launch {
                lastResult = "“.$ext” is not a supported import format."
                snackbar.showSnackbar(lastResult)
            }
            return@rememberLauncherForActivityResult
        }
        scope.launch {
            val (name, bytes) = readBytes(uri) ?: run {
                snackbar.showSnackbar("Could not read that file.")
                return@launch
            }
            fileName = name
            importBytes(name, bytes)
        }
    }

    val selectedMenuName = selectedMenuId?.let { id -> menus.firstOrNull { (mid, _) -> mid == id }?.second }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Import") }) },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp).verticalScroll(rememberScrollState()),
        ) {
            Text("Recipe file")
            Text(
                "Paprika (.paprikarecipe/.paprikarecipes), YAML (.yml/.yaml), plus " +
                    "MasterCook, MealMaster, Living Cookbook, Pepperplate, Copy Me That, " +
                    "Yum XML and other formats Paprika imports.",
                modifier = Modifier.padding(bottom = 8.dp),
            )
            Button(
                onClick = { picker.launch(arrayOf("*/*")) },
                enabled = !busy,
            ) { Text(if (busy) "Importing…" else "Choose file") }
            if (fileName.isNotBlank()) Text("Selected: $fileName", modifier = Modifier.padding(top = 4.dp))
            Text("Cookbook", modifier = Modifier.padding(top = 16.dp))
            Box {
                OutlinedTextField(
                    value = selectedMenuName ?: "No cookbook (keep file tags)",
                    onValueChange = {},
                    readOnly = true,
                    trailingIcon = {
                        IconButton(
                            onClick = { menuExpanded = !menuExpanded },
                            modifier = Modifier.semantics { contentDescription = "Choose cookbook" },
                        ) { Text(if (menuExpanded) "▴" else "▾") }
                    },
                    modifier = Modifier.fillMaxWidth().clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = { menuExpanded = true },
                    ),
                )
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                    DropdownMenuItem(text = { Text("No cookbook (keep file tags)") }, onClick = {
                        selectedMenuId = null
                        menuExpanded = false
                    })
                    menus.forEach { (id, name) ->
                        DropdownMenuItem(text = { Text(name) }, onClick = {
                            selectedMenuId = id
                            menuExpanded = false
                        })
                    }
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(top = 8.dp).clickable { importCookbooks = !importCookbooks },
            ) {
                Checkbox(checked = importCookbooks, onCheckedChange = { importCookbooks = it })
                Text("Import cookbooks from file (creates cookbook entries)")
            }
            if (lastResult.isNotBlank()) {
                Text(lastResult, modifier = Modifier.padding(top = 12.dp))
            }
            lastWarnings.forEach { w ->
                Text("• $w", modifier = Modifier.padding(top = 4.dp))
            }
            Spacer(Modifier.padding(8.dp))
        }
    }
}

/**
 * Server-side import attempt. Returns null on any failure (route missing,
 * offline, bad payload) so the caller falls back to offline parsing.
 * Exported for tests.
 */
suspend fun apiImport(container: AppContainer, request: JsonObject): ParsedFile? {
    return try {
        val res = container.api.importPaprika(null, request)
        val recipes = (res["recipes"] as? JsonArray)
            ?.mapNotNull { it as? JsonObject }
            ?.map { RecipeFileParser.jsonToParsed("server", it, mutableListOf()).recipes.firstOrNull() }
            ?.filterNotNull()
            ?: return null
        val warnings = (res["warnings"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            .orEmpty()
        ParsedFile(recipes, warnings = warnings)
    } catch (_: Exception) {
        null
    }
}
