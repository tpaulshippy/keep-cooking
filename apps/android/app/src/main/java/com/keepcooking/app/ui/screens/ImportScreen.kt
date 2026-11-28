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
import com.keepcooking.app.network.ImportReportDto
import com.keepcooking.app.network.ImportRequestDto
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * File import UI — Paprika native (`.paprikarecipe`/`.paprikarecipes`), Paprika
 * YAML, and the P1 third-party formats Paprika imports (see
 * packages/contracts/openapi.yaml `POST /import` format enum and
 * api/src/import.ts).
 *
 * Flow: SAF picker ([ActivityResultContracts.OpenDocument]) → bytes → try the
 * API import endpoint ([com.keepcooking.app.network.ApiService.importFile]),
 * fall back to the offline on-device parser ([RecipeFileParser]) → upsert into
 * Room ([importParsed]) → result snackbar (imported / updated / warnings).
 * Cookbook destination folds into categories (Menu-or-categories fallback);
 * “Import cookbooks” creates Menu rows for file cookbooks.
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
    // Finding 1 (P2): server import succeeded but the follow-up sync failed,
    // so recipes are invisible locally. Kept true until a manual retry sync
    // succeeds — the result text reports partial success, not success.
    var syncRetryPending by remember { mutableStateOf(false) }

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
            syncRetryPending = false
            try {
                val targetCookbook = selectedMenuId?.let { id ->
                    menus.firstOrNull { (mid, _) -> mid == id }?.second
                }
                // SKIP-SERVER RULE (cubic findings 2+3): the live POST /import
                // has no cookbook/target field (api/src/import.ts ImportRequest
                // is format/filename/bytes/text/householdId only; the
                // importCookbooks flag is ignored server-side) and only parses
                // paprika-json/paprika-zip/yaml/html — P1 format values 415 and
                // unknown values (yum-xml/mcb/recipe-manager-txt/…) sniff as
                // YAML with 200 + 0 imported. So skip the server path when a
                // cookbook destination matters (a cookbook is selected, or
                // importCookbooks is on) or the format is not server-parseable,
                // and go straight to the offline parser + local upsert, which
                // applies the cookbook tag.
                val ext = name.substringAfterLast('.', "").lowercase()
                val needsLocalCookbook = targetCookbook != null || importCookbooks
                val serverReport = if (!needsLocalCookbook && serverImportFormat(ext) != null) {
                    runCatching {
                        apiImport(container, name, bytes, importCookbooks)
                    }.getOrNull()
                } else null
                // Finding 3: a zero-imported server report (sniffed-as-YAML 200
                // with nothing parsed) is a fallback trigger, not success.
                val usable = serverReport?.takeIf { it.imported > 0 || it.ids.isNotEmpty() }
                if (usable != null) {
                    // Finding 1: a failed follow-up sync must NOT report plain
                    // success — the recipes stay invisible locally. Report
                    // partial success and keep retryable state instead.
                    val syncOk = runCatching { container.syncEngine.sync() }.isSuccess
                    if (syncOk) {
                        lastResult = "Imported ${usable.imported} from $name."
                    } else {
                        syncRetryPending = true
                        lastResult = "Imported ${usable.imported} on server — sync failed, tap Retry Sync to show them locally."
                    }
                    lastWarnings = usable.warnings
                    val warnSuffix = if (usable.warnings.isEmpty()) "" else " (${usable.warnings.size} warnings)"
                    snackbar.showSnackbar(lastResult + warnSuffix)
                    return@launch
                }
                // 2. …otherwise parse fully offline (works without connectivity).
                val parsed: ParsedFile = withContext(Dispatchers.Default) {
                    RecipeFileParser.parse(name, bytes)
                }
                val result = importParsed(
                    db = container.db,
                    deviceId = container.syncEngine.deviceId(),
                    parsed = parsed,
                    targetCookbook = targetCookbook,
                    importCookbooks = importCookbooks,
                    enqueue = { container.syncEngine.enqueue(it) },
                )
                if (serverReport != null) {
                    // Server answered 200 but parsed nothing; the offline
                    // result below is what actually imported.
                    lastWarnings = listOf("Server import found no recipes; parsed on-device instead.")
                }
                lastResult = "Imported ${result.imported}, updated ${result.updated} from $name."
                lastWarnings = lastWarnings + result.warnings
                val warnSuffix = if (lastWarnings.isEmpty()) "" else " (${lastWarnings.size} warnings)"
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
            if (syncRetryPending) {
                Button(
                    onClick = {
                        scope.launch {
                            busy = true
                            try {
                                container.syncEngine.sync()
                                syncRetryPending = false
                                lastResult = "Sync recovered — imported recipes are now visible."
                                snackbar.showSnackbar(lastResult)
                            } catch (e: Exception) {
                                lastResult = "Sync failed again: ${e.message ?: "unknown error"}. Tap Retry Sync to try again."
                                snackbar.showSnackbar(lastResult)
                            } finally {
                                busy = false
                            }
                        }
                    },
                    enabled = !busy,
                    modifier = Modifier.padding(top = 8.dp),
                ) { Text(if (busy) "Syncing…" else "Retry Sync") }
            }
            lastWarnings.forEach { w ->
                Text("• $w", modifier = Modifier.padding(top = 4.dp))
            }
            Spacer(Modifier.padding(8.dp))
        }
    }
}

/**
 * Server-side import attempt (`POST /import` with `{ filename, payload
 * (base64), format?, householdId?, importCookbooks? }`; see
 * packages/contracts/openapi.yaml ImportRequest and api/src/import.ts).
 * Returns the server's [ImportReportDto] (`{ imported (count), ids,
 * warnings }`) on success, null on any failure (route missing, offline, bad
 * payload, 415/400) so the caller falls back to offline parsing.
 *
 * Conservative gate (cubic finding 3): only formats the live server parses
 * ([serverImportFormat] non-null) are attempted — anything else returns null
 * so the caller goes straight to the offline parser. Unknown format values
 * would otherwise sniff as YAML server-side and return 200 with 0 imported.
 * Exported for tests.
 */
suspend fun apiImport(
    container: AppContainer,
    filename: String,
    bytes: ByteArray,
    importCookbooks: Boolean = true,
): ImportReportDto? {
    return try {
        val ext = filename.substringAfterLast('.', "").lowercase()
        // Not server-parseable (P1/third-party xml/mcb/txt/…): skip the
        // server entirely — it would 415 or sniff-as-YAML with 0 imported.
        val format = serverImportFormat(ext) ?: return null
        val request = ImportRequestDto(
            filename = filename,
            payload = Base64.getEncoder().encodeToString(bytes),
            format = format,
            householdId = "hh-demo",
            importCookbooks = importCookbooks,
        )
        container.api.importFile(null, request)
    } catch (_: Exception) {
        null
    }
}

/** Map a file extension to a `POST /import` format value the live server
 * actually parses (api/src/import.ts: `paprika-json`/`paprika-zip`/`yaml`/
 * `html` plus its documented aliases). Anything else returns null so the
 * caller parses offline: P1 values (mx2/mxp/mz2/mmf/fdx/fdxz/…) get a server
 * 415 with re-export guidance, and unknown values (yum-xml/mcb/
 * recipe-manager-txt/…) sniff as YAML and return 200 with 0 imported —
 * neither is a usable server import. */
internal fun serverImportFormat(ext: String): String? = when (ext) {
    "paprikarecipe", "paprikarecipes", "zip" -> "paprika-zip"
    "json" -> "paprika-json"
    "yml", "yaml" -> "yaml"
    "html", "htm" -> "html"
    else -> null
}

/** Legacy alias kept for tests: same contract as [serverImportFormat]. */
internal fun importFormatForExtension(ext: String): String? = serverImportFormat(ext)
