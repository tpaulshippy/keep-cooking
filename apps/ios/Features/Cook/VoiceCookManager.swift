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
        stopEngineAndTask()
        #if os(iOS)
        deactivateAudioSession()
        #endif
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
        // On-device first for privacy + offline use; server fallback happens
        // in the task-error handler below when the on-device attempt fails
        // (missing offline model, unsupported language, ...). Forcing
        // on-device unconditionally fails silently with zero transcripts
        // when the model isn't downloaded, so it must never be required.
        request.requiresOnDeviceRecognition = preferOnDevice
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, myGeneration == self.generation else { return }
            if let error {
                guard self.shouldKeepListening else { return }
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
            guard let result else { return }
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if result.isFinal {
                if text != self.lastForwarded {
                    self.lastForwarded = text
                    self.lastPartialForwarded = text
                    DispatchQueue.main.async { [weak self] in
                        self?.onTranscript?(text)
                    }
                }
                // Apple finishes the task after a final — restart so the
                // NEXT command is heard.
                self.scheduleRestart(after: 0.25, generation: myGeneration)
            } else if text != self.lastPartialForwarded {
                // Live display only: partials update the Heard caption so
                // the cook sees audio flowing before pausing for the final.
                // Never routed to command handling (partials like "nex"
                // would spam "didn't catch that").
                self.lastPartialForwarded = text
                DispatchQueue.main.async { [weak self] in
                    self?.onPartial?(text)
                }
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
        audioInput?.start(onTranscript: { [weak self] transcript in
            guard let self else { return }
            // Snapshot arrival state BEFORE barge-in handling for the
            // temporary DEBUG line (stopSpeakingOutput clears isSpeaking).
            let wasSpeaking = self.synthesizer.isSpeaking
            let echo = self.isEchoOfLastSpoken(transcript)
            self.lastArrivalWasSpeaking = wasSpeaking
            self.lastArrivalEcho = echo
            self.lastArrivalTranscript = transcript
            if wasSpeaking {
                // Barge-in path: with hardware echo cancellation (voiceChat
                // mode) the mic stays live while replies play. Our own audio
                // is still the likeliest transcript — drop it when it matches
                // what we just spoke; otherwise stop talking and obey the
                // cook ("repeat" / "stop speaking" over a read-aloud).
                if echo {
                    self.lastDebugLine = "DEBUG final=true speaking=true echo=true front=\(self.isAppFrontmost) parse=\(self.debugParseLabel(parseVoiceCommand(transcript))) replied=false"
                    return
                }
                self.stopSpeakingOutput()
            }
            // Record what was heard BEFORE handling, so the pill can show
            // the words even when the command itself is unknown. A fresh
            // transcript also means recovery: drop any earlier error.
            self.lastHeardTranscript = transcript
            self.listeningError = nil
            // Preliminary line; `handle` overwrites with parse + replied.
            self.lastDebugLine = "DEBUG final=true speaking=\(wasSpeaking) echo=\(echo) front=\(self.isAppFrontmost) parse=... replied=..."
            onTranscript(transcript)
        })
        if let live = audioInput as? LiveVoiceInput {
            live.onPartial = { [weak self] text in
                guard let self else { return }
                if self.synthesizer.isSpeaking {
                    // Barge-in: finals need silence to fire, and our own
                    // read-aloud denies it — so the first real user speech
                    // over our audio stops TTS, creating the silence the
                    // final needs. Our own echo (a partial contained in
                    // what we're speaking) is ignored so read-aloud can't
                    // cut itself off.
                    if self.partialIsEcho(text) { return }
                    self.stopSpeakingOutput()
                }
                self.lastHeardTranscript = text
            }
            live.onError = { [weak self] message in
                guard let self else { return }
                // The retry loop re-reports persistent failures; only
                // publish changes so the pill doesn't churn.
                if self.listeningError != message {
                    self.listeningError = message
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
        }
    }

    /// Tears down listening AND clears the persisted `listeningEnabled` flag,
    /// so a late permission completion (see `requestPermissionsThenStart`)
    /// can never start the mic after the view has disappeared:
    /// `startListening` guards on the flag, and the pending completion is
    /// cancelled here. CookModeView.onDisappear relies on this (it must not
    /// leave a stale "on").
    public func stopListening() {
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
        guard front else {
            lastDebugLine = "DEBUG final=true speaking=\(speakingAtArrival) echo=\(echoAtArrival) front=false parse=\(parseLabel) replied=false"
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
        lastDebugLine = "DEBUG final=true speaking=\(speakingAtArrival) echo=\(echoAtArrival) front=\(front) parse=\(parseLabel) replied=\(replied)"
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
