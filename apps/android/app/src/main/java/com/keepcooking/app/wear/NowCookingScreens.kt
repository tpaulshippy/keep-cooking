package com.keepcooking.app.wear

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.keepcooking.app.widgets.TodaySnapshot
import com.keepcooking.app.widgets.WidgetSnapshotStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
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
 *
 * Timer countdown state + ticker jobs live on [NowCookingScreen] and are
 * passed down, so tab switches never orphan a ticker and Stop/restart always
 * cancels the previous job before starting a new one.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NowCookingScreen() {
    var tab by remember { mutableStateOf(0) }
    // Hoisted timer state: seconds left per unique timer key + running set.
    val remaining = remember { mutableStateMapOf<String, Int>() }
    val runningState = remember { mutableStateOf(setOf<String>()) }
    val tickers = remember { mutableMapOf<String, Job>() }
    val scope = rememberCoroutineScope()
    DisposableEffect(Unit) {
        onDispose { tickers.values.forEach { it.cancel() } }
    }
    Scaffold(topBar = { TopAppBar(title = { Text("Now Cooking") }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            TabRow(selectedTabIndex = tab) {
                listOf("Steps", "Timers", "Lists").forEachIndexed { i, label ->
                    Tab(selected = tab == i, onClick = { tab = i }, text = { Text(label) })
                }
            }
            when (tab) {
                0 -> WatchStepsPane()
                1 -> WatchTimersPane(
                    remaining = remaining,
                    runningState = runningState,
                    tickers = tickers,
                    scope = scope,
                )
                2 -> WatchListPane()
            }
        }
    }
}

@Composable
private fun WatchStepsPane() {
    val context = LocalContext.current
    var payload by remember { mutableStateOf<NowCookingPayload?>(null) }
    // Local done-override: explicit user taps win over the stored step.done flag.
    var doneOverride by remember { mutableStateOf(mapOf<Int, Boolean>()) }
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
        itemsIndexed(steps, key = { _, step -> "step-${step.position}" }) { _, step ->
            val isDone = doneOverride[step.position] ?: step.done
            Row(
                Modifier.fillMaxWidth().padding(vertical = 8.dp)
                    .clickable {
                        doneOverride = doneOverride + (step.position to !isDone)
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
private fun WatchTimersPane(
    remaining: SnapshotStateMap<String, Int>,
    runningState: MutableState<Set<String>>,
    tickers: MutableMap<String, Job>,
    scope: CoroutineScope,
) {
    val context = LocalContext.current
    var payload by remember { mutableStateOf<NowCookingPayload?>(null) }
    LaunchedEffect(Unit) { payload = WatchStore.readNowCooking(context) }
    DisposableEffect(Unit) {
        onDispose { tickers.values.forEach { it.cancel() } }
    }
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
        itemsIndexed(timers, key = { index, timer -> "timer-$index-${timer.label}-${timer.seconds}" }) { index, timer ->
            val key = "timer-$index-${timer.label}-${timer.seconds}"
            val left = remaining[key] ?: timer.seconds
            val running = runningState.value
            Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Text(timer.label, style = MaterialTheme.typography.titleSmall)
                Text(
                    "%d:%02d".format(left / 60, left % 60),
                    style = MaterialTheme.typography.headlineMedium,
                )
                Button(onClick = {
                    if (key in runningState.value) {
                        tickers.remove(key)?.cancel()
                        runningState.value = runningState.value - key
                    } else {
                        tickers.remove(key)?.cancel()
                        remaining[key] = remaining[key] ?: timer.seconds
                        runningState.value = runningState.value + key
                        tickers[key] = scope.launch {
                            // Stop/restart cancels this job; the loop only counts down.
                            while ((remaining[key] ?: 0) > 0) {
                                delay(1000)
                                remaining[key] = maxOf(0, (remaining[key] ?: 0) - 1)
                            }
                            tickers.remove(key)
                            runningState.value = runningState.value - key
                        }
                    }
                }) { Text(if (key in running) "Stop" else "Start") }
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
        itemsIndexed(snapshot.lists, key = { _, list -> "list-${list.listId}" }) { _, list ->
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
