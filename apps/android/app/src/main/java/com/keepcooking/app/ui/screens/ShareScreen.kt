package com.keepcooking.app.ui.screens

import android.content.Intent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
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
import com.keepcooking.app.AppContainer
import com.keepcooking.app.network.ShareCookbookRequest
import com.keepcooking.app.network.ShareLinkDto
import com.keepcooking.app.share.HouseholdInvite
import com.keepcooking.app.sync.SyncEngine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/**
 * Share UI — parity with iOS Features/Library/ShareViews.swift.
 * Household invites (out-of-band links) + cookbook share links
 * (Lane 1 POST /share/cookbook). Every button performs a real action.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareScreen(container: AppContainer) {
    Scaffold(topBar = { TopAppBar(title = { Text("Share") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
            item { HouseholdInvitesCard() }
            item { CookbookShareCard(container) }
        }
    }
}

@Composable
private fun HouseholdInvitesCard() {
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    var householdId by remember { mutableStateOf("hh-demo") }
    var invites by remember { mutableStateOf(emptyList<HouseholdInvite>()) }

    Card(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text("Household invites", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(
                value = householdId,
                onValueChange = { householdId = it },
                label = { Text("Household id") },
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            )
            Button(
                onClick = { invites = invites + HouseholdInvite.make(householdId.trim()) },
                enabled = householdId.trim().isNotEmpty(),
            ) { Text("Create invite link") }
            Text(
                "Pending invites (${invites.size})",
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
            )
            if (invites.isEmpty()) {
                Text("No invites yet — create one above.", style = MaterialTheme.typography.bodyMedium)
            }
            invites.forEach { invite ->
                Card(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Column(Modifier.padding(12.dp)) {
                        Text(invite.code, style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Expires ${DateFormat.getDateInstance().format(Date(invite.expiresAtMillis))} · " +
                                "${invite.useCount}/${invite.maxUses} uses",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Row {
                            Button(onClick = {
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_TEXT, invite.inviteUrl)
                                }
                                context.startActivity(Intent.createChooser(send, "Share invite"))
                            }) { Text("Share") }
                            TextButton(onClick = { clipboard.setText(AnnotatedString(invite.inviteUrl)) }) {
                                Text("Copy")
                            }
                            TextButton(
                                onClick = { invites = invites.filterNot { it.id == invite.id } },
                            ) { Text("Revoke") }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CookbookShareCard(container: AppContainer) {
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var householdId by remember { mutableStateOf("hh-demo") }
    var recipeIdsText by remember { mutableStateOf("") }
    var link by remember { mutableStateOf<ShareLinkDto?>(null) }
    var sharing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var betaToken by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(container) {
        // Reuse the container's DataStore — no second delegate on this file.
        betaToken = runCatching {
            container.appDataStore.data.map { it[SyncEngine.KEY_BETA_TOKEN] }.first()
        }.getOrNull()
    }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Cookbook share", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(
                value = householdId,
                onValueChange = { householdId = it },
                label = { Text("Household id") },
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            )
            OutlinedTextField(
                value = recipeIdsText,
                onValueChange = { recipeIdsText = it },
                label = { Text("Recipe ids (comma separated)") },
                modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
            )
            Button(
                onClick = {
                    val ids = recipeIdsText.split(",").map { it.trim() }.filter { it.isNotEmpty() }
                    if (ids.isEmpty()) {
                        error = "Add at least one recipe id."
                        return@Button
                    }
                    sharing = true
                    scope.launch {
                        try {
                            val auth = betaToken?.takeIf { it.isNotBlank() }?.let { "Bearer $it" }
                            link = container.api.createCookbookShare(
                                auth,
                                ShareCookbookRequest(householdId.trim(), ids),
                            )
                            error = null
                        } catch (t: Throwable) {
                            error = "Share failed (${t.message}). Check connection and retry."
                        } finally {
                            sharing = false
                        }
                    }
                },
                enabled = !sharing,
            ) { Text(if (sharing) "Creating…" else "Create share link") }
            link?.let {
                Text(it.url, modifier = Modifier.padding(top = 12.dp))
                Text("Expires ${it.expiresAt}", style = MaterialTheme.typography.bodySmall)
                Row {
                    TextButton(onClick = {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, it.url)
                        }
                        context.startActivity(Intent.createChooser(send, "Share cookbook"))
                    }) { Text("Share") }
                    TextButton(onClick = { clipboard.setText(AnnotatedString(it.url)) }) { Text("Copy") }
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
        }
    }
}
