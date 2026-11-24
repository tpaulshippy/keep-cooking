package com.keepcooking.app.ui.screens

import android.view.View
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.keepcooking.app.cook.CookActivityStub
import com.keepcooking.app.cook.CookSession
import com.keepcooking.app.cook.KeepAwake
import com.keepcooking.app.cook.ScaleVoiceCommand
import com.keepcooking.app.cook.VoiceCommand
import com.keepcooking.app.cook.VoiceIngredientRef
import com.keepcooking.app.cook.applyScaleCommand
import com.keepcooking.app.cook.fractionDisplayString
import com.keepcooking.app.cook.fuzzyVoiceMatch
import com.keepcooking.app.cook.ingredientId
import com.keepcooking.app.cook.parseVoiceCommand
import com.keepcooking.app.cook.scaleFactor
import com.keepcooking.app.cook.scaledDisplay
import com.keepcooking.app.cook.validatedStep

private data class DemoIngredient(val id: String, val name: String, val quantity: Double?, val unit: String)
private data class DemoStep(val id: String, val position: Int, val text: String)

/**
 * Cook tab — parity with iOS Features/Cook/CookModeView.swift.
 * Full-screen step pager + progress, servings scaler slider, large-type
 * steps, ingredient checklist, timers with Start, keep-screen-on, and a
 * voice-command bar (text entry driving the same parser as iOS voice).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CookScreen() {
    // Demo recipe (store-agnostic snapshots, like the iOS view's init args).
    val title = "Weeknight Pasta"
    val baseServings = 4.0
    val ingredients = remember {
        listOf(
            DemoIngredient("i1", "Spaghetti", 8.0, "oz"),
            DemoIngredient("i2", "Crushed tomatoes", 28.0, "oz"),
            DemoIngredient("i3", "Garlic", 3.0, "cloves"),
            DemoIngredient("i4", "Olive oil", 2.0, "tbsp"),
            DemoIngredient("i5", "Salt to taste", null, ""),
        )
    }
    val steps = remember {
        listOf(
            DemoStep("s1", 0, "Bring a large pot of salted water to a boil."),
            DemoStep("s2", 1, "Cook the spaghetti 8-10 min until al dente."),
            DemoStep("s3", 2, "Warm the sauce 5 min, then rest 1 min before serving."),
        )
    }

    val session = remember { CookSession(stepCount = steps.size).also { it.loadTimers(steps.map { s -> s.text }) } }
    var stepIndex by remember { mutableStateOf(0) }
    var targetServings by remember { mutableStateOf(baseServings) }
    var ingredientsExpanded by remember { mutableStateOf(true) }
    var crossedSteps by remember { mutableStateOf(setOf<String>()) }
    var crossedIngredients by remember { mutableStateOf(setOf<String>()) }
    var scheduledCount by remember { mutableStateOf(0) }
    var lastReply by remember { mutableStateOf("") }
    var readAloud by remember { mutableStateOf(true) }
    var listening by remember { mutableStateOf(false) }
    var voiceInput by remember { mutableStateOf("") }
    val scheduledIds = remember { mutableStateListOf<String>() }

    val factor = scaleFactor(baseServings, targetServings)
    val progress = (stepIndex + 1).toFloat() / steps.size.coerceAtLeast(1)

    // Keep screen on while cooking (parity with iOS KeepAwake).
    KeepScreenOnEffect()
    DisposableEffect(Unit) {
        KeepAwake.enable()
        onDispose { KeepAwake.disable() }
    }

    fun speak(text: String) {
        // Read-aloud seam: real TTS (TextToSpeech) lands here; the reply line
        // always updates so the UI mirrors the iOS pill reply.
        lastReply = text
    }

    fun handleVoice(cmd: VoiceCommand) {
        val voiceIngredients = ingredients.map { VoiceIngredientRef(it.id, it.name) }
        val stepTexts = steps.map { it.text }
        when (cmd) {
            VoiceCommand.Next -> {
                if (stepIndex < steps.size - 1) {
                    stepIndex++
                    session.go(stepIndex)
                    speak("Step ${stepIndex + 1}: ${stepTexts[stepIndex]}")
                } else speak("That was the last step.")
            }
            VoiceCommand.Previous -> {
                if (stepIndex > 0) {
                    stepIndex--
                    session.go(stepIndex)
                    speak("Step ${stepIndex + 1}: ${stepTexts[stepIndex]}")
                } else speak("You're on the first step.")
            }
            VoiceCommand.RepeatStep -> speak("Step ${stepIndex + 1}: ${stepTexts[stepIndex]}")
            is VoiceCommand.GoToStep -> {
                val valid = validatedStep(cmd.step, steps.size)
                if (valid == null) speak("There are only ${steps.size} steps.")
                else {
                    stepIndex = valid - 1
                    session.go(stepIndex)
                    speak("Step $valid: ${stepTexts[stepIndex]}")
                }
            }
            VoiceCommand.StartOver -> {
                stepIndex = 0
                session.go(0)
                speak("Starting over. Step 1: ${stepTexts.firstOrNull().orEmpty()}")
            }
            VoiceCommand.ReadIngredients -> {
                speak(ingredients.joinToString("; ") { scaledDisplay(it.name, it.quantity, it.unit, factor) })
            }
            is VoiceCommand.IngredientAmount -> {
                val match = fuzzyVoiceMatch(cmd.name, ingredients.map { it.name })
                val found = ingredients.firstOrNull { it.name == match }
                if (found == null) speak("I couldn't find ${cmd.name}.")
                else speak(scaledDisplay(found.name, found.quantity, found.unit, factor))
            }
            is VoiceCommand.CrossOff -> {
                val id = ingredientId(cmd.name, voiceIngredients)
                if (id == null) speak("Which one? I couldn't match ${cmd.name}.")
                else {
                    crossedIngredients = crossedIngredients + id
                    session.toggleIngredient(id)
                    speak("Crossed off ${cmd.name}.")
                }
            }
            is VoiceCommand.Uncross -> {
                val id = ingredientId(cmd.name, voiceIngredients)
                if (id == null) speak("Which one? I couldn't match ${cmd.name}.")
                else {
                    crossedIngredients = crossedIngredients - id
                    speak("Uncrossed ${cmd.name}.")
                }
            }
            VoiceCommand.DoubleScale, VoiceCommand.HalveScale, VoiceCommand.ResetScale -> {
                val scaleCmd = ScaleVoiceCommand.from(cmd)!!
                val next = applyScaleCommand(scaleCmd, baseServings, targetServings)
                targetServings = next.coerceIn(maxOf(0.25, baseServings * 0.25), baseServings * 4)
                speak("Servings set to ${fractionDisplayString(targetServings)}.")
            }
            is VoiceCommand.AddToList -> speak(
                if (cmd.listName == null) "Added to your list." else "Added to your ${cmd.listName} list.",
            )
            is VoiceCommand.StartTimer -> {
                if (cmd.seconds == null) {
                    val t = session.timers.firstOrNull()
                    if (t == null) speak("No timers in these steps.")
                    else {
                        scheduledIds += CookActivityStub.schedule(listOf(t))
                        scheduledCount = scheduledIds.size
                        speak("Timer started for ${t.label}.")
                    }
                } else {
                    scheduledIds += CookActivityStub.schedule(
                        listOf(com.keepcooking.app.cook.ParsedTimer(cmd.seconds, cmd.label ?: "Voice timer")),
                    )
                    scheduledCount = scheduledIds.size
                    speak("Timer started.")
                }
            }
            VoiceCommand.StopSpeaking -> speak("")
            VoiceCommand.StopCooking -> speak("Done cooking. Bon appétit!")
            VoiceCommand.Unknown -> speak("Sorry, I didn't catch that.")
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text(title) }) }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Sticky-style servings scaler.
            Card { Column(Modifier.padding(16.dp)) {
                Text("SERVINGS", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary)
                Text(
                    "${fractionDisplayString(targetServings)} servings (${"%.2g".format(factor)}×)",
                    style = MaterialTheme.typography.titleMedium,
                )
                Slider(
                    value = targetServings.toFloat(),
                    onValueChange = { targetServings = it.toDouble() },
                    valueRange = maxOf(0.25f, (baseServings * 0.25).toFloat())..(baseServings * 4).toFloat(),
                    steps = 0,
                )
            } }

            // Progress header.
            Card { Column(Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Step ${stepIndex + 1} of ${steps.size}", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.weight(1f))
                    Text("${(progress * 100).toInt()}%", style = MaterialTheme.typography.labelMedium)
                }
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(8.dp))
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    steps.forEachIndexed { idx, _ ->
                        val done = crossedSteps.contains(steps[idx].id)
                        Box(
                            Modifier.size(width = if (idx == stepIndex) 28.dp else 16.dp, height = 8.dp)
                                .clip(RoundedCornerShape(4.dp))
                                .background(
                                    when {
                                        idx == stepIndex -> MaterialTheme.colorScheme.primary
                                        done -> MaterialTheme.colorScheme.tertiary
                                        else -> MaterialTheme.colorScheme.surfaceVariant
                                    },
                                ),
                        )
                    }
                }
            } }

            // Step pager card.
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                Column(Modifier.padding(20.dp)) {
                    Text("STEP ${stepIndex + 1}", style = MaterialTheme.typography.labelSmall)
                    Text(steps[stepIndex].text, style = MaterialTheme.typography.titleLarge, lineHeight = MaterialTheme.typography.titleLarge.lineHeight)
                    Spacer(Modifier.height(12.dp))
                    val done = crossedSteps.contains(steps[stepIndex].id)
                    OutlinedButton(onClick = {
                        val id = steps[stepIndex].id
                        crossedSteps = if (done) crossedSteps - id else crossedSteps + id
                        session.toggleStep(id)
                    }) { Text(if (done) "✓ Done — tap to unmark" else "Mark done") }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(
                    onClick = { stepIndex = maxOf(0, stepIndex - 1); session.go(stepIndex) },
                    enabled = stepIndex > 0,
                    modifier = Modifier.weight(1f),
                ) { Text("Back") }
                Button(
                    onClick = {
                        if (stepIndex >= steps.size - 1) {
                            crossedSteps = crossedSteps + steps.last().id
                            session.markStepDone(steps.last().id)
                        } else {
                            stepIndex++
                            session.go(stepIndex)
                        }
                    },
                    modifier = Modifier.weight(1f),
                ) { Text(if (stepIndex >= steps.size - 1) "Finish" else "Next") }
            }

            // Ingredients checklist.
            Card { Column(Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Ingredients", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.weight(1f))
                    Text("${fractionDisplayString(targetServings)} servings", style = MaterialTheme.typography.labelMedium)
                    TextButton(onClick = { ingredientsExpanded = !ingredientsExpanded }) {
                        Text(if (ingredientsExpanded) "Hide" else "Show")
                    }
                }
                if (ingredientsExpanded) {
                    val done = ingredients.count { crossedIngredients.contains(it.id) }
                    Text("$done of ${ingredients.size} gathered", style = MaterialTheme.typography.labelSmall)
                    ingredients.forEach { ing ->
                        val isDone = crossedIngredients.contains(ing.id)
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                        ) {
                            IconButton(onClick = {
                                crossedIngredients = if (isDone) crossedIngredients - ing.id else crossedIngredients + ing.id
                                session.toggleIngredient(ing.id)
                            }) {
                                Icon(
                                    if (isDone) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                                    contentDescription = if (isDone) "gathered" else "not gathered",
                                )
                            }
                            Text(
                                scaledDisplay(ing.name, ing.quantity, ing.unit, factor),
                                style = MaterialTheme.typography.bodyLarge,
                                color = if (isDone) MaterialTheme.colorScheme.secondary else MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                }
            } }

            // Timers.
            Card { Column(Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Timer, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Timers", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.weight(1f))
                    if (session.timers.isNotEmpty()) Text("${session.timers.size}")
                }
                if (session.timers.isEmpty()) {
                    Text(
                        "No timers in these steps. When a step mentions minutes, its timer appears here with a Start button.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                } else {
                    session.timers.forEachIndexed { idx, timer ->
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                            Column(Modifier.weight(1f)) {
                                Text(timer.label, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                                Text(durationString(timer.seconds), style = MaterialTheme.typography.bodySmall)
                            }
                            Button(onClick = {
                                scheduledIds += CookActivityStub.schedule(listOf(timer))
                                scheduledCount = scheduledIds.size
                            }) { Text("Start") }
                        }
                    }
                    Button(onClick = {
                        scheduledIds.addAll(CookActivityStub.schedule(session.timers))
                        scheduledCount = scheduledIds.size
                    }, modifier = Modifier.fillMaxWidth()) { Text("Start all timers") }
                }
                if (scheduledCount > 0) Text("$scheduledCount timer(s) scheduled", style = MaterialTheme.typography.labelSmall)
            } }

            // Keep-awake pill.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(MaterialTheme.colorScheme.tertiary))
                Spacer(Modifier.width(8.dp))
                Text("Screen stays awake while you cook", style = MaterialTheme.typography.labelMedium)
            }

            // Voice bar.
            Card { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        if (steps.isNotEmpty()) "Step ${stepIndex + 1} of ${steps.size}" else "No steps",
                        style = MaterialTheme.typography.titleSmall,
                    )
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = {
                        readAloud = !readAloud
                        if (!readAloud) lastReply = ""
                    }) {
                        Icon(
                            if (readAloud) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff,
                            contentDescription = if (readAloud) "Read aloud on" else "Read aloud off",
                        )
                    }
                    IconButton(onClick = { listening = !listening }) {
                        Icon(
                            if (listening) Icons.Filled.Mic else Icons.Filled.MicOff,
                            contentDescription = if (listening) "Listening on" else "Listening off",
                        )
                    }
                }
                if (lastReply.isNotEmpty()) Text(lastReply, style = MaterialTheme.typography.bodyMedium)
                if (listening) {
                    OutlinedTextField(
                        value = voiceInput,
                        onValueChange = { voiceInput = it },
                        label = { Text("Say: next, go to step 2, set a timer…") },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                    Button(onClick = {
                        handleVoice(parseVoiceCommand(voiceInput))
                        voiceInput = ""
                    }, enabled = voiceInput.isNotBlank(), modifier = Modifier.fillMaxWidth()) {
                        Text("Send voice command")
                    }
                    Text("Try: “smidgen next”, “go to step two”, “start a timer for 10 minutes”.",
                        style = MaterialTheme.typography.labelSmall)
                } else {
                    Text("Tap the mic to type a voice command.", style = MaterialTheme.typography.labelSmall)
                }
            } }
            Spacer(Modifier.height(56.dp))
        }
    }
}

private fun durationString(seconds: Int): String = when {
    seconds >= 3600 -> {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        if (m == 0) "$h hr" else "$h hr $m min"
    }
    seconds >= 60 -> "${seconds / 60} min"
    else -> "$seconds sec"
}

/** Sets FLAG_KEEP_SCREEN_ON on the hosting view while composed. */
@Composable
private fun KeepScreenOnEffect() {
    // KeepAwake bookkeeping (mirrors the iOS helper); the view flag does the work.
    AndroidView(factory = { context -> View(context).apply { keepScreenOn = true } })
}
