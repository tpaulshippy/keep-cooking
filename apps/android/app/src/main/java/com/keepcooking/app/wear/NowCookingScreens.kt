package com.keepcooking.app.wear

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.keepcooking.app.widgets.TodaySnapshot
import com.keepcooking.app.widgets.WidgetSnapshotStore
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Now-cooking companion screens — parity with iOS watch/WatchViews.swift
 * (WatchRootView: Steps / Timers / Lists tabs).
 *
 * Phone-side data layer + Wear OS Compose stubs: these are plain Material3
 * screens reading [WatchStore]/[WidgetSnapshotStore] so they run in the phone
 * app today; the Wear OS module reuses the same store + payload with
 * Wear Material (drop-in: swap imports, same state logic).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NowCookingScreen() {
    var tab by remember { mutableStateOf(0) }
    Scaffold(topBar = { TopAppBar(title = { Text("Now Cooking") }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            TabRow(selectedTabIndex = tab) {
                listOf("Steps", "Timers", "Lists").forEachIndexed { i, label ->
                    Tab(selected = tab == i, onClick = { tab = i }, text = { Text(label) })
                }
            }
            when (tab) {
                0 -> WatchStepsPane()
                1 -> WatchTimersPane()
                2 -> WatchListPane()
            }
        }
    }
}

@Composable
private fun WatchStepsPane() {
    val context = LocalContext.current
    var payload by remember { mutableStateOf<NowCookingPayload?>(null) }
    var done by remember { mutableStateOf(setOf<Int>()) }
    LaunchedEffect(Unit) { payload = WatchStore.readNowCooking(context) }
    val steps = payload?.steps?.sortedBy { it.position }.orEmpty()
    if (steps.isEmpty()) {
        Text(
            "No recipe — start cooking on the Cook tab to see steps here.",
            modifier = Modifier.padding(16.dp),
            style = MaterialTheme.typography.bodyMedium,
        )
        return
    }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item { Text(payload?.title.orEmpty(), style = MaterialTheme.typography.titleMedium) }
        items(steps, key = { it.position }) { step ->
            val isDone = step.position in done || step.done
            Row(
                Modifier.fillMaxWidth().padding(vertical = 8.dp)
                    .clickable {
                        done = if (isDone) done - step.position else done + step.position
                    },
            ) {
                Text(
                    "${step.position + 1}. ${step.text}",
                    style = MaterialTheme.typography.bodyLarge.copy(
                        textDecoration = if (isDone) TextDecoration.LineThrough else null,
                    ),
                )
            }
        }
    }
}

@Composable
private fun WatchTimersPane() {
    val context = LocalContext.current
    var payload by remember { mutableStateOf<NowCookingPayload?>(null) }
    val remaining = remember { mutableStateMapOf<String, Int>() }
    var running by remember { mutableStateOf(setOf<String>()) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { payload = WatchStore.readNowCooking(context) }
    val timers = payload?.timers.orEmpty()
    if (timers.isEmpty()) {
        Text(
            "No timers — timers from Cook mode appear here.",
            modifier = Modifier.padding(16.dp),
            style = MaterialTheme.typography.bodyMedium,
        )
        return
    }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        items(timers, key = { it.label }) { timer ->
            val left = remaining[timer.label] ?: timer.seconds
            Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Text(timer.label, style = MaterialTheme.typography.titleSmall)
                Text(
                    "%d:%02d".format(left / 60, left % 60),
                    style = MaterialTheme.typography.headlineMedium,
                )
                Button(onClick = {
                    if (timer.label in running) {
                        running = running - timer.label
                    } else {
                        remaining[timer.label] = remaining[timer.label] ?: timer.seconds
                        running = running + timer.label
                        scope.launch {
                            while ((remaining[timer.label] ?: 0) > 0 && timer.label in running) {
                                delay(1000)
                                remaining[timer.label] = maxOf(0, (remaining[timer.label] ?: 0) - 1)
                            }
                            running = running - timer.label
                        }
                    }
                }) { Text(if (timer.label in running) "Stop" else "Start") }
            }
        }
    }
}

@Composable
private fun WatchListPane() {
    val context = LocalContext.current
    var snapshot by remember { mutableStateOf(TodaySnapshot.EMPTY) }
    LaunchedEffect(Unit) { snapshot = WidgetSnapshotStore.read(context) }
    if (snapshot.lists.isEmpty()) {
        Text(
            "No lists — shopping lists sync here.",
            modifier = Modifier.padding(16.dp),
            style = MaterialTheme.typography.bodyMedium,
        )
        return
    }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        items(snapshot.lists, key = { it.listId }) { list ->
            Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Text(list.name, style = MaterialTheme.typography.titleSmall)
                LinearProgressIndicator(progress = list.fraction, modifier = Modifier.fillMaxWidth())
                Text(
                    "${list.checked} of ${list.total} done",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}
