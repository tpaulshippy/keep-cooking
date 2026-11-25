// Keep Cooking — Lane 10 Voice (Option A): speech I/O manager
// @Observable @MainActor class owning read-aloud (AVSpeechSynthesizer, recipe
// locale) + continuous listening (SFSpeechRecognizer + AVAudioEngine).
// Listening is simulator-stubbed: the `VoiceAudioInput` protocol ({start/stop})
// lets tests inject `MockVoiceInput`; when the mic/recognizer is unavailable
// the manager falls back to the mock and flags `micDenied`.
//
// Toggles persist via the same keys the UI lane uses:
//   cook.readAloudEnabled (default true), cook.listeningEnabled (default false).
// Replies: every handled command sets `lastReply` AND speaks it (Paprika
// parity: show + say each reply). Commands are only handled while the app is
// frontmost (`UIApplication.applicationState == .active` where available).
//
// Cubic review fixes (manager+session lane):
//   - `VoiceIngredient` (id/name/quantity/unit) feeds `handle`; amount replies
//     scale via `scaledDisplay(..., factor: session.scale)`.
//   - View-wired callbacks: `onScaleCommand` (clamped factor),
//     `onTimerCommand`, `onStopCooking`, `onAddToList`. Add-to-list / timer
//     never claim success without a real write/schedule.
//   - Step-read interrupts: `readCurrentStep` stops the current utterance
//     before speaking the new step (see also `readCurrentStepInterrupting`).
//   - Permission-then-start: `requestPermissions(completion:)` /
//     `requestPermissionsThenStart(_:)` join mic + speech results; the legacy
//     `requestPermissions()` calls through.
//   - `stopListening` clears persisted `listeningEnabled` and cancels any
//     pending permission completion, so a late auth result can never start
//     the mic after the view disappeared; `startListening` also guards on
//     the flag. Simulator-only mock fallback: on device a missing
//     recognizer reports a failed start instead of fake "listening".
//   - Ambiguity: ties use `isFuzzyVoiceMatchAmbiguous` ("Which <name>?");
//     `fuzzyVoiceMatch` nil alone means "I don't see ...".
//   - Voice-started timer ids are retained in `scheduledTimerIds` for
//     CookModeView.onDisappear cancellation.
//   - Shared handoff: `consumePendingCommand(session:ingredients:steps:)`
//     reads + clears the exact UserDefaults key "cook.pendingCommand".

import Foundation
import AVFoundation
import Speech

#if os(iOS)
import UIKit
#endif

// MARK: - Voice ingredient (contract: designer UI lane depends on this shape)

/// Ingredient as seen by voice commands: identity + scaled-amount data.
/// Amount replies render via
/// `scaledDisplay(name:quantity:unit:factor:)` with `factor = session.scale`;
/// `quantity == nil` (unmeasured, e.g. "salt to taste") replies name only.
public struct VoiceIngredient: Sendable {
    public var id: String
    public var name: String
    public var quantity: Double?
    public var unit: String
    public init(id: String, name: String, quantity: Double? = nil, unit: String = "") {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
    }
}

// MARK: - Audio input seam

/// Continuous-listening input. Production uses `LiveVoiceInput`;
/// simulator/tests use `MockVoiceInput`.
public protocol VoiceAudioInput: AnyObject {
    var isRunning: Bool { get }
    func start(onTranscript: @escaping (String) -> Void)
    func stop()
}

// MARK: - Transcript source (TEMPORARY TestFlight diagnostic)

/// Where a delivered transcript came from. Real Apple finals and stable-fired
/// partials share the SAME manager final-delivery path; the DEBUG line tags
/// which one fired so device logs stay interpretable.
enum VoiceTranscriptSource {
    case final
    case partialStable
}

/// In-memory input for the simulator and tests. Tests inject this via
/// `startListening(using:onTranscript:)` and drive transcripts with `emit(_:)`.
public final class MockVoiceInput: VoiceAudioInput {
    public private(set) var isRunning = false
    private var onTranscript: ((String) -> Void)?

    public init() {}

    public func start(onTranscript: @escaping (String) -> Void) {
        isRunning = true
        self.onTranscript = onTranscript
    }

    public func stop() {
        isRunning = false
        onTranscript = nil
    }

    /// Test/simulator helper: deliver a transcript as if recognized.
    public func emit(_ transcript: String) { onTranscript?(transcript) }
}

/// On-device continuous recognition (SFSpeechRecognizer + AVAudioEngine).
/// Failable: nil when recognition is unavailable (including the simulator),
/// so the manager can fall back and flag `micDenied`.
public final class LiveVoiceInput: VoiceAudioInput {
    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    public private(set) var isRunning = false
    private var shouldKeepListening = false
    private var onTranscript: ((String) -> Void)?
    /// Live partial words for display (set by the manager). Also the
    /// barge-in trigger: a non-echo partial arriving while TTS speaks
    /// stops TTS (see `startListening`). Never routed to command handling.
    var onPartial: ((String) -> Void)?
    /// Recognition failures for display (set by the manager).
    var onError: ((String) -> Void)?
    /// Non-error task events for TEMPORARY TestFlight diagnostics (set by
    /// the manager): recognition route at task start, stale-callback drops.
    /// True errors stay on `onError` only.
    var onEvent: ((String) -> Void)?
    private var lastForwarded = ""
    private var lastPartialForwarded = ""
    /// Recognition route for this session. Starts on-device when the
    /// recognizer supports it; drops to server on the first on-device
    /// failure and stays there (retrying a missing offline model every
    /// 0.8s would just delay hearing). Reset every `start`, so the next
    /// session tries on-device again.
    private var preferOnDevice = true
    private var generation = 0
    private var tapInstalled = false

    public init?(locale: Locale = .current) {
        #if targetEnvironment(simulator)
        return nil
        #else
        // Locale fallback: `.current` may resolve to an unsupported locale
        // (init succeeds but `isAvailable` is false and the task errors
        // silently). Prefer current when usable, else en-US.
        if let r = SFSpeechRecognizer(locale: locale), r.isAvailable {
            recognizer = r
        } else if let fallback = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) {
            recognizer = fallback
        } else {
            return nil
        }
        #endif
    }

    public func start(onTranscript: @escaping (String) -> Void) {
        stopEngineAndTask()
        shouldKeepListening = true
        self.onTranscript = onTranscript
        lastForwarded = ""
        lastPartialForwarded = ""
        preferOnDevice = recognizer.supportsOnDeviceRecognition
        #if os(iOS)
        configureAudioSession()
        #endif
        startEngineIfNeeded()
        startRecognition()
        isRunning = engine.isRunning && shouldKeepListening
        if !isRunning {
            stopEngineAndTask()
        }
    }

    public func stop() {
        shouldKeepListening = false
        generation += 1
        onTranscript = nil
        onPartial = nil
        onError = nil
        onEvent = nil
        stopEngineAndTask()
        #if os(iOS)
        deactivateAudioSession()
        #endif
    }

    /// Records a stable-fired text in the within-task dedup state, so a late
    /// Apple final for the same text dedups instead of double-firing.
    /// Called by the manager's stable-partial fallback (same generation).
    func markConsumed(_ text: String) {
        lastForwarded = text
        lastPartialForwarded = text
    }

    /// Soft restarts ONLY the recognition task after a stable execution:
    /// fresh generation + cleared within-task dedup so the SAME command
    /// works again. The AVAudioEngine and mic tap keep running (no audio
    /// gap); the only `endAudio` is the standard request teardown inside
    /// `startRecognition`.
    func restartRecognitionKeepingEngine() {
        guard shouldKeepListening else { return }
        startRecognition()
    }

    // MARK: - Continuous recognition internals

    /// Starts (or restarts) one recognition request on the already-running
    /// engine. Apple ends tasks after a final result, ~60s, or transient
    /// errors — without a restart the engine keeps running but delivers
    /// zero transcripts ("shows listening but no reply").
    private func startRecognition() {
        guard shouldKeepListening else { return }
        // Fresh task = fresh utterance stream: clear within-task duplicate
        // suppression so repeating the same word ("next", "repeat") is heard
        // again. Keeps suppression within a single task only.
        lastForwarded = ""
        lastPartialForwarded = ""
        generation += 1
        let myGeneration = generation
        // Stale task/request from the previous generation: end them; their
        // callbacks carry the old generation and are ignored below.
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        guard recognizer.isAvailable else {
            let message = "Speech recognition isn't available right now — check your connection."
            DispatchQueue.main.async { [weak self] in self?.onError?(message) }
            scheduleRestart(after: 1.5, generation: myGeneration)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        // Partial results keep the task alive through pauses; we only
        // forward finals (partials like "nex" would spam "didn't catch that").
        request.shouldReportPartialResults = true
        // Dictation hint: continuous command-style utterances, not a search
        // query (reference parity: continuous implementations set this).
        request.taskHint = .dictation
        // On-device first for privacy + offline use; server fallback happens
        // in the task-error handler below when the on-device attempt fails
        // (missing offline model, unsupported language, ...). Forcing
        // on-device unconditionally fails silently with zero transcripts
        // when the model isn't downloaded, so it must never be required.
        request.requiresOnDeviceRecognition = preferOnDevice
        self.request = request
        // TEMPORARY TestFlight diagnostic: which route this task uses.
        // Surfaced via onEvent so the manager can show it in lastDebugLine.
        let routeLabel = preferOnDevice ? "on-device" : "server"
        DispatchQueue.main.async { [weak self] in self?.onEvent?("route=\(routeLabel)") }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            guard myGeneration == self.generation else {
                // Stale task/request from a previous generation: dropped.
                // Previously invisible; surfaced so a restart loop is
                // distinguishable from a dead task in TestFlight diagnostics.
                DispatchQueue.main.async { [weak self] in self?.onEvent?("stale-drop gen=\(myGeneration)") }
                return
            }
            // Result BEFORE error: Apple can bundle a final result with an
            // error, and discarding the result would drop a heard command.
            // The error half still runs below (fallback/message/restart)
            // unless the result half already forwarded a final + scheduled
            // its restart — one restart per callback, never two.
            var finalForwarded = false
            if let result {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    if result.isFinal {
                        if text != self.lastForwarded {
                            self.lastForwarded = text
                            self.lastPartialForwarded = text
                            DispatchQueue.main.async { [weak self] in
                                self?.onTranscript?(text)
                            }
                        }
                        finalForwarded = true
                        // Apple finishes the task after a final — restart so
                        // the NEXT command is heard.
                        self.scheduleRestart(after: 0.25, generation: myGeneration)
                    } else if text != self.lastPartialForwarded {
                        // Live display only: partials update the Heard caption
                        // so the cook sees audio flowing before pausing for
                        // the final. Never routed to command handling
                        // (partials like "nex" would spam "didn't catch
                        // that"); the manager's stable-partial fallback owns
                        // execution for stalled endpointing.
                        self.lastPartialForwarded = text
                        DispatchQueue.main.async { [weak self] in
                            self?.onPartial?(text)
                        }
                    }
                }
            }
            if let error {
                guard self.shouldKeepListening else { return }
                // A forwarded final already executed + scheduled its restart;
                // surfacing this bundled error would alarm over a success and
                // double-schedule the restart.
                if finalForwarded { return }
                if self.preferOnDevice {
                    // On-device attempt failed — fall back to server for the
                    // rest of this session (next session tries on-device
                    // again). The note clears on the next transcript.
                    self.preferOnDevice = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onError?("On-device speech isn't available — using online recognition.")
                    }
                    self.scheduleRestart(after: 0.5, generation: myGeneration)
                    return
                }
                // Surface the cause: without this the engine runs with zero
                // transcripts and the pill claims "listening" (the deaf-mic
                // report). The manager dedups repeats from the retry loop.
                let nsError = error as NSError
                let message: String
                if nsError.domain == NSURLErrorDomain {
                    message = "Speech recognition can't reach Apple — check your connection."
                } else {
                    message = nsError.localizedDescription
                }
                DispatchQueue.main.async { [weak self] in self?.onError?(message) }
                // Transient (network handoff, audio glitch, timeout):
                // fresh request so listening resumes instead of going deaf.
                self.scheduleRestart(after: 0.8, generation: myGeneration)
                return
            }
        }
    }

    private func scheduleRestart(after delay: TimeInterval, generation gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldKeepListening, gen == self.generation else { return }
            self.startRecognition()
        }
    }

    private func startEngineIfNeeded() {
        if !tapInstalled {
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            tapInstalled = true
        }
        if !engine.isRunning {
            do {
                engine.prepare()
                try engine.start()
            } catch {
                // `isRunning` check in `start` reports the failure.
            }
        }
    }

    private func stopEngineAndTask() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRunning = false
    }

    #if os(iOS)
    /// Mode stays `.spokenAudio`: `.voiceChat` was tried for its hardware
    /// echo cancellation but rendered TTS inaudible in practice, so it was
    /// reverted — barge-in matching in `startListening` remains the echo
    /// defense. `.spokenAudio` is proven audible with this exact setup.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            // Engine start below still reports failure via `isRunning`.
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Best effort; nothing for the caller to do.
        }
    }
    #endif
}

// MARK: - Manager

@Observable
@MainActor
public final class VoiceCookManager {
    // Same keys the UI lane uses (project.yml: cook.readAloudEnabled default
    // true, cook.listeningEnabled default false). Stored (not @AppStorage:
    // @AppStorage clashes with @Observable synthesis) and mirrored to
    // UserDefaults on change.
    public var readAloudEnabled: Bool = UserDefaults.standard.object(forKey: "cook.readAloudEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(readAloudEnabled, forKey: "cook.readAloudEnabled") }
    }
    public var listeningEnabled: Bool = UserDefaults.standard.object(forKey: "cook.listeningEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(listeningEnabled, forKey: "cook.listeningEnabled") }
    }

    public private(set) var isReadingAloud = false
    public private(set) var isListening = false
    public var lastReply = ""
    /// Latest transcript the recognizer delivered (live partials + finals).
    /// Shown in the pill so the cook can tell "heard but not understood"
    /// apart from "not hearing". Updated for both live and simulated input.
    public var lastHeardTranscript = ""
    /// TEMPORARY TestFlight debug caption (no Xcode): one-line summary of
    /// the last transcript's path through echo/front/parse/reply. Shown
    /// under the Heard line in `CookModeView.voiceHeardView`.
    public var lastDebugLine = ""
    /// Pre-barge-in arrival snapshot for the debug line (captured in
    /// `startListening` before `stopSpeakingOutput()` clears `isSpeaking`).
    private var lastArrivalWasSpeaking = false
    private var lastArrivalEcho = false
    private var lastArrivalTranscript = ""
    /// Latest recognition failure, if any. Set by the input's error path
    /// (deduped against retry-loop repeats), cleared on the next transcript
    /// or stop. Shown in the pill so silent task death is diagnosable.
    public var listeningError: String?
    /// Last text handed to TTS. A transcript matching this (normalized)
    /// while it is still playing is our own speaker — see the barge-in
    /// path in `startListening`.
    private var lastSpokenText = ""
    public private(set) var micDenied = false

    // MARK: View-wired callbacks (all optional; the view owns rendering)

    /// Fired with the clamped scale factor whenever a voice scale command
    /// applies, so the view can update `targetServings`.
    public var onScaleCommand: ((Double) -> Void)?
    /// Fired with the timer that was actually scheduled.
    public var onTimerCommand: ((ParsedTimer) -> Void)?
    /// Fired when "stop cooking" is handled, after input is torn down.
    public var onStopCooking: (() -> Void)?
    /// Fired as `(itemsDescription, listName)` when an add-to-list command is
    /// handled. When nil the manager replies honestly that it cannot edit
    /// lists from Cook mode instead of claiming success.
    public var onAddToList: ((String, String?) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioInput: VoiceAudioInput?

    /// Stability fallback: fires an unchanged KNOWN partial through the
    /// final path when Apple endpointing never delivers `isFinal=true`.
    /// Created per `startListening`; cancelled on real finals (final wins),
    /// on unknown/changed partials, and in `stopListening`.
    private var stableFirer: StablePartialFirer?
    /// Single-use consumption guard: a stable-fired text dedups a late Apple
    /// final for the SAME text arriving before the soft restart. Cleared on
    /// consumption and on every soft restart (new generation allows the same
    /// word again; stale late finals are dropped by the input's generation
    /// guard before reaching here). Pure logic lives in
    /// `StableConsumeState` (same-target tests cover it).
    private var stableConsume = StableConsumeState()
    /// External transcript consumer (the view's `handle` call). Stored so
    /// both real finals and stable-fired partials share one `deliverFinal`.
    private var externalOnTranscript: ((String) -> Void)?
    /// Source tag for the TEMPORARY TestFlight DEBUG line, set by
    /// `deliverFinal` before invoking the external consumer so `handle`'s
    /// own DEBUG line reports the same source.
    private var lastSource: VoiceTranscriptSource = .final
    /// Soft-restart work scheduled ~0.25s after each stable execution.
    private var stableRestartCancel: (() -> Void)?
    /// Test seam: when set, `startListening` and the post-stable soft
    /// restart use this scheduler instead of `DispatchQueue.main`, so
    /// same-target tests drive timing deterministically with a fake clock.
    var stableScheduler: ((TimeInterval, @escaping () -> Void) -> (() -> Void))?
    /// Stability window override for tests (defaults to 1.4s).
    var stableDelay: TimeInterval = StablePartialFirer.defaultDelay
    /// Post-stable soft-restart delay (matches the post-final 0.25s restart).
    static let stableRestartDelay: TimeInterval = 0.25

    /// Notification ids scheduled by voice-started timers (`handle`
    /// `.startTimer`). Retained so CookModeView.onDisappear can cancel them
    /// alongside its own `scheduledIds` (the schedule call's return used to
    /// be discarded, leaking voice timers past Cook mode).
    public private(set) var scheduledTimerIds: [String] = []

    // Single-flight permission join state: mic + speech results are tracked
    // separately so neither callback can clobber the other (denial race).
    private var pendingSpeechGranted: Bool?
    private var pendingMicGranted: Bool?
    private var pendingPermissionCompletion: ((Bool) -> Void)?

    /// Exact UserDefaults key the Intents lane uses to hand off a command
    /// issued while the app was backgrounded.
    public static let pendingCommandKey = "cook.pendingCommand"

    public init() {}

    // MARK: Permissions

    /// Requests mic + speech permissions and reports whether BOTH were
    /// granted. `micDenied` is set when EITHER is denied. Use this (or
    /// `requestPermissionsThenStart`) so the UI never starts the engine
    /// before authorization completes.
    public func requestPermissions(completion: @escaping (Bool) -> Void) {
        pendingSpeechGranted = nil
        pendingMicGranted = nil
        pendingPermissionCompletion = completion
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                self?.noteSpeechPermission(granted: status == .authorized)
            }
        }
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.noteMicPermission(granted: granted)
            }
        }
        #else
        noteMicPermission(granted: true)
        #endif
    }

    /// Permission-then-start: runs `body` only after BOTH mic and speech
    /// permissions are granted. The UI lane should start the engine from
    /// `body`, never before auth completes.
    public func requestPermissionsThenStart(_ body: @escaping () -> Void) {
        requestPermissions { granted in
            if granted { body() }
        }
    }

    /// Legacy entry point (kept for existing callers); calls through to the
    /// joined permission flow with no follow-up work.
    public func requestPermissions() {
        requestPermissionsThenStart {}
    }

    private func noteSpeechPermission(granted: Bool) {
        pendingSpeechGranted = granted
        finishPermissionsIfReady()
    }

    private func noteMicPermission(granted: Bool) {
        pendingMicGranted = granted
        finishPermissionsIfReady()
    }

    private func finishPermissionsIfReady() {
        guard let speech = pendingSpeechGranted,
              let mic = pendingMicGranted,
              let completion = pendingPermissionCompletion else { return }
        pendingPermissionCompletion = nil
        let granted = speech && mic
        micDenied = !granted
        if granted {
            micDenied = false
        } else {
            // Denied: clear the persisted intent so the pill doesn't stay
            // stuck on "listening" with no engine behind it (the
            // "shows listening but no reply" report).
            listeningEnabled = false
        }
        completion(granted)
    }

    // MARK: Speech output

    /// Speaks text, optionally in the recipe locale.
    public func speak(_ text: String, locale: Locale? = nil) {
        // Remembered for echo rejection: a transcript matching what we just
        // spoke (while still speaking) is our own speaker, not the cook.
        lastSpokenText = text
        #if os(iOS)
        // Re-assert the session: interruptions (calls, Siri, alerts) can
        // deactivate it mid-cook, leaving TTS — and the mic tap — silently
        // dead for the rest of the session. Idempotent when already active.
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: text)
        if let locale {
            utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier)
        }
        synthesizer.speak(utterance)
        isReadingAloud = true
    }

    /// Stops speech output immediately.
    public func stopSpeakingOutput() {
        synthesizer.stopSpeaking(at: .immediate)
        isReadingAloud = false
    }

    /// Reads the current step aloud on entry / step change when enabled.
    /// The UI lane calls this on appear and whenever `session.stepIndex` changes.
    ///
    /// Interrupt behavior (cubic finding): this stops the current utterance
    /// BEFORE speaking the new step, so step changes never talk over the
    /// previous step. `readCurrentStepInterrupting` is the explicit alias.
    public func readCurrentStep(steps: [String], session: CookSession, locale: Locale? = nil) {
        guard readAloudEnabled, isAppFrontmost else { return }
        guard session.stepIndex >= 0, session.stepIndex < steps.count else { return }
        stopSpeakingOutput()
        speak(steps[session.stepIndex], locale: locale)
    }

    /// Explicit interrupt-and-read alias. Identical to `readCurrentStep`,
    /// which already stops the current utterance before speaking the new
    /// step; provided so callers can state the interrupt intent.
    public func readCurrentStepInterrupting(steps: [String], session: CookSession, locale: Locale? = nil) {
        readCurrentStep(steps: steps, session: session, locale: locale)
    }

    // MARK: Listening

    /// Starts continuous listening. Pass a mock via `input` in tests; with
    /// nil the manager uses on-device recognition first and falls back to
    /// server recognition if the on-device attempt fails (missing offline
    /// model, ...). On the simulator it falls back to the mock (no mic
    /// needed, `micDenied` stays false so the simulator-only debug bar can
    /// inject transcripts); on device a missing recognizer reports a failed
    /// start instead of a mock that claims "listening" but never delivers
    /// transcripts.
    /// `isListening` honestly reflects `audioInput?.isRunning` after the
    /// start attempt; on failure it stays false with a retry prompt in
    /// `lastReply`.
    public func startListening(using input: VoiceAudioInput? = nil,
                               onTranscript: @escaping (String) -> Void) {
        guard listeningEnabled else { return }
        // Re-entrant begins (double onAppear, late permission completions)
        // must not tear down a live task: rebuilding the request discards
        // the in-flight utterance's final — Heard with no reply, dot on.
        if isListening, audioInput?.isRunning == true { return }
        if let input {
            audioInput = input
        } else if let live = LiveVoiceInput() {
            audioInput = live
        } else {
            #if targetEnvironment(simulator)
            // Simulated input needs no mic: leave `micDenied` false so the
            // simulator shows the debug bar instead of the denied placard.
            micDenied = false
            audioInput = MockVoiceInput()
            #else
            // Device with no usable recognizer: no mock — a mock would set
            // `isListening` with zero transcripts. Fall through with nil
            // input so the failure reply below fires honestly.
            micDenied = true
            audioInput = nil
            #endif
        }
        externalOnTranscript = onTranscript
        let scheduler = stableScheduler ?? StablePartialFirer.mainQueueSchedule
        stableFirer = StablePartialFirer(
            delay: stableDelay,
            schedule: scheduler,
            onFire: { [weak self] text in
                // Scheduler fires on main in production; hop to MainActor.
                Task { @MainActor [weak self] in
                    self?.stableFired(text)
                }
            })
        stableConsume.resetForNewGeneration()
        stableRestartCancel?()
        stableRestartCancel = nil
        audioInput?.start(onTranscript: { [weak self] transcript in
            guard let self else { return }
            self.receiveFinal(transcript, source: .final)
        })
        if let live = audioInput as? LiveVoiceInput {
            live.onPartial = { [weak self] text in
                guard let self else { return }
                self.receivePartial(text)
            }
            live.onError = { [weak self] message in
                guard let self else { return }
                // The retry loop re-reports persistent failures; only
                // publish changes so the pill doesn't churn.
                if self.listeningError != message {
                    self.listeningError = message
                }
                // TEMPORARY TestFlight diagnostic: copy the surfaced error
                // into the debug line so task death is visible on-device.
                self.lastDebugLine = "DEBUG error='\(message)'"
            }
            live.onEvent = { [weak self] event in
                guard let self else { return }
                // TEMPORARY TestFlight diagnostic: append non-error task
                // events (route, stale-drop) to the debug line.
                if self.lastDebugLine.isEmpty {
                    self.lastDebugLine = "DEBUG \(event)"
                } else {
                    self.lastDebugLine += " [\(event)]"
                }
            }
        }
        let running = audioInput?.isRunning ?? false
        isListening = running
        if !running {
            // Hard failure (no engine): drop the intent too, so the pill
            // doesn't claim "listening" while deaf. Permission denials are
            // handled the same way in `finishPermissionsIfReady`.
            listeningEnabled = false
            lastReply = "I couldn't start listening. Check the microphone and try again."
            speak(lastReply)
        } else {
            micDenied = false
            // Self-identifying build marker: no caption ever = old build;
            // stuck on this line = new build with zero finals arriving.
            lastDebugLine = "DEBUG listening — waiting for final…"
        }
    }

    /// Shared final-delivery entry: real Apple finals AND stable-fired
    /// partials both route here, so echo/frontmost/Heard handling is
    /// identical. A late Apple final matching a just-stable-fired text is
    /// dropped once (single-use `StableConsumeState`); on device the
    /// LiveVoiceInput `markConsumed` dedup is the primary guard.
    func receiveFinal(_ transcript: String, source: VoiceTranscriptSource = .final) {
        if source == .final {
            // LiveVoiceInput schedules its own post-final restart. Cancel the
            // stable-path restart so a real final arriving in the 0.25s
            // window cannot cause a second restart that interrupts the next
            // utterance. This applies to duplicate finals too: the input
            // restarts after every final, even when its text dedups.
            stableRestartCancel?()
            stableRestartCancel = nil
        }
        if source == .final, stableConsume.shouldDropFinal(transcript) {
            lastDebugLine += " [dup-drop]"
            return
        }
        // A real final supersedes any pending stable timer for an older
        // partial — otherwise the fallback would double-fire after it.
        if source == .final { stableFirer?.cancelPending() }
        deliverFinal(transcript, source: source)
    }

    /// Shared partial-handling entry (wired to `LiveVoiceInput.onPartial`).
    /// Updates Heard as today, and arms/cancels the stability fallback:
    /// unknown/ineligible partials (including mid-utterance fragments that
    /// parse `.unknown`) never fire — they just keep updating Heard.
    func receivePartial(_ text: String) {
        if synthesizer.isSpeaking {
            // Barge-in: finals need silence to fire, and our own
            // read-aloud denies it — so the first real user speech
            // over our audio stops TTS, creating the silence the
            // final needs. Our own echo (a partial contained in
            // what we're speaking) is ignored so read-aloud can't
            // cut itself off.
            if partialIsEcho(text) { return }
            stopSpeakingOutput()
        }
        lastHeardTranscript = text
        // TEMPORARY TestFlight diagnostic: proves partials flow.
        // A later final overwrites this line (see receiveFinal above).
        lastDebugLine = "DEBUG partial='\(String(text.prefix(24)))' awaiting final"
        stableFirer?.notePartial(text)
    }

    /// Stability fallback fire: route the unchanged KNOWN partial through
    /// the EXACT same final path, mark it consumed so a late Apple final
    /// for the same text dedups, tag the DEBUG line, then softly restart
    /// only the recognition task (~0.25s, engine/tap untouched) so the SAME
    /// command works again. A final arriving before that restart still hits
    /// the consumption guard and does not double-fire.
    private func stableFired(_ text: String) {
        (audioInput as? LiveVoiceInput)?.markConsumed(text)
        stableConsume.recordStableDelivery(text)
        deliverFinal(text, source: .partialStable)
        lastDebugLine += " [stable-fire]"
        let scheduler = stableScheduler ?? StablePartialFirer.mainQueueSchedule
        stableRestartCancel?()
        stableRestartCancel = scheduler(Self.stableRestartDelay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.softRestartAfterStable()
            }
        }
    }

    /// Post-stable soft restart: new generation (same word allowed again),
    /// tracker reset, pending stable work cleared. Stale late finals from
    /// the old task are dropped by the input's generation guard before
    /// reaching the manager.
    private func softRestartAfterStable() {
        stableRestartCancel = nil
        stableConsume.resetForNewGeneration()
        stableFirer?.cancelPending()
        (audioInput as? LiveVoiceInput)?.restartRecognitionKeepingEngine()
    }

    /// The extracted `startListening` onTranscript body: echo/barge-in,
    /// Heard/error, preliminary DEBUG line (tagged with the transcript
    /// source), then the external consumer.
    private func deliverFinal(_ transcript: String, source: VoiceTranscriptSource) {
        lastSource = source
        let sourceLabel = source == .final ? "final" : "partial-stable"
        // Snapshot arrival state BEFORE barge-in handling for the
        // temporary DEBUG line (stopSpeakingOutput clears isSpeaking).
        let wasSpeaking = synthesizer.isSpeaking
        let echo = isEchoOfLastSpoken(transcript)
        lastArrivalWasSpeaking = wasSpeaking
        lastArrivalEcho = echo
        lastArrivalTranscript = transcript
        if wasSpeaking {
            // Barge-in path: with hardware echo cancellation (voiceChat
            // mode) the mic stays live while replies play. Our own audio
            // is still the likeliest transcript — drop it when it matches
            // what we just spoke; otherwise stop talking and obey the
            // cook ("repeat" / "stop speaking" over a read-aloud).
            if echo {
                lastDebugLine = "DEBUG source=\(sourceLabel) speaking=true echo=true front=\(isAppFrontmost) parse=\(debugParseLabel(parseVoiceCommand(transcript))) replied=false"
                return
            }
            stopSpeakingOutput()
        }
        // Record what was heard BEFORE handling, so the pill can show
        // the words even when the command itself is unknown. A fresh
        // transcript also means recovery: drop any earlier error.
        lastHeardTranscript = transcript
        listeningError = nil
        // Preliminary line; `handle` overwrites with parse + replied.
        lastDebugLine = "DEBUG source=\(sourceLabel) speaking=\(wasSpeaking) echo=\(echo) front=\(isAppFrontmost) parse=... replied=..."
        externalOnTranscript?(transcript)
    }

    /// Tears down listening AND clears the persisted `listeningEnabled` flag,
    /// so a late permission completion (see `requestPermissionsThenStart`)
    /// can never start the mic after the view has disappeared:
    /// `startListening` guards on the flag, and the pending completion is
    /// cancelled here. CookModeView.onDisappear relies on this (it must not
    /// leave a stale "on").
    public func stopListening() {
        stableFirer?.cancelPending()
        stableFirer = nil
        stableConsume.resetForNewGeneration()
        stableRestartCancel?()
        stableRestartCancel = nil
        externalOnTranscript = nil
        pendingPermissionCompletion = nil
        pendingSpeechGranted = nil
        pendingMicGranted = nil
        listeningEnabled = false
        audioInput?.stop()
        isListening = false
        lastHeardTranscript = ""
        lastDebugLine = ""
        listeningError = nil
    }

    /// Simulator/debug helper: delivers a transcript through the active
    /// input as if it had been recognized. No-op unless listening with a
    /// `MockVoiceInput` (simulator builds / tests). Lets the simulator
    /// exercise the full `handle` path without a microphone.
    public func emitSimulatedTranscript(_ transcript: String) {
        (audioInput as? MockVoiceInput)?.emit(transcript)
    }

    // MARK: Shared handoff (Intents lane)

    /// Reads + clears the "cook.pendingCommand" value written by the Intents
    /// lane (`next` / `previous` / `repeat` / `crossoff:<name>` /
    /// `gotostep:<n>`) and applies it to `session`. Returns true when a
    /// pending value was consumed. The view should call this on appear; it
    /// cannot run in `init` because it needs a live session.
    @discardableResult
    public func consumePendingCommand(session: CookSession,
                                      ingredients: [VoiceIngredient],
                                      steps: [String]) -> Bool {
        let key = Self.pendingCommandKey
        guard let raw = UserDefaults.standard.string(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cmd.isEmpty else { return false }
        switch cmd {
        case "next":
            session.next()
            reply("Next step.")
            return true
        case "previous", "prev":
            session.previous()
            reply("Previous step.")
            return true
        case "repeat":
            if session.stepIndex >= 0, session.stepIndex < steps.count {
                reply(steps[session.stepIndex])
            } else {
                reply("Here is that step again.")
            }
            return true
        default:
            if cmd.hasPrefix("crossoff:") {
                let name = String(cmd.dropFirst("crossoff:".count)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return false }
                let tuples = ingredients.map { (id: $0.id, name: $0.name) }
                if let id = ingredientId(matching: name, in: tuples) {
                    session.crossedOffIngredients.insert(id)
                    reply("Crossed off \(name).")
                } else if isFuzzyVoiceMatchAmbiguous(name, candidates: ingredients.map { $0.name }) {
                    reply("Which \(name)? I see more than one matching ingredient.")
                } else {
                    reply("I don't see \(name) in the ingredients.")
                }
                return true
            }
            if cmd.hasPrefix("gotostep:") {
                let token = String(cmd.dropFirst("gotostep:".count)).trimmingCharacters(in: .whitespaces)
                guard let n = Int(token), n > 0 else { return false }
                let total = steps.isEmpty ? session.stepCount : steps.count
                if let target = validatedStep(n, stepCount: total) {
                    session.go(to: target - 1)
                    reply("Step \(target).")
                } else {
                    reply("There are only \(total) steps.")
                }
                return true
            }
            return false
        }
    }

    /// Tuple compatibility overload (existing view/tests pass `(id:name)`
    /// pairs); forwards to the `VoiceIngredient` implementation.
    @discardableResult
    public func consumePendingCommand(session: CookSession,
                                      ingredients: [(id: String, name: String)],
                                      steps: [String]) -> Bool {
        consumePendingCommand(session: session,
                              ingredients: ingredients.map { VoiceIngredient(id: $0.id, name: $0.name) },
                              steps: steps)
    }

    // MARK: Command handling

    /// Handles one transcript. Returns true when a command (not `.unknown`)
    /// was recognized. No-op (false) while the app is backgrounded.
    @discardableResult
    public func handle(transcript: String,
                       session: CookSession,
                       ingredients: [VoiceIngredient],
                       steps: [String]) -> Bool {
        // Prefer the pre-barge-in arrival snapshot when the transcript
        // matches what startListening just captured; otherwise sample live.
        let speakingAtArrival: Bool
        let echoAtArrival: Bool
        if transcript == lastArrivalTranscript {
            speakingAtArrival = lastArrivalWasSpeaking
            echoAtArrival = lastArrivalEcho
        } else {
            speakingAtArrival = synthesizer.isSpeaking
            echoAtArrival = isEchoOfLastSpoken(transcript)
        }
        let front = isAppFrontmost
        let cmd = parseVoiceCommand(transcript)
        let parseLabel = debugParseLabel(cmd)
        let sourceLabel = lastSource == .final ? "final" : "partial-stable"
        guard front else {
            lastDebugLine = "DEBUG source=\(sourceLabel) speaking=\(speakingAtArrival) echo=\(echoAtArrival) front=false parse=\(parseLabel) replied=false"
            return false
        }
        let replyBefore = lastReply
        let tuples = ingredients.map { (id: $0.id, name: $0.name) }
        var handled = true
        switch cmd {
        case .next:
            session.next()
            reply("Next step.")
        case .previous:
            session.previous()
            reply("Previous step.")
        case .repeatStep:
            if session.stepIndex >= 0, session.stepIndex < steps.count {
                reply(steps[session.stepIndex])
            } else {
                reply("Here is that step again.")
            }
        case .goToStep(let n):
            if n == VoiceCommand.lastStep {
                session.go(to: session.stepCount - 1)
                reply("Last step.")
            } else {
                let total = steps.isEmpty ? session.stepCount : steps.count
                if let target = validatedStep(n, stepCount: total) {
                    session.go(to: target - 1)
                    reply("Step \(target).")
                } else {
                    reply("There are only \(total) steps.")
                }
            }
        case .startOver:
            session.go(to: 0)
            reply("Starting over.")
        case .readIngredients:
            if ingredients.isEmpty {
                reply("No ingredients listed.")
            } else {
                reply("You need " + ingredients.map { $0.name }.joined(separator: ", ") + ".")
            }
        case .ingredientAmount(let name):
            if let id = ingredientId(matching: name, in: tuples),
               let found = ingredients.first(where: { $0.id == id }) {
                reply("You need \(scaledDisplay(name: found.name, quantity: found.quantity, unit: found.unit, factor: session.scale)).")
            } else if isFuzzyVoiceMatchAmbiguous(name, candidates: ingredients.map { $0.name }) {
                reply("Which \(name)? I see more than one matching ingredient.")
            } else {
                reply("I don't see \(name) in the ingredients.")
            }
        case .crossOff(let name):
            if let id = ingredientId(matching: name, in: tuples) {
                session.crossedOffIngredients.insert(id)
                reply("Crossed off \(name).")
            } else if isFuzzyVoiceMatchAmbiguous(name, candidates: ingredients.map { $0.name }) {
                reply("Which \(name)? I see more than one matching ingredient.")
            } else {
                reply("I don't see \(name) in the ingredients.")
            }
        case .uncross(let name):
            if let id = ingredientId(matching: name, in: tuples) {
                session.crossedOffIngredients.remove(id)
                reply("Put back \(name).")
            } else if isFuzzyVoiceMatchAmbiguous(name, candidates: ingredients.map { $0.name }) {
                reply("Which \(name)? I see more than one matching ingredient.")
            } else {
                reply("I don't see \(name) in the ingredients.")
            }
        case .doubleScale:
            let factor = min(4, session.scale * 2)
            session.scale = factor
            onScaleCommand?(factor)
            reply("Doubled.")
        case .halveScale:
            let factor = max(0.25, session.scale / 2)
            session.scale = factor
            onScaleCommand?(factor)
            reply("Halved.")
        case .resetScale:
            session.scale = 1
            onScaleCommand?(1)
            reply("Back to the original scale.")
        case .addToList(let listName):
            if let onAddToList {
                let items = ingredients.map { $0.name }.joined(separator: ", ")
                onAddToList(items.isEmpty ? "ingredients" : items, listName)
                if let listName {
                    reply("Added to your \(listName) list.")
                } else {
                    reply("Added to your list.")
                }
            } else {
                if let listName {
                    reply("I can't edit lists from Cook mode yet — add these ingredients to your \(listName) list from the Lists tab.")
                } else {
                    reply("I can't edit lists from Cook mode yet — add these ingredients from the Lists tab.")
                }
            }
        case .startTimer(let seconds, let label):
            let timer: ParsedTimer?
            if let seconds {
                timer = ParsedTimer(seconds: seconds, label: label ?? "Timer")
            } else if session.stepIndex >= 0, session.stepIndex < steps.count {
                timer = parseTimers(from: steps[session.stepIndex]).first
            } else {
                timer = nil
            }
            if let timer {
                let ids = CookActivityStub.schedule(timers: [timer])
                scheduledTimerIds.append(contentsOf: ids)
                onTimerCommand?(timer)
                reply("Timer started for \(timer.label), \(voiceDurationString(timer.seconds)).")
            } else {
                reply("No timer found in this step.")
            }
        case .stopSpeaking:
            stopSpeakingOutput()
            lastReply = "Stopped."
        case .stopCooking:
            audioInput?.stop()
            isListening = false
            // Persist off so a reopen doesn't show a stale "on".
            listeningEnabled = false
            onStopCooking?()
            reply("Done cooking.")
        case .unknown:
            lastReply = "Sorry, I didn't catch that."
            speak(lastReply)
            handled = false
        }
        let replied = (lastReply != replyBefore)
        lastDebugLine = "DEBUG source=\(sourceLabel) speaking=\(speakingAtArrival) echo=\(echoAtArrival) front=\(front) parse=\(parseLabel) replied=\(replied)"
        return handled
    }

    /// Tuple compatibility overload: the CookModeView lane passes
    /// `(id:name)` pairs without quantities. Forwards to the
    /// `VoiceIngredient` implementation (amounts reply name-only).
    @discardableResult
    public func handle(transcript: String,
                       session: CookSession,
                       ingredients: [(id: String, name: String)],
                       steps: [String]) -> Bool {
        handle(transcript: transcript,
               session: session,
               ingredients: ingredients.map { VoiceIngredient(id: $0.id, name: $0.name) },
               steps: steps)
    }

    // MARK: Private

    private var isAppFrontmost: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    private func reply(_ text: String) {
        lastReply = text
        speak(text)
    }

    /// True when the transcript is almost certainly our own speaker: it
    /// matches the last utterance we spoke (normalized for case and
    /// punctuation). Only consulted while TTS is playing. Exact-match is
    /// deliberately conservative — a mixed transcript (echo + real command)
    /// falls through to normal handling, where it usually parses as
    /// `.unknown` ("Sorry, I didn't catch that.") rather than firing a
    /// phantom command.
    private func isEchoOfLastSpoken(_ transcript: String) -> Bool {
        let heard = normalizeEchoText(transcript)
        guard !heard.isEmpty else { return false }
        return heard == normalizeEchoText(lastSpokenText)
    }

    private func partialIsEcho(_ partial: String) -> Bool {
        let p = normalizeEchoText(partial)
        guard !p.isEmpty else { return true }
        let spoken = normalizeEchoText(lastSpokenText)
        guard !spoken.isEmpty else { return false }
        return spoken.contains(p)
    }

    private func normalizeEchoText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Short label for the TEMPORARY TestFlight DEBUG line.
    func debugParseLabel(_ cmd: VoiceCommand) -> String {
        switch cmd {
        case .next: return "next"
        case .previous: return "previous"
        case .repeatStep: return "repeat"
        case .goToStep(let n): return n == VoiceCommand.lastStep ? "goto-last" : "goto\(n)"
        case .startOver: return "startover"
        case .readIngredients: return "ingredients"
        case .ingredientAmount(let n): return "amount:\(n)"
        case .crossOff(let n): return "crossoff:\(n)"
        case .uncross(let n): return "uncross:\(n)"
        case .doubleScale: return "double"
        case .halveScale: return "halve"
        case .resetScale: return "reset"
        case .addToList(let l): return "addtolist:\(l ?? "-")"
        case .startTimer(let s, _): return s.map { "timer\($0)s" } ?? "timer"
        case .stopSpeaking: return "stop-speaking"
        case .stopCooking: return "stop-cooking"
        case .unknown: return "unknown"
        }
    }

    private func voiceDurationString(_ seconds: Int) -> String {
        if seconds >= 3600, seconds % 3600 == 0 {
            let h = seconds / 3600
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        if seconds % 60 == 0 {
            let m = seconds / 60
            return m == 1 ? "1 minute" : "\(m) minutes"
        }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}
