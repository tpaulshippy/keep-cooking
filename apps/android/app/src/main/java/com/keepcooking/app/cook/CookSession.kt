package com.keepcooking.app.cook

import java.util.UUID

/**
 * Cook session state — port of apps/ios/Features/Cook/CookSession.swift.
 * Step pager state (index, crossed-off steps, per-ingredient cross-off, timers).
 * Pure Kotlin, no persistence layer, no Android framework dependency so it
 * stays unit-testable (keep-screen-on / notifications live in the UI layer).
 */
class CookSession(stepCount: Int = 1) {
    var stepIndex: Int = 0
        private set
    var stepCount: Int = maxOf(1, stepCount)
        private set
    val crossedOffSteps: MutableSet<String> = mutableSetOf() // Step.id
    val crossedOffIngredients: MutableSet<String> = mutableSetOf() // Ingredient.id
    var scale: Double = 1.0 // 0.25x–4x, clamped by UI stepper
    var timers: List<ParsedTimer> = emptyList()
        private set

    fun go(to: Int) {
        stepIndex = to.coerceIn(0, stepCount - 1)
    }

    fun next() = go(to = stepIndex + 1)
    fun previous() = go(to = stepIndex - 1)

    fun toggleStep(id: String) {
        if (!crossedOffSteps.remove(id)) crossedOffSteps.add(id)
    }

    /** Idempotent "done": repeat calls never unmark. The step card's toggle remains the unmark action. */
    fun markStepDone(id: String) {
        crossedOffSteps.add(id)
    }

    fun toggleIngredient(id: String) {
        if (!crossedOffIngredients.remove(id)) crossedOffIngredients.add(id)
    }

    fun loadTimers(fromStepTexts: List<String>) {
        timers = fromStepTexts.flatMap { parseTimers(it) }
    }
}

/** Voice scale commands ("double / halve / reset the recipe"). */
enum class ScaleVoiceCommand {
    DOUBLE,
    HALVE,
    RESET,
    ;

    companion object {
        fun from(voice: VoiceCommand): ScaleVoiceCommand? = when (voice) {
            VoiceCommand.DoubleScale -> DOUBLE
            VoiceCommand.HalveScale -> HALVE
            VoiceCommand.ResetScale -> RESET
            else -> null
        }
    }
}

/**
 * Applies a voice scale command to a servings pair. Double/halve are
 * relative to the base servings; reset returns to base. Pure (no state).
 * Returns the new target servings (Kotlin has no inout params).
 */
fun applyScaleCommand(command: ScaleVoiceCommand, baseServings: Double, targetServings: Double): Double =
    when (command) {
        ScaleVoiceCommand.DOUBLE -> baseServings * 2
        ScaleVoiceCommand.HALVE -> baseServings / 2
        ScaleVoiceCommand.RESET -> baseServings
    }

/** One ingredient candidate for fuzzy voice lookup. */
data class VoiceIngredientRef(val id: String, val name: String)

/**
 * Fuzzy ingredient-id lookup using the same normalization as the voice
 * parser ([fuzzyVoiceMatch]). Pure (no state).
 * When multiple ingredients share the same normalized label, returns null
 * so the caller can reply with a disambiguation prompt.
 */
fun ingredientId(matching: String, ingredients: List<VoiceIngredientRef>): String? {
    val matched = fuzzyVoiceMatch(matching, ingredients.map { it.name }) ?: return null
    val norm = voiceNormalizedName(matched)
    val dupes = ingredients.filter { voiceNormalizedName(it.name) == norm }
    if (dupes.size != 1) return null
    return dupes.first().id
}

/**
 * Keep-screen-on seam. The Compose UI sets `view.keepScreenOn` directly;
 * this object mirrors the iOS KeepAwake enable/disable contract for call sites.
 */
object KeepAwake {
    var enabled: Boolean = false
        private set

    fun enable() {
        enabled = true
    }

    fun disable() {
        enabled = false
    }
}

/**
 * Background timer-alert seam. Local-notification wiring lands here
 * (AlarmManager / NotificationManager); today this only mints stable IDs
 * and records pending timers, mirroring the iOS CookActivityStub contract.
 */
object CookActivityStub {
    private val pending: MutableMap<String, ParsedTimer> = mutableMapOf()

    /** Pure ID builder: one UUID batch per call so per-timer starts never collide. */
    fun makeIDs(forTimers: List<ParsedTimer>): List<String> {
        val batch = UUID.randomUUID().toString()
        return forTimers.mapIndexed { index, timer -> "cook-timer-$batch-$index-${timer.seconds}" }
    }

    /** Records pending timers and returns the scheduled ids. */
    fun schedule(timers: List<ParsedTimer>): List<String> {
        val ids = makeIDs(timers)
        ids.zip(timers).forEach { (id, timer) -> pending[id] = timer }
        return ids
    }

    fun cancel(ids: List<String>) {
        ids.forEach { pending.remove(it) }
    }

    fun startLiveActivityStub(timerCount: Int) {
        // Intentional no-op: count only, no PII.
    }

    fun endLiveActivityStub() {}
}
