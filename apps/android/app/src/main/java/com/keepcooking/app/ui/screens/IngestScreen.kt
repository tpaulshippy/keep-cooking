package com.keepcooking.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.keepcooking.app.ingest.ClipClient
import com.keepcooking.app.ingest.ClipClientError
import com.keepcooking.app.ingest.ClipReport
import com.keepcooking.app.ingest.ClipRequest
import com.keepcooking.app.ingest.ClipSource
import com.keepcooking.app.ingest.ClipboardDetector
import com.keepcooking.app.ingest.IngredientParser
import com.keepcooking.app.ingest.OcrSplitter
import com.keepcooking.app.ingest.cleanTitle
import com.keepcooking.app.ingest.clipServerErrorMessage
import com.keepcooking.app.ingest.clipWarningText
import com.keepcooking.app.ingest.isSavableTitle
import com.keepcooking.app.sync.DeviceAuthInterceptor
import kotlinx.coroutines.launch

/**
 * Ingest tab — parity with iOS ClipView.swift, CaptionsImportView.swift,
 * OCRScanView.swift, ClipboardBanner.swift.
 *
 * Tabs: Clip (URL → preview → save), Captions (tiktok/instagram/youtube),
 * OCR (paste/scan text → splitter → save). A clipboard banner sits above
 * the tabs when pasted text looks like a recipe link. Saving is delegated
 * to [onSaveRecipe] so Room wiring stays in one place.
 */
data class IngestDraft(
    val title: String,
    val ingredientLines: List<String>,
    val stepLines: List<String>,
    val source: String,
    val sourceUrl: String,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IngestScreen(
    baseUrl: String = "https://keep-cooking-api.pshippy-245.workers.dev/",
    clipboardText: String? = null,
    onSaveRecipe: suspend (IngestDraft) -> String = { "Saved “${it.title}”" },
    // Fresh device-auth state per request (enroll may complete after
    // composition). Signs the mutating clip POST; a null state fails fast in
    // ClipClient instead of sending an unsigned POST the server rejects.
    deviceState: () -> DeviceAuthInterceptor.State? = { null },
    // Suspends until enrollment is ensured (DeviceAuth.ensure): awaited on
    // submit so a first-tap clip races enrollment instead of sending null.
    // Falls back to [deviceState] when null (previews/tests).
    ensureDeviceState: (suspend () -> DeviceAuthInterceptor.State?)? = null,
) {
    var tab by remember { mutableStateOf(0) }
    var bannerUrl by remember(clipboardText) {
        mutableStateOf(clipboardText?.let { ClipboardDetector.firstUrl(it) })
    }
    var bannerDismissed by remember { mutableStateOf<String?>(null) }
    var clipPrefill by remember { mutableStateOf<String?>(null) }

    Scaffold(topBar = { TopAppBar(title = { Text("Ingest") }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            val showBanner = bannerUrl != null && bannerUrl != bannerDismissed
            if (showBanner) {
                Card(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text("Clip this link?", style = MaterialTheme.typography.titleSmall)
                            Text(bannerUrl!!, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                        }
                        Button(onClick = { clipPrefill = bannerUrl; bannerUrl = null; tab = 0 }) { Text("Clip") }
                        TextButton(onClick = { bannerDismissed = bannerUrl; bannerUrl = null }) { Text("Dismiss") }
                    }
                }
            }
            TabRow(selectedTabIndex = tab) {
                listOf("Clip link", "Captions", "OCR scan").forEachIndexed { i, t ->
                    Tab(selected = tab == i, onClick = { tab = i }, text = { Text(t) })
                }
            }
            when (tab) {
                0 -> ClipTab(baseUrl = baseUrl, prefill = clipPrefill, onSaveRecipe = onSaveRecipe, deviceState = deviceState, ensureDeviceState = ensureDeviceState)
                1 -> CaptionsTab(baseUrl = baseUrl, onSaveRecipe = onSaveRecipe, deviceState = deviceState, ensureDeviceState = ensureDeviceState)
                2 -> OcrTab(onSaveRecipe = onSaveRecipe)
            }
        }
    }
}

@Composable
private fun ClipTab(
    baseUrl: String,
    prefill: String?,
    onSaveRecipe: suspend (IngestDraft) -> String,
    deviceState: () -> DeviceAuthInterceptor.State? = { null },
    ensureDeviceState: (suspend () -> DeviceAuthInterceptor.State?)? = null,
) {
    var urlText by remember(prefill) { mutableStateOf(prefill ?: "") }
    var report by remember { mutableStateOf<ClipReport?>(null) }
    var isLoading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var reportStale by remember { mutableStateOf(false) }
    var savedMessage by remember { mutableStateOf<String?>(null) }
    var title by remember { mutableStateOf("") }
    var ingredientLines by remember { mutableStateOf("") }
    var stepLines by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        StepHeader(current = if (savedMessage != null) 2 else if (report != null) 1 else 0)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("1 · Add a link", style = MaterialTheme.typography.titleSmall)
                Text("Paste a recipe link below and we'll pull in the details.", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(value = urlText, onValueChange = { urlText = it }, label = { Text("Recipe link") }, modifier = Modifier.fillMaxWidth(), singleLine = true, enabled = !isLoading)
                Button(
                    onClick = {
                        scope.launch {
                            isLoading = true; error = null; savedMessage = null; reportStale = false
                            try {
                                // Await enrollment first: startup enroll runs
                                // async and a first-tap submit would otherwise
                                // sample null and fail. Residual null still
                                // fails fast inside ClipClient (never unsigned).
                                val auth = ensureDeviceState?.invoke() ?: deviceState()
                                val client = ClipClient(baseUrl = baseUrl, deviceState = auth)
                                val rep = client.clip(ClipRequest(url = urlText.trim(), source = ClipSource.URL))
                                report = rep
                                title = rep.recipe.title
                                ingredientLines = (rep.recipe.ingredients ?: emptyList()).joinToString("\n") { it.display ?: it.name }
                                stepLines = (rep.recipe.steps ?: emptyList()).joinToString("\n") { it.text }
                            } catch (e: Exception) {
                                reportStale = report != null
                                val code = (e as? ClipClientError.HttpStatus)?.status
                                error = clipServerErrorMessage(code) ?: "Couldn't clip that link. Check the address and try again."
                            } finally {
                                isLoading = false
                            }
                        }
                    },
                    enabled = !isLoading && urlText.isBlank().not(),
                ) { Text(if (isLoading) "Clipping…" else "Clip recipe") }
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        report?.let { rep ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("2 · Review and save", style = MaterialTheme.typography.titleSmall)
                    rep.warnings?.forEach { w -> Text(clipWarningText(w), style = MaterialTheme.typography.bodySmall) }
                    OutlinedTextField(value = title, onValueChange = { title = it }, label = { Text("Title") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(value = ingredientLines, onValueChange = { ingredientLines = it }, label = { Text("Ingredients") }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                    OutlinedTextField(value = stepLines, onValueChange = { stepLines = it }, label = { Text("Steps") }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                    val canSave = isSavableTitle(title)
                    Button(
                        onClick = {
                            scope.launch {
                                savedMessage = onSaveRecipe(
                                    IngestDraft(
                                        title = cleanTitle(title),
                                        ingredientLines = ingredientLines.split("\n").map { it.trim() }.filter { it.isNotEmpty() },
                                        stepLines = stepLines.split("\n").map { it.trim() }.filter { it.isNotEmpty() },
                                        source = rep.recipe.source ?: "clip",
                                        sourceUrl = rep.recipe.sourceUrl ?: urlText,
                                    ),
                                )
                            }
                        },
                        enabled = canSave && savedMessage == null && !isLoading && !reportStale,
                    ) { Text("Save recipe") }
                    if (!canSave) Text("Add a title to save.", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        savedMessage?.let { Text(it, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyMedium) }
    }
}

@Composable
private fun CaptionsTab(
    baseUrl: String,
    onSaveRecipe: suspend (IngestDraft) -> String,
    deviceState: () -> DeviceAuthInterceptor.State? = { null },
    ensureDeviceState: (suspend () -> DeviceAuthInterceptor.State?)? = null,
) {
    var platform by remember { mutableStateOf(ClipSource.TIKTOK) }
    var linkText by remember { mutableStateOf("") }
    var captionText by remember { mutableStateOf("") }
    var report by remember { mutableStateOf<ClipReport?>(null) }
    var isLoading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var reportStale by remember { mutableStateOf(false) }
    var savedMessage by remember { mutableStateOf<String?>(null) }
    var title by remember { mutableStateOf("") }
    var ingredientLines by remember { mutableStateOf("") }
    var stepLines by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    // Live local parse preview before server round-trip.
    val livePreview = remember(captionText, report) {
        if (report == null && captionText.isNotBlank()) {
            IngredientParser.parseLines(captionText).joinToString("\n") { it.display }
        } else null
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        StepHeader(current = if (savedMessage != null) 2 else if (report != null) 1 else 0)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("1 · Add a video", style = MaterialTheme.typography.titleSmall)
                Text("Pick where the video is from, then paste its caption.", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(ClipSource.TIKTOK to "TikTok", ClipSource.INSTAGRAM to "Instagram", ClipSource.YOUTUBE to "YouTube").forEach { (s, label) ->
                        FilterChip(selected = platform == s, onClick = { platform = s }, label = { Text(label) }, enabled = !isLoading)
                    }
                }
                OutlinedTextField(value = linkText, onValueChange = { linkText = it }, label = { Text("Video link (optional)") }, modifier = Modifier.fillMaxWidth(), singleLine = true, enabled = !isLoading)
                OutlinedTextField(value = captionText, onValueChange = { captionText = it }, label = { Text("Caption") }, modifier = Modifier.fillMaxWidth(), minLines = 4, enabled = !isLoading)
                livePreview?.let { Text("Preview:\n$it", style = MaterialTheme.typography.bodySmall) }
                Button(
                    onClick = {
                        scope.launch {
                            isLoading = true; error = null; savedMessage = null; reportStale = false
                            try {
                                val req = ClipRequest(
                                    url = linkText.trim().ifEmpty { null },
                                    caption = captionText,
                                    source = platform,
                                )
                                // Await enrollment first (see ClipTab): a null
                                // state fails fast in ClipClient, never unsigned.
                                val auth = ensureDeviceState?.invoke() ?: deviceState()
                                val rep = ClipClient(baseUrl = baseUrl, deviceState = auth).clip(req)
                                report = rep
                                title = rep.recipe.title
                                val ings = rep.recipe.ingredients ?: emptyList()
                                ingredientLines = if (ings.isEmpty()) {
                                    IngredientParser.parseLines(captionText).joinToString("\n") { it.display }
                                } else {
                                    ings.joinToString("\n") { it.display ?: it.name }
                                }
                                stepLines = (rep.recipe.steps ?: emptyList()).joinToString("\n") { it.text }
                            } catch (e: Exception) {
                                reportStale = report != null
                                val code = (e as? ClipClientError.HttpStatus)?.status
                                error = clipServerErrorMessage(code) ?: "Couldn't import that caption. Check the text and try again."
                            } finally {
                                isLoading = false
                            }
                        }
                    },
                    enabled = !isLoading && captionText.isBlank().not(),
                ) { Text(if (isLoading) "Importing…" else "Import caption") }
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        report?.let { rep ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("2 · Review and save", style = MaterialTheme.typography.titleSmall)
                    OutlinedTextField(value = title, onValueChange = { title = it }, label = { Text("Title") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(value = ingredientLines, onValueChange = { ingredientLines = it }, label = { Text("Ingredients") }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                    OutlinedTextField(value = stepLines, onValueChange = { stepLines = it }, label = { Text("Steps") }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                    val canSave = isSavableTitle(title)
                    Button(
                        onClick = {
                            scope.launch {
                                savedMessage = onSaveRecipe(
                                    IngestDraft(
                                        title = cleanTitle(title),
                                        ingredientLines = ingredientLines.split("\n").map { it.trim() }.filter { it.isNotEmpty() },
                                        stepLines = stepLines.split("\n").map { it.trim() }.filter { it.isNotEmpty() },
                                        source = "caption:${platform.raw.lowercase()}",
                                        sourceUrl = linkText,
                                    ),
                                )
                            }
                        },
                        enabled = canSave && savedMessage == null && !isLoading && !reportStale,
                    ) { Text("Save recipe") }
                    if (!canSave) Text("Add a title to save.", style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        savedMessage?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
    }
}

@Composable
private fun OcrTab(onSaveRecipe: suspend (IngestDraft) -> String) {
    val scope = rememberCoroutineScope()
    var recognizedText by remember { mutableStateOf("") }
    var title by remember { mutableStateOf("") }
    var ingredientLines by remember { mutableStateOf("") }
    var stepLines by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf<String?>(null) }
    var savedMessage by remember { mutableStateOf<String?>(null) }

    fun parse() {
        val draft = OcrSplitter.split(recognizedText.split("\n"))
        savedMessage = null
        title = draft.title
        ingredientLines = draft.ingredientLines.joinToString("\n")
        stepLines = draft.stepLines.joinToString("\n")
        notice = "Checked on this device."
    }

    val stepIndex = if (savedMessage != null) 2 else if (title.isNotEmpty() || ingredientLines.isNotEmpty()) 1 else 0
    val canSave = isSavableTitle(title)

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        StepHeader(current = stepIndex)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("1 · Add text", style = MaterialTheme.typography.titleSmall)
                Text("Paste photo text below — on-device ML Kit / OCR wiring fills this in automatically when available.", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(value = recognizedText, onValueChange = { recognizedText = it }, label = { Text("Recognized text") }, modifier = Modifier.fillMaxWidth(), minLines = 4)
                Button(onClick = { parse() }) { Text("Parse text") }
            }
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("2 · Review and save", style = MaterialTheme.typography.titleSmall)
                Text("Check the details below — the first line becomes the title.", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(value = title, onValueChange = { title = it }, label = { Text("Title") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = ingredientLines, onValueChange = { ingredientLines = it }, label = { Text("Ingredients") }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                OutlinedTextField(value = stepLines, onValueChange = { stepLines = it }, label = { Text("Steps") }, modifier = Modifier.fillMaxWidth(), minLines = 3)
            }
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("3 · Save", style = MaterialTheme.typography.titleSmall)
                Text(
                    notice ?: if (title.isEmpty() && ingredientLines.isEmpty()) "Add text or parse to begin." else "Checked on this device.",
                    style = MaterialTheme.typography.bodySmall,
                )
                Button(
                    onClick = {
                        scope.launch {
                            savedMessage = onSaveRecipe(
                                IngestDraft(
                                    title = cleanTitle(title),
                                    ingredientLines = ingredientLines.split("\n").map { it.trim() }.filter { it.isNotEmpty() },
                                    stepLines = stepLines.split("\n").map { it.trim() }.filter { it.isNotEmpty() },
                                    source = "ocr",
                                    sourceUrl = "",
                                ),
                            )
                            notice = null
                        }
                    },
                    enabled = canSave && savedMessage == null,
                ) { Text("Save recipe") }
                if (!canSave) Text("Add a title to save.", style = MaterialTheme.typography.bodySmall)
                savedMessage?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
            }
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun StepHeader(current: Int) {
    val labels = listOf("Add", "Review", "Save")
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        labels.forEachIndexed { i, label ->
            val active = i <= current
            Text(
                "${i + 1} · $label",
                style = MaterialTheme.typography.labelLarge,
                color = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
