package com.keepcooking.app.ui.screens

import android.content.Intent
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
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.datastore.preferences.core.edit
import com.keepcooking.app.AppContainer
import com.keepcooking.app.network.createApiService
import com.keepcooking.app.sync.E2EJoinException
import com.keepcooking.app.sync.E2EKeyStore
import com.keepcooking.app.sync.SyncEngine
import com.keepcooking.app.sync.SyncRoute
import com.keepcooking.app.sync.ensureE2EIdentity
import com.keepcooking.app.sync.inviteBundleJson
import com.keepcooking.app.sync.parseInviteBundle
import com.keepcooking.app.sync.resolveSyncRoute
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Settings — parity with iOS SettingsView.
 * Sync status + Sync now, Devices sharing (connect / join via the
 * auto-generated E2E identity), and an Advanced custom-server disclosure.
 * No URL, token, Test/Reset, or identifier rows anywhere else.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(container: AppContainer, onBack: () -> Unit = {}) {
    val scope = rememberCoroutineScope()
    var syncing by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf("") }
    var household by remember { mutableStateOf("hh-demo") }
    var hasCustomServer by remember { mutableStateOf(false) }

    LaunchedEffect(container) {
        household = E2EKeyStore.loadMetadata(container.e2eMetaStore)?.householdId ?: "hh-demo"
        hasCustomServer = container.appDataStore.data
            .map { it[SyncEngine.KEY_BASE_URL]?.trim().orEmpty() }.first().isNotEmpty()
        // Auto-generate the E2E identity on first launch so there is always a
        // key to share — the user never sees key setup, only Devices sharing.
        runCatching { ensureE2EIdentity(container.e2eMetaStore, container.e2eSecretStore, household) }
    }

    fun doSync() {
        scope.launch {
            syncing = true
            try {
                runCatching {
                    ensureE2EIdentity(container.e2eMetaStore, container.e2eSecretStore, household)
                }
                val route: SyncRoute =
                    resolveSyncRoute(container.e2eMetaStore, container.e2eSecretStore)
                val res = container.syncEngine.syncRouted(route)
                status = if (res.conflicts > 0) {
                    "Synced ${res.pulled} down · ${res.pushed} up · ${res.conflicts} server-won"
                } else {
                    "Synced ${res.pulled} down · ${res.pushed} up"
                }
            } catch (t: Throwable) {
                status = "Sync failed (${t.message ?: "unknown error"})"
            } finally {
                syncing = false
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp).verticalScroll(rememberScrollState()),
        ) {
            SyncCard(status = status, syncing = syncing, hasCustomServer = hasCustomServer, onSync = ::doSync)
            Spacer(Modifier.height(12.dp))
            DevicesCard(container)
            Spacer(Modifier.height(12.dp))
            AdvancedCard(container, onServerChanged = { custom ->
                hasCustomServer = custom
                if (!custom) doSync()
            })
            Spacer(Modifier.height(12.dp))
            Card(Modifier.fillMaxWidth()) {
                Text(
                    "Keep Cooking 0.1.0 — offline-first, MIT.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
    }
}

@Composable
private fun SyncCard(status: String, syncing: Boolean, hasCustomServer: Boolean, onSync: () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Sync", style = MaterialTheme.typography.titleMedium)
            Text(
                if (status.isEmpty()) "Offline-ready" else status,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 8.dp),
            )
            Button(onClick = onSync, enabled = !syncing) {
                Text(if (syncing) "Syncing…" else "Sync now")
            }
            Text(
                if (hasCustomServer) "Using a custom server (see Advanced)." else "Using the built-in server.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

@Composable
private fun DevicesCard(container: AppContainer) {
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    var household by remember { mutableStateOf("hh-demo") }
    var inviteCode by remember { mutableStateOf<String?>(null) }
    var pasteInput by remember { mutableStateOf("") }
    var joinResult by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }

    LaunchedEffect(container) {
        household = E2EKeyStore.loadMetadata(container.e2eMetaStore)?.householdId ?: "hh-demo"
    }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Devices", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            Button(onClick = {
                scope.launch {
                    working = true
                    try {
                        val cred = ensureE2EIdentity(
                            container.e2eMetaStore, container.e2eSecretStore, household,
                        )
                        // Custom-server invites carry the server URL so the
                        // joining device lands on the same backend; built-in
                        // installs omit it (nothing to review).
                        val hint = container.appDataStore.data
                            .map { it[SyncEngine.KEY_BASE_URL]?.trim().orEmpty() }
                            .first().ifEmpty { null }
                        inviteCode = cred?.let {
                            inviteBundleJson(
                                com.keepcooking.app.sync.SyncInviteBundle(
                                    householdId = it.metadata.householdId,
                                    syncCode = it.syncCode,
                                    kid = it.metadata.kid,
                                    hash = it.metadata.hash,
                                    endpointHint = hint,
                                ),
                            )
                        }
                        if (inviteCode == null) joinResult = "Could not access secure storage — code unavailable."
                    } finally {
                        working = false
                    }
                }
            }, enabled = !working) { Text("Connect a new device") }
            inviteCode?.let { code ->
                Text(
                    code,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
                Row {
                    Button(onClick = { clipboard.setText(AnnotatedString(code)) }) { Text("Copy code") }
                    TextButton(onClick = {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, code)
                        }
                        context.startActivity(Intent.createChooser(send, "Share code"))
                    }) { Text("Share") }
                }
                Text(
                    "Enter it on your second device under Devices → Join with code.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = pasteInput,
                onValueChange = { pasteInput = it },
                label = { Text("Paste code to join") },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = {
                    scope.launch {
                        working = true
                        try {
                            val bundle = parseInviteBundle(pasteInput)
                            val ok = E2EKeyStore.acceptInvite(
                                container.e2eMetaStore, container.e2eSecretStore, bundle,
                            )
                            if (!ok) {
                                joinResult = "Code does not match — it was mistyped or tampered with."
                            } else {
                                household = bundle.householdId
                                pasteInput = ""
                                joinResult = if (!bundle.endpointHint.isNullOrEmpty()) {
                                    "Joined household ${bundle.householdId}. The code suggests a custom server — review it under Advanced before switching."
                                } else {
                                    "Joined household ${bundle.householdId}."
                                }
                            }
                        } catch (e: E2EJoinException) {
                            joinResult = e.message ?: "That text is not a Keep Cooking invite code."
                        } finally {
                            working = false
                        }
                    }
                },
                enabled = !working && pasteInput.trim().isNotEmpty(),
            ) { Text("Join with code") }
            if (joinResult.isNotEmpty()) {
                Text(
                    joinResult,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
            Text(
                "Keep Cooking can't see or recover your data. Lose all devices = permanent loss. Add a new phone while you still have this one — open Settings here on both devices.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}

@Composable
private fun AdvancedCard(container: AppContainer, onServerChanged: (Boolean) -> Unit) {
    val scope = rememberCoroutineScope()
    var expanded by remember { mutableStateOf(false) }
    var customUrl by remember { mutableStateOf("") }
    var healthResult by remember { mutableStateOf("") }
    var testing by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    LaunchedEffect(container) {
        customUrl = container.appDataStore.data
            .map { it[SyncEngine.KEY_BASE_URL].orEmpty() }.first()
    }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            TextButton(onClick = { expanded = !expanded }, modifier = Modifier.fillMaxWidth()) {
                Text(if (expanded) "Advanced ▾" else "Advanced ▸")
            }
            if (!expanded) return@Column
            Text(
                "Only set this if you run your own backend. Most users should leave it blank.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = customUrl,
                onValueChange = { customUrl = it },
                label = { Text("Server URL (blank = built-in)") },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            Row {
                Button(
                    onClick = {
                        scope.launch {
                            testing = true
                            try {
                                val base = customUrl.trim()
                                    .ifEmpty { SyncEngine.PROD_BASE_URL }
                                createApiService(base).health()
                                healthResult = "Healthy — $base"
                            } catch (t: Throwable) {
                                healthResult = "Unreachable: ${t.message ?: "unknown error"}"
                            } finally {
                                testing = false
                            }
                        }
                    },
                    enabled = !testing && !saving,
                ) { Text(if (testing) "Testing…" else "Test") }
                TextButton(
                    onClick = {
                        scope.launch {
                            saving = true
                            try {
                                container.appDataStore.edit {
                                    it[SyncEngine.KEY_BASE_URL] = customUrl.trim()
                                }
                                healthResult = ""
                                onServerChanged(customUrl.trim().isNotEmpty())
                            } finally {
                                saving = false
                            }
                        }
                    },
                    enabled = !testing && !saving,
                ) { Text("Save") }
                TextButton(
                    onClick = {
                        scope.launch {
                            container.appDataStore.edit { it.remove(SyncEngine.KEY_BASE_URL) }
                            customUrl = ""
                            healthResult = "Using the built-in server."
                            onServerChanged(false)
                        }
                    },
                    enabled = !testing && !saving,
                ) { Text("Use built-in") }
            }
            if (healthResult.isNotEmpty()) {
                Text(
                    healthResult,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        }
    }
}
