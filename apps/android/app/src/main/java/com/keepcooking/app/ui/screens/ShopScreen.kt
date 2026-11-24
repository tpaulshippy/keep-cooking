package com.keepcooking.app.ui.screens

import android.util.Log
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.keepcooking.app.AppContainer
import com.keepcooking.app.data.ListItemEntity
import com.keepcooking.app.data.PantryItemEntity
import com.keepcooking.app.data.ShoppingListEntity
import com.keepcooking.app.network.SyncEnvelopeDto
import com.keepcooking.app.shop.ExpiryStatus
import com.keepcooking.app.shop.aisleGroupedNames
import com.keepcooking.app.shop.expiryStatus
import com.keepcooking.app.shop.isLowStock
import com.keepcooking.app.shop.normalizedAisleKey
import com.keepcooking.app.widgets.SnapshotWriter
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private data class ShopItem(val id: String, val name: String, val quantity: String = "", val aisle: String = "", val checked: Boolean = false, val recipeId: String? = null)
private data class ShopList(val id: String, val name: String, val items: List<ShopItem>)
private data class PantryItem(
    val id: String,
    val name: String,
    val quantity: String = "",
    val location: String = "",
    val expiresAtMillis: Long? = null,
    val lowThreshold: String = "",
    val barcode: String = "",
)

private enum class ShopTab { LISTS, PANTRY }

/**
 * Shop tab — parity with iOS Features/Shop/ShopViews.swift.
 * Multi-list aisle-sorted views with check-off + pantry (expiry, low-stock,
 * barcode stub with manual-entry fallback).
 *
 * Lists/items/pantry persist through Room (ShoppingListDao / ListItemDao /
 * PantryDao); every mutation enqueues a sync envelope and refreshes the
 * widget snapshot. Without a container the tab renders the in-memory demo.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShopScreen(container: AppContainer? = null) {
    var tab by remember { mutableStateOf(ShopTab.LISTS) }
    Scaffold(topBar = { TopAppBar(title = { Text("Lists") }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                ShopTab.entries.forEachIndexed { idx, t ->
                    SegmentedButton(
                        selected = tab == t,
                        onClick = { tab = t },
                        shape = androidx.compose.material3.SegmentedButtonDefaults.itemShape(idx, ShopTab.entries.size),
                        label = { Text(if (t == ShopTab.LISTS) "Lists" else "Pantry") },
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            when (tab) {
                ShopTab.LISTS -> if (container == null) ListsContent() else ListsContentRoom(container)
                ShopTab.PANTRY -> if (container == null) PantryContent() else PantryContentRoom(container)
            }
        }
    }
}

@Composable
private fun ListsContent() {
    var lists by remember {
        mutableStateOf(
            listOf(
                ShopList(
                    "l1", "Weekly shop", listOf(
                        ShopItem("a", "Apples", "4", "produce"),
                        ShopItem("b", "Milk", "1 gal", "dairy", checked = true),
                        ShopItem("c", "Chicken", "2 lb", "meat"),
                        ShopItem("d", "Salt", "", ""),
                    ),
                ),
                ShopList("l2", "Costco", emptyList()),
            ),
        )
    }
    val drafts = remember { mutableStateMapOf<String, String>() }
    var collapsedChecked by remember { mutableStateOf(setOf<String>()) }

    fun toggle(listId: String, itemId: String) {
        lists = lists.map { list ->
            if (list.id != listId) list
            else list.copy(items = list.items.map { if (it.id == itemId) it.copy(checked = !it.checked) else it })
        }
    }

    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (lists.isEmpty()) Text("No lists yet. Add a week to a list from the Plan tab.")
        lists.forEach { list ->
            val total = list.items.size
            val left = list.items.count { !it.checked }
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(list.name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        Text("$left of $total left", style = MaterialTheme.typography.labelMedium)
                    }
                    if (total > 0) {
                        Spacer(Modifier.height(4.dp))
                        LinearProgressIndicator(
                            progress = { (total - left).toFloat() / total },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
            val unchecked = list.items.filter { !it.checked }
            val aisles = aisleGroupedNames(unchecked, aisleOf = { it.aisle }, nameOf = { it.name })
            aisles.forEach { aisle ->
                val key = normalizedAisleKey(aisle)
                val header = if (aisle.trim().isEmpty()) "Other" else aisle.trim().replaceFirstChar { it.uppercase() }
                Text(header, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.secondary)
                unchecked.filter { normalizedAisleKey(it.aisle) == key }
                    .sortedBy { it.name.lowercase() }
                    .forEach { item -> ItemRow(item, onToggle = { toggle(list.id, item.id) }) }
            }
            val checked = list.items.filter { it.checked }.sortedBy { it.name.lowercase() }
            if (checked.isNotEmpty()) {
                val collapsed = collapsedChecked.contains(list.id)
                TextButton(onClick = {
                    collapsedChecked = if (collapsed) collapsedChecked - list.id else collapsedChecked + list.id
                }) { Text(if (collapsed) "Show checked (${checked.size})" else "Hide checked (${checked.size})") }
                if (!collapsed) checked.forEach { item -> ItemRow(item, onToggle = { toggle(list.id, item.id) }) }
            } else if (list.items.isEmpty()) {
                Text("Nothing here yet — add the first item below.", color = MaterialTheme.colorScheme.secondary)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = drafts[list.id].orEmpty(),
                    onValueChange = { drafts[list.id] = it },
                    label = { Text("Add item") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                Button(
                    onClick = {
                        val text = drafts[list.id].orEmpty().trim()
                        if (text.isNotEmpty()) {
                            lists = lists.map {
                                if (it.id == list.id) it.copy(items = it.items + ShopItem("n${System.currentTimeMillis()}", text)) else it
                            }
                            drafts[list.id] = ""
                        }
                    },
                    enabled = drafts[list.id].orEmpty().isNotBlank(),
                ) { Text("Add") }
            }
        }
        Spacer(Modifier.height(56.dp))
    }
}

@Composable
private fun ListsContentRoom(container: AppContainer) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val db = remember(container) { container.db }
    var lists by remember { mutableStateOf(listOf<ShoppingListEntity>()) }
    var itemsByList by remember { mutableStateOf(mapOf<String, List<ListItemEntity>>()) }
    var deviceId by remember { mutableStateOf("") }
    val drafts = remember { mutableStateMapOf<String, String>() }
    var collapsedChecked by remember { mutableStateOf(setOf<String>()) }
    var newListName by remember { mutableStateOf("") }
    val snackbarHostState = remember { SnackbarHostState() }

    fun reportError(message: String) {
        Log.e("ShopScreen", message)
        scope.launch { snackbarHostState.showSnackbar(message) }
    }

    suspend fun reload() {
        lists = db.shoppingLists().liveLists()
        itemsByList = lists.associate { it.id to db.listItems().forList(it.id) }
    }

    suspend fun refreshSnapshot() {
        runCatching { SnapshotWriter.refresh(context, db) }
    }

    suspend fun enqueueList(listId: String) {
        val list = db.shoppingLists().liveLists().firstOrNull { it.id == listId } ?: return
        val items = db.listItems().forList(listId).filterNot { it.deleted }
        val now = System.currentTimeMillis()
        val did = deviceId.ifEmpty { container.syncEngine.deviceId() }
        container.syncEngine.enqueue(
            SyncEnvelopeDto(
                id = list.id,
                updatedAt = Instant.ofEpochMilli(now).toString(),
                deviceId = did,
                entity = "list",
                payload = buildJsonObject {
                    put("id", list.id)
                    put("householdId", list.householdId)
                    put("name", list.name)
                    put(
                        "items",
                        JsonArray(
                            items.map { item ->
                                buildJsonObject {
                                    put("id", item.id)
                                    put("name", item.name)
                                    put("quantity", item.quantity)
                                    put("aisle", item.aisle)
                                    put("checked", item.checked)
                                    item.recipeId?.let { put("recipeId", it) }
                                }
                            },
                        ),
                    )
                },
            ),
        )
    }

    LaunchedEffect(db) {
        deviceId = runCatching { container.syncEngine.deviceId() }.getOrDefault("")
        reload()
    }

    fun toggle(listId: String, item: ListItemEntity) {
        scope.launch {
            runCatching {
                val now = System.currentTimeMillis()
                val did = deviceId.ifEmpty { container.syncEngine.deviceId() }
                db.listItems().upsertAll(listOf(item.copy(checked = !item.checked, updatedAt = now, deviceId = did)))
                // Bump the parent list so its envelope wins last-write-wins
                // against older remote envelopes (same as addItem/createList).
                db.shoppingLists().liveLists().firstOrNull { it.id == listId }?.let { parent ->
                    db.shoppingLists().upsertAll(listOf(parent.copy(updatedAt = now, deviceId = did)))
                }
                reload()
                enqueueList(listId)
                refreshSnapshot()
            }.onFailure { reportError("Couldn't update \"${item.name}\" (${it.message}).") }
        }
    }

    fun addItem(list: ShoppingListEntity) {
        val text = drafts[list.id].orEmpty().trim()
        if (text.isEmpty()) return
        scope.launch {
            runCatching {
                val now = System.currentTimeMillis()
                val did = deviceId.ifEmpty { container.syncEngine.deviceId() }
                db.listItems().upsertAll(
                    listOf(
                        ListItemEntity(
                            id = UUID.randomUUID().toString(), listId = list.id, name = text,
                            updatedAt = now, deviceId = did,
                        ),
                    ),
                )
                db.shoppingLists().upsertAll(listOf(list.copy(updatedAt = now)))
                drafts[list.id] = ""
                reload()
                enqueueList(list.id)
                refreshSnapshot()
            }.onFailure { reportError("Couldn't add item (${it.message}).") }
        }
    }

    fun createList() {
        val name = newListName.trim().ifEmpty { "Shopping" }
        scope.launch {
            runCatching {
                val now = System.currentTimeMillis()
                val did = deviceId.ifEmpty { container.syncEngine.deviceId() }
                val list = ShoppingListEntity(
                    id = UUID.randomUUID().toString(), householdId = "hh-demo",
                    name = name, updatedAt = now, deviceId = did,
                )
                db.shoppingLists().upsertAll(listOf(list))
                newListName = ""
                reload()
                enqueueList(list.id)
                refreshSnapshot()
            }.onFailure { reportError("Couldn't create list (${it.message}).") }
        }
    }

    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (lists.isEmpty()) {
            Text("No lists yet. Add a week to a list from the Plan tab.")
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = newListName,
                onValueChange = { newListName = it },
                label = { Text("New list name") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            Button(onClick = { createList() }) { Text("Create") }
        }
        lists.forEach { list ->
            val items = itemsByList[list.id].orEmpty().filterNot { it.deleted }
            val total = items.size
            val left = items.count { !it.checked }
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(list.name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        Text("$left of $total left", style = MaterialTheme.typography.labelMedium)
                    }
                    if (total > 0) {
                        Spacer(Modifier.height(4.dp))
                        LinearProgressIndicator(
                            progress = { (total - left).toFloat() / total },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
            val unchecked = items.filter { !it.checked }
            val aisles = aisleGroupedNames(unchecked, aisleOf = { it.aisle }, nameOf = { it.name })
            aisles.forEach { aisle ->
                val key = normalizedAisleKey(aisle)
                val header = if (aisle.trim().isEmpty()) "Other" else aisle.trim().replaceFirstChar { it.uppercase() }
                Text(header, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.secondary)
                unchecked.filter { normalizedAisleKey(it.aisle) == key }
                    .sortedBy { it.name.lowercase() }
                    .forEach { item ->
                        ItemRow(
                            ShopItem(item.id, item.name, item.quantity, item.aisle, item.checked, item.recipeId),
                            onToggle = { toggle(list.id, item) },
                        )
                    }
            }
            val checked = items.filter { it.checked }.sortedBy { it.name.lowercase() }
            if (checked.isNotEmpty()) {
                val collapsed = collapsedChecked.contains(list.id)
                TextButton(onClick = {
                    collapsedChecked = if (collapsed) collapsedChecked - list.id else collapsedChecked + list.id
                }) { Text(if (collapsed) "Show checked (${checked.size})" else "Hide checked (${checked.size})") }
                if (!collapsed) checked.forEach { item ->
                    ItemRow(
                        ShopItem(item.id, item.name, item.quantity, item.aisle, item.checked, item.recipeId),
                        onToggle = { toggle(list.id, item) },
                    )
                }
            } else if (items.isEmpty()) {
                Text("Nothing here yet — add the first item below.", color = MaterialTheme.colorScheme.secondary)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = drafts[list.id].orEmpty(),
                    onValueChange = { drafts[list.id] = it },
                    label = { Text("Add item") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                Button(
                    onClick = { addItem(list) },
                    enabled = drafts[list.id].orEmpty().isNotBlank(),
                ) { Text("Add") }
            }
        }
        SnackbarHost(hostState = snackbarHostState)
        Spacer(Modifier.height(56.dp))
    }
}

@Composable
private fun ItemRow(item: ShopItem, onToggle: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        IconButton(onClick = onToggle) {
            Icon(
                if (item.checked) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                contentDescription = if (item.checked) "checked" else "unchecked",
            )
        }
        Column(Modifier.weight(1f)) {
            Text(item.name, style = MaterialTheme.typography.bodyLarge)
            if (item.quantity.isNotEmpty()) Text(item.quantity, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun PantryContent() {
    var items by remember {
        mutableStateOf(
            listOf(
                PantryItem("p1", "Flour", "2 lb", "Pantry", expiresAtMillis = System.currentTimeMillis() + 60L * 86400000, lowThreshold = "1"),
                PantryItem("p2", "Milk", "1", "Fridge", expiresAtMillis = System.currentTimeMillis() + 2L * 86400000, lowThreshold = "2"),
                PantryItem("p3", "Canned beans", "", "Pantry", expiresAtMillis = System.currentTimeMillis() - 86400000),
                PantryItem("p4", "Rice", "5 lb", "Pantry"),
            ),
        )
    }
    var showScanner by remember { mutableStateOf(false) }
    var manualCode by remember { mutableStateOf("") }
    var lastScan by remember { mutableStateOf<String?>(null) }

    val flagged = items.filter {
        val s = expiryStatus(it.expiresAtMillis)
        (s != ExpiryStatus.FRESH && s != ExpiryStatus.NO_DATE) || isLowStock(it.quantity, it.lowThreshold)
    }
    val rest = items.sortedWith(compareBy({ it.location.lowercase() }, { it.name.lowercase() }))

    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Pantry", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            OutlinedButton(onClick = { showScanner = true }) { Text("Scan") }
        }
        lastScan?.let { Text("Scanned: $it", style = MaterialTheme.typography.labelMedium) }
        Text("Needs attention", style = MaterialTheme.typography.titleSmall)
        if (flagged.isEmpty()) Text("Nothing expiring or low.", color = MaterialTheme.colorScheme.secondary)
        flagged.forEach { PantryRow(it) }
        Text("All", style = MaterialTheme.typography.titleSmall)
        rest.forEach { PantryRow(it) }
        Spacer(Modifier.height(56.dp))
    }

    if (showScanner) {
        AlertDialog(
            onDismissRequest = { showScanner = false; manualCode = "" },
            title = { Text("Scan barcode") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Scanner preview (stub). Enter a code manually.", style = MaterialTheme.typography.bodySmall)
                    OutlinedTextField(
                        value = manualCode,
                        onValueChange = { manualCode = it },
                        label = { Text("Enter barcode manually") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val code = manualCode.trim()
                        if (code.isNotEmpty()) {
                            lastScan = code
                            items = items + PantryItem("b$code", "Scanned item $code", barcode = code)
                            showScanner = false
                            manualCode = ""
                        }
                    },
                    enabled = manualCode.trim().isNotEmpty(),
                ) { Text("Use this code") }
            },
            dismissButton = { TextButton(onClick = { showScanner = false; manualCode = "" }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun PantryContentRoom(container: AppContainer) {
    val scope = rememberCoroutineScope()
    val db = remember(container) { container.db }
    var items by remember { mutableStateOf(listOf<PantryItemEntity>()) }
    var deviceId by remember { mutableStateOf("") }
    var showScanner by remember { mutableStateOf(false) }
    var manualCode by remember { mutableStateOf("") }
    var lastScan by remember { mutableStateOf<String?>(null) }
    var pantryError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(db) {
        deviceId = runCatching { container.syncEngine.deviceId() }.getOrDefault("")
        items = db.pantry().liveItems()
    }

    fun addScanned(code: String) {
        scope.launch {
            runCatching {
                val now = System.currentTimeMillis()
                val did = deviceId.ifEmpty { container.syncEngine.deviceId() }
                val row = PantryItemEntity(
                    id = UUID.randomUUID().toString(), householdId = "hh-demo",
                    name = "Scanned item $code", barcode = code,
                    updatedAt = now, deviceId = did,
                )
                db.pantry().upsertAll(listOf(row))
                lastScan = code
                pantryError = null
                items = db.pantry().liveItems()
                container.syncEngine.enqueue(
                    SyncEnvelopeDto(
                        id = row.id,
                        updatedAt = Instant.ofEpochMilli(now).toString(),
                        deviceId = did,
                        entity = "pantryItem",
                        payload = buildJsonObject {
                            put("id", row.id)
                            put("householdId", row.householdId)
                            put("name", row.name)
                            put("quantity", row.quantity)
                            put("location", row.location)
                            put("barcode", row.barcode)
                        },
                    ),
                )
            }.onFailure {
                val message = "Couldn't save scanned item ($it)."
                Log.e("ShopScreen", message)
                pantryError = message
            }
        }
    }

    val rows = items.map {
        PantryItem(it.id, it.name, it.quantity, it.location, it.expiresAt, it.lowThreshold, it.barcode)
    }
    val flagged = rows.filter {
        val s = expiryStatus(it.expiresAtMillis)
        (s != ExpiryStatus.FRESH && s != ExpiryStatus.NO_DATE) || isLowStock(it.quantity, it.lowThreshold)
    }
    val rest = rows.sortedWith(compareBy({ it.location.lowercase() }, { it.name.lowercase() }))

    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Pantry", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            OutlinedButton(onClick = { showScanner = true }) { Text("Scan") }
        }
        lastScan?.let { Text("Scanned: $it", style = MaterialTheme.typography.labelMedium) }
        pantryError?.let { Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.error) }
        Text("Needs attention", style = MaterialTheme.typography.titleSmall)
        if (flagged.isEmpty()) Text("Nothing expiring or low.", color = MaterialTheme.colorScheme.secondary)
        flagged.forEach { PantryRow(it) }
        Text("All", style = MaterialTheme.typography.titleSmall)
        if (rest.isEmpty()) Text("Pantry is empty — scan an item to start.", color = MaterialTheme.colorScheme.secondary)
        rest.forEach { PantryRow(it) }
        Spacer(Modifier.height(56.dp))
    }

    if (showScanner) {
        AlertDialog(
            onDismissRequest = { showScanner = false; manualCode = "" },
            title = { Text("Scan barcode") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Scanner preview (stub). Enter a code manually.", style = MaterialTheme.typography.bodySmall)
                    OutlinedTextField(
                        value = manualCode,
                        onValueChange = { manualCode = it },
                        label = { Text("Enter barcode manually") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val code = manualCode.trim()
                        if (code.isNotEmpty()) {
                            addScanned(code)
                            showScanner = false
                            manualCode = ""
                        }
                    },
                    enabled = manualCode.trim().isNotEmpty(),
                ) { Text("Use this code") }
            },
            dismissButton = { TextButton(onClick = { showScanner = false; manualCode = "" }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun PantryRow(item: PantryItem) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp)) {
            Text(item.name, style = MaterialTheme.typography.bodyLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (item.location.isNotEmpty()) Text(item.location, style = MaterialTheme.typography.labelSmall)
                if (item.quantity.isNotEmpty()) Text(item.quantity, style = MaterialTheme.typography.labelSmall)
                if (isLowStock(item.quantity, item.lowThreshold)) {
                    Text("Low", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.tertiary)
                }
                when (expiryStatus(item.expiresAtMillis)) {
                    ExpiryStatus.EXPIRED -> Text("Expired", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
                    ExpiryStatus.EXPIRING_SOON -> Text("Expiring soon", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.tertiary)
                    ExpiryStatus.FRESH, ExpiryStatus.NO_DATE -> Unit
                }
            }
        }
    }
}
