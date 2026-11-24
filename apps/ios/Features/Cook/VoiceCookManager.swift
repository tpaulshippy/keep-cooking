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

    public init?(locale: Locale = .current) {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        #endif
    }

    public func start(onTranscript: @escaping (String) -> Void) {
        stop()
        #if os(iOS)
        configureAudioSession()
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        // Prefer on-device recognition when the recognizer supports it.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        task = recognizer.recognitionTask(with: request) { result, _ in
            guard let result, result.isFinal else { return }
            onTranscript(result.bestTranscription.formattedString)
        }
        do {
            try engine.start()
            isRunning = true
        } catch {
            stop()
        }
    }

    public func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRunning = false
        #if os(iOS)
        deactivateAudioSession()
        #endif
    }

    #if os(iOS)
    /// Play-and-record so read-aloud ducks under listening; activated before
    /// `engine.start()` so the engine never starts on a cold session.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: .duckOthers)
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
        completion(granted)
    }

    // MARK: Speech output

    /// Speaks text, optionally in the recipe locale.
    public func speak(_ text: String, locale: Locale? = nil) {
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
    /// nil the manager uses on-device recognition, falling back to the mock
    /// (and setting `micDenied`) when the mic is unavailable.
    /// `isListening` honestly reflects `audioInput?.isRunning` after the
    /// start attempt; on failure it stays false with a retry prompt in
    /// `lastReply`.
    public func startListening(using input: VoiceAudioInput? = nil,
                               onTranscript: @escaping (String) -> Void) {
        guard listeningEnabled else { return }
        if let input {
            audioInput = input
        } else if let live = LiveVoiceInput() {
            audioInput = live
        } else {
            micDenied = true
            audioInput = MockVoiceInput()
        }
        audioInput?.start(onTranscript: onTranscript)
        let running = audioInput?.isRunning ?? false
        isListening = running
        if !running {
            lastReply = "I couldn't start listening. Check the microphone and try again."
            speak(lastReply)
        }
    }

    public func stopListening() {
        audioInput?.stop()
        isListening = false
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
                } else if fuzzyVoiceMatch(name, candidates: ingredients.map { $0.name }) != nil {
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
        guard isAppFrontmost else { return false }
        let tuples = ingredients.map { (id: $0.id, name: $0.name) }
        switch parseVoiceCommand(transcript) {
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
            } else if fuzzyVoiceMatch(name, candidates: ingredients.map { $0.name }) != nil {
                reply("Which \(name)? I see more than one matching ingredient.")
            } else {
                reply("I don't see \(name) in the ingredients.")
            }
        case .crossOff(let name):
            if let id = ingredientId(matching: name, in: tuples) {
                session.crossedOffIngredients.insert(id)
                reply("Crossed off \(name).")
            } else if fuzzyVoiceMatch(name, candidates: ingredients.map { $0.name }) != nil {
                reply("Which \(name)? I see more than one matching ingredient.")
            } else {
                reply("I don't see \(name) in the ingredients.")
            }
        case .uncross(let name):
            if let id = ingredientId(matching: name, in: tuples) {
                session.crossedOffIngredients.remove(id)
                reply("Put back \(name).")
            } else if fuzzyVoiceMatch(name, candidates: ingredients.map { $0.name }) != nil {
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
                CookActivityStub.schedule(timers: [timer])
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
            return false
        }
        return true
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
