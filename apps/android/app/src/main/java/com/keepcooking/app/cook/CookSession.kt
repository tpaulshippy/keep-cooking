package com.keepcooking.app.cook

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import java.util.UUID

/**
 * Cook session state — port of apps/ios/Features/Cook/CookSession.swift.
 * Step pager state (index, crossed-off steps, per-ingredient cross-off, timers).
 * The session class itself is pure Kotlin (no Android framework dependency so
 * it stays unit-testable); device alerts live in [CookActivityStub] below.
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
 * Background timer-alert seam. Timers armed through [CookActivityStub.schedule]
 * with a [Context] fire a real device alert: `setExactAndAllowWhileIdle` (or
 * the best inexact fallback when the exact-alarm grant is missing) wakes
 * [CookTimerReceiver], which posts a high-priority notification. The pure
 * [schedule] overload only mints stable IDs and records pending timers (kept
 * for unit tests and call sites without a Context).
 *
 * Permission flow (lives in the Cook timer UI — CookScreen — not here: this
 * file stays unit-testable with no Activity reference):
 *   - POST_NOTIFICATIONS (API 33+, off by default): requested via an
 *     ActivityResultLauncher before the UI promises alerts.
 *   - SCHEDULE_EXACT_ALARM (API 31+): granted in Settings via
 *     [CookTimerPermissions.exactAlarmSettingsIntent]; without it alarms fall
 *     back to inexact (see armAlarm).
 * [CookTimerPermissions] centralizes both checks so the UI can gate copy.
 *
 * UI copy rule: claim a live alert ("Timer started — we'll alert you") only
 * when [CookActivityStub.hasRealAlarms] is true; otherwise use honest fallback
 * copy ("Timer noted — enable notifications for alerts") since the alarm may
 * never be seen.
 */
object CookActivityStub {
    const val ACTION_TIMER_FIRED = "com.keepcooking.app.cook.TIMER_FIRED"
    const val EXTRA_TIMER_ID = "timer_id"
    const val EXTRA_SECONDS = "seconds"
    const val EXTRA_LABEL = "label"

    const val CHANNEL_ID = "cook_timers"

    private val pending: MutableMap<String, ParsedTimer> = mutableMapOf()

    /** Pure ID builder: one UUID batch per call so per-timer starts never collide. */
    fun makeIDs(forTimers: List<ParsedTimer>): List<String> {
        val batch = UUID.randomUUID().toString()
        return forTimers.mapIndexed { index, timer -> "cook-timer-$batch-$index-${timer.seconds}" }
    }

    /** Records pending timers and returns the scheduled ids (no device alarms). */
    fun schedule(timers: List<ParsedTimer>): List<String> {
        val ids = makeIDs(timers)
        ids.zip(timers).forEach { (id, timer) -> pending[id] = timer }
        return ids
    }

    /**
     * Records pending timers AND arms a real device alarm per timer, posting
     * a notification via [CookTimerReceiver] when each fires. Same ID contract
     * as [schedule]. This is the timer path Cook UI and shortcuts share.
     */
    fun schedule(context: Context, timers: List<ParsedTimer>): List<String> {
        val ids = schedule(timers)
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return ids
        ensureChannel(context)
        ids.zip(timers).forEach { (id, timer) -> armAlarm(context, alarms, id, timer) }
        return ids
    }

    fun cancel(ids: List<String>) {
        ids.forEach { pending.remove(it) }
    }

    /** Cancels device alarms + posted notifications as well as pending records. */
    fun cancel(context: Context, ids: List<String>) {
        cancel(ids)
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        ids.forEach { id ->
            if (alarms != null) alarms.cancel(timerPendingIntent(context, id))
            timerPendingIntent(context, id).cancel()
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        ids.forEach { nm?.cancel(it.hashCode()) }
    }

    /**
     * True when a scheduled timer will actually alert: an AlarmManager is
     * present and notifications are enabled (API 33+ gates visible alerts on
     * POST_NOTIFICATIONS). Gate "Timer started" copy on this.
     */
    fun hasRealAlarms(context: Context): Boolean {
        if (context.getSystemService(Context.ALARM_SERVICE) !is AlarmManager) return false
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return false
        return nm.areNotificationsEnabled()
    }

    /** Removes a fired timer from the pending record (called by the receiver). */
    fun acknowledge(id: String) {
        pending.remove(id)
    }

    fun startLiveActivityStub(timerCount: Int) {
        // Intentional no-op: count only, no PII.
    }

    fun endLiveActivityStub() {}

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Cook timers", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Alerts when a cook timer finishes."
                },
            )
        }
    }

    private fun armAlarm(context: Context, alarms: AlarmManager, id: String, timer: ParsedTimer) {
        val at = System.currentTimeMillis() + timer.seconds * 1000L
        val pi = timerPendingIntent(context, id, timer)
        // Exact alarms need no grant below API 31; on S+ they need the user's
        // SCHEDULE_EXACT_ALARM grant (see CookTimerPermissions). Without it use
        // the best inexact fallback and show honest timer copy (see CookScreen).
        // (minSdk 26: no pre-M branch — set() fallback would be unreachable.)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    private fun timerPendingIntent(context: Context, id: String, timer: ParsedTimer? = null): PendingIntent {
        val intent = Intent(context, CookTimerReceiver::class.java).apply {
            action = ACTION_TIMER_FIRED
            putExtra(EXTRA_TIMER_ID, id)
            if (timer != null) {
                putExtra(EXTRA_SECONDS, timer.seconds)
                putExtra(EXTRA_LABEL, timer.label)
            }
        }
        return PendingIntent.getBroadcast(
            context, id.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/**
 * Timer-permission checks shared by the Cook timer UI (CookScreen owns the
 * ActivityResultLauncher flow; MainActivity owns none of it).
 */
object CookTimerPermissions {
    /** POST_NOTIFICATIONS is install-granted below API 33; on 33+ check the runtime grant. */
    fun notificationsGranted(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** Exact alarms need no grant below API 31; on S+ check the Settings grant. */
    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        return alarms.canScheduleExactAlarms()
    }

    /** Opens the system exact-alarm grant screen (API 31+; no-op elsewhere). */
    fun exactAlarmSettingsIntent(): Intent =
        Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
}

/**
 * Alarm receiver: fires when a cook timer elapses and posts the visible
 * alert. Registered in AndroidManifest.xml (explicit intents only).
 */
class CookTimerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != CookActivityStub.ACTION_TIMER_FIRED) return
        val id = intent.getStringExtra(CookActivityStub.EXTRA_TIMER_ID) ?: return
        val label = intent.getStringExtra(CookActivityStub.EXTRA_LABEL).orEmpty().ifEmpty { "Timer" }
        CookActivityStub.acknowledge(id)
        CookActivityStub.ensureChannel(context)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val openApp = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            PendingIntent.getActivity(
                context, id.hashCode(), launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val notification = NotificationCompat.Builder(context, CookActivityStub.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(label)
            .setContentText("Your timer is up.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setContentIntent(openApp)
            .build()
        nm.notify(id.hashCode(), notification)
    }
}
