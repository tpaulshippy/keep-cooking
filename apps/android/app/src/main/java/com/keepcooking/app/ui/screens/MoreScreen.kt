package com.keepcooking.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * More tab — parity with iOS PhoneTabView More tab.
 * Overflow destinations: clip, export, sharing, Settings, and the
 * watch companion.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MoreScreen(
    onClip: () -> Unit = {},
    onExport: () -> Unit = {},
    onShare: () -> Unit = {},
    onNowCooking: () -> Unit = {},
    onSettings: () -> Unit = {},
) {
    val rows = listOf(
        "Clip a recipe" to onClip,
        "Export a recipe" to onExport,
        "Share a cookbook" to onShare,
        "Now Cooking (watch)" to onNowCooking,
        "Settings" to onSettings,
    )
    Scaffold(topBar = { TopAppBar(title = { Text("More") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
            items(rows) { (label, go) ->
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp)
                        .clickable(onClick = go),
                ) {
                    Column(Modifier.padding(16.dp)) {
                        Text(label, style = MaterialTheme.typography.titleMedium)
                    }
                }
            }
        }
    }
}
