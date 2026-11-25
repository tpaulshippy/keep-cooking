// Keep Cooking — Lane 4 Cook: CookModeView (SwiftUI)
// Hands-free overhaul: full-screen step pager + progress, sticky servings
// scaler, large-type steps, 44pt targets, ingredient checklist, timers with
// Start, visible keep-awake pill. iPad (.regular) keeps 2-column layout.

import SwiftUI
import UIKit
import Foundation

/// Cook mode for one recipe. Caller passes live SwiftData values as plain
/// snapshots so this view stays store-agnostic (works with @Query or previews).
public struct CookModeView: View {
    /// Set while a session is on screen (appear/disappear); nav intents
    /// require it so they never claim a step change when no live session
    /// can consume the handoff. Single source of truth — CookModeView and
    /// KeepCookingIntents both read this, never a string-literal copy
    /// (same pattern as VoiceCookManager.pendingCommandKey).
    public static let sessionActiveKey = "cook.sessionActive"

    public struct IngredientSnapshot: Hashable, Sendable {
        public var id: String
        public var name: String
        public var quantity: Double?
        public var unit: String
        public init(id: String, name: String, quantity: Double?, unit: String) {
            self.id = id; self.name = name; self.quantity = quantity; self.unit = unit
        }
    }

    public struct StepSnapshot: Hashable, Sendable {
        public var id: String
        public var position: Int
        public var text: String
        public init(id: String, position: Int, text: String) {
            self.id = id; self.position = position; self.text = text
        }
    }

    private let title: String
    private let baseServings: Double
    private let ingredients: [IngredientSnapshot]
    private let steps: [StepSnapshot]
    @State private var session: CookSession
    @State private var scheduledIds: [String] = []
    @State private var targetServings: Double
    @State private var ingredientsExpanded = true
    @Environment(\.horizontalSizeClass) private var sizeClass
    // Reconciled: VoiceCookManager owns read-aloud + listening state
    // (same UserDefaults keys: cook.readAloudEnabled default true,
    // cook.listeningEnabled default false).
    @State private var voiceManager = VoiceCookManager()
    #if targetEnvironment(simulator)
    @State private var simVoiceText = ""
    #endif

    public init(title: String, baseServings: Double,
                ingredients: [IngredientSnapshot], steps: [StepSnapshot],
                initialServings: Double? = nil) {
        self.title = title
        self.baseServings = baseServings
        self.ingredients = ingredients
        self.steps = steps.sorted(by: { $0.position < $1.position })
        _session = State(initialValue: CookSession(stepCount: max(1, steps.count)))
        _targetServings = State(initialValue: initialServings ?? baseServings)
    }

    private var factor: Double { scaleFactor(baseServings: baseServings, targetServings: targetServings) }
    private var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(session.stepIndex + 1) / Double(steps.count)
    }

    public var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: ingredients + timers beside the full-height step pager.
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            servingsCard
                            ingredientsCard
                            timersCard
                            keepAwakePill
                            Spacer(minLength: 24)
                        }
                        .padding()
                    }
                    .frame(maxWidth: 360)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            progressHeader
                            stepPagerFull
                            stepNavBar
                        }
                        .padding(24)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        progressHeader
                        stepPagerFull
                        stepNavBar
                        ingredientsCard
                        timersCard
                        keepAwakePill
                        // Clearance for the pill tab bar.
                        Spacer(minLength: 72)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    servingsHeaderSticky
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Text(title).font(.headline) }
        }
        .onAppear {
            KeepAwake.enable()
            session.loadTimers(from: steps.map { $0.text })
            // Mark the session active so Shortcuts nav intents accept
            // handoffs while Cook mode can consume them (cleared below).
            UserDefaults.standard.set(true, forKey: Self.sessionActiveKey)
            // Sync voice scale from any restored servings before wiring.
            session.scale = factor
            // Wire voice callbacks (idempotent per appearance).
            wireVoiceCallbacks()
            // Consume any Shortcuts/intent handoff written while away.
            // Shared key "cook.pendingCommand" (next/previous/repeat/
            // crossoff:<name>/gotostep:<n>). Manager owns parsing + clearing;
            // the view only maps its store-agnostic snapshots.
            _ = voiceManager.consumePendingCommand(session: session, ingredients: voiceIngredients, steps: steps.map { $0.text })
            // Resume listening when the persisted flag is on. The manager
            // persists cook.listeningEnabled; permission-then-start avoids
            // starting the engine before mic access resolves.
            if voiceManager.listeningEnabled {
                beginListening()
            }
            // VoiceCookManager owns speak on appear (interrupting read).
            speakCurrentStep()
        }
        .onDisappear {
            KeepAwake.disable()
            UserDefaults.standard.set(false, forKey: Self.sessionActiveKey)
            // Cancel both view-started timers and voice-started ones (the
            // manager retains those ids in `scheduledTimerIds`).
            CookActivityStub.cancel(ids: scheduledIds + voiceManager.scheduledTimerIds)
            // Manager's stopListening also persists listeningEnabled off,
            // fixing the stale-flag bug (was: stopped input, left flag true).
            voiceManager.stopListening()
        }
        .onChange(of: session.stepIndex) {
            // Re-read on every step change (pager swipe, dots, Back/Next/Finish).
            // speakCurrentStep interrupts first so rapid swipes never pile up.
            speakCurrentStep()
        }
        .onChange(of: targetServings) {
            // Manual stepper -> session sync (voice -> servings flows through
            // onScaleCommand). Without this, "double it" after a manual
            // change computes from a stale `session.scale`.
            session.scale = factor
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            voiceBottomBar
        }
    }

    // MARK: - Sticky servings scaler header

    private var servingsHeaderSticky: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fractionDisplayString(for: targetServings)) servings")
                        .font(.headline)
                    Text("Scaled \(String(format: "%.2g", factor))× · base \(fractionDisplayString(for: baseServings))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("", value: $targetServings,
                        in: max(0.25, baseServings * 0.25)...(baseServings * 4),
                        step: baseServings <= 4 ? 0.5 : 1)
                .frame(minHeight: 44)
                .accessibilityLabel("Adjust servings")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
        }
    }

    /// Same scaler as a card (iPad column + compact fallback).
    private var servingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Servings")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Stepper(value: $targetServings,
                    in: max(0.25, baseServings * 0.25)...(baseServings * 4),
                    step: baseServings <= 4 ? 0.5 : 1) {
                Text("\(fractionDisplayString(for: targetServings)) servings (\(String(format: "%.2g", factor))×)")
                    .font(.headline)
            }
            .frame(minHeight: 44)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Progress (Step X of N + bar + dots)

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if steps.isEmpty {
                Text("No steps yet.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Step \(session.stepIndex + 1) of \(steps.count)")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(round(progress * 100)))%")
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(minHeight: 8)
                    .accessibilityLabel("Cooking progress \(Int(round(progress * 100))) percent")
                // Dots double as large jump targets; scrolls when the
                // recipe has more steps than fit on screen.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(steps.indices, id: \.self) { idx in
                            Button { session.go(to: idx) } label: {
                                Capsule()
                                    .fill(idx == session.stepIndex ? Color.accentColor
                                          : (crossed(idx) ? Color.green.opacity(0.7) : Color.secondary.opacity(0.3)))
                                    .frame(width: idx == session.stepIndex ? 28 : 16, height: 8)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Go to step \(idx + 1)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func crossed(_ idx: Int) -> Bool {
        guard steps.indices.contains(idx) else { return false }
        return session.crossedOffSteps.contains(steps[idx].id)
    }

    // MARK: - Full-screen step pager

    private var stepPagerFull: some View {
        Group {
            if steps.isEmpty {
                ContentUnavailableView("No steps yet",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text("Steps added to this recipe will appear here, one big card at a time."))
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                TabView(selection: Binding(
                    get: { session.stepIndex },
                    set: { session.go(to: $0) })) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Step \(idx + 1)")
                                .font(.caption).bold()
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(step.text)
                                .font(.title2)
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Button(session.crossedOffSteps.contains(step.id) ? "✓ Done — tap to unmark" : "Mark done") {
                                session.toggleStep(id: step.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(minHeight: 44)
                            .tint(session.crossedOffSteps.contains(step.id) ? .green : .accentColor)
                        }
                        .tag(idx)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 2)
                        .opacity(session.crossedOffSteps.contains(step.id) ? 0.75 : 1)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(minHeight: 340)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Recipe steps pager")
            }
        }
    }

    private var stepNavBar: some View {
        HStack(spacing: 12) {
            Button {
                session.previous()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .disabled(session.stepIndex == 0 || steps.isEmpty)
            Button {
                if session.stepIndex >= steps.count - 1 {
                    // Last step: idempotently mark done (repeat taps must
                    // not unmark); the card control is the unmark action.
                    if let last = steps.last { session.markStepDone(id: last.id) }
                } else {
                    session.next()
                }
            } label: {
                Label(session.stepIndex >= steps.count - 1 ? "Finish" : "Next",
                      systemImage: session.stepIndex >= steps.count - 1 ? "checkmark" : "chevron.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(steps.isEmpty)
        }
    }

    // MARK: - Ingredients (large checklist, collapsible)

    private var ingredientsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup(isExpanded: $ingredientsExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    let done = ingredients.filter { session.crossedOffIngredients.contains($0.id) }.count
                    if !ingredients.isEmpty {
                        Text("\(done) of \(ingredients.count) gathered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                    ForEach(ingredients, id: \.id) { ing in
                        let done = session.crossedOffIngredients.contains(ing.id)
                        Button { session.toggleIngredient(id: ing.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(done ? .green : .secondary)
                                    .frame(width: 28, height: 28)
                                Text(scaledDisplay(name: ing.name, quantity: ing.quantity,
                                                   unit: ing.unit, factor: factor))
                                    .font(.body)
                                    .strikethrough(done)
                                    .foregroundStyle(done ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityLabel("\(scaledDisplay(name: ing.name, quantity: ing.quantity, unit: ing.unit, factor: factor)), \(done ? "gathered" : "not gathered")")
                        if ing.id != ingredients.last?.id { Divider() }
                    }
                    if ingredients.isEmpty {
                        Text("No ingredients listed.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
            } label: {
                HStack {
                    Text("Ingredients")
                        .font(.headline)
                    Spacer()
                    Text("\(fractionDisplayString(for: targetServings)) servings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Timers (Start via CookActivityStub, friendly empty state)

    private var timerList: some View { timersCard }

    private var timersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Timers", systemImage: "timer")
                    .font(.headline)
                Spacer()
                if !session.timers.isEmpty {
                    Text("\(session.timers.count)")
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            if session.timers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "timer")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No timers in these steps")
                            .font(.subheadline).bold()
                        Text("Cook at your own pace — when a step mentions minutes, its timer will appear here with a Start button.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(Array(session.timers.enumerated()), id: \.offset) { idx, timer in
                    HStack(spacing: 12) {
                        Image(systemName: "timer")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(timer.label)
                                .font(.headline)
                                .lineLimit(2)
                            Text(durationString(timer.seconds))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Start") {
                            let ids = CookActivityStub.schedule(timers: [timer])
                            scheduledIds.append(contentsOf: ids)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .frame(minWidth: 72, minHeight: 44)
                        .accessibilityLabel("Start timer \(idx + 1): \(timer.label)")
                    }
                    .padding(.vertical, 4)
                    if idx < session.timers.count - 1 { Divider() }
                }
                Button {
                    scheduledIds = CookActivityStub.schedule(timers: session.timers)
                } label: {
                    Label("Start all timers", systemImage: "bell.badge")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Schedules background alerts for every timer in this recipe")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Keep-awake pill (visible)

    private var keepAwakePill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)
            Image(systemName: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Screen stays awake while you cook")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Screen stays awake while cooking")
    }

    // MARK: - Voice bottom bar (Paprika parity pill + reply + mic-denied)

    #if targetEnvironment(simulator)
    /// Simulator-only voice harness: the sim has no mic or recognizer, so
    /// this field injects typed transcripts through the same MockVoiceInput
    /// + `handle` path the device uses (replies, scale sync, timers). Never
    /// compiled into device builds.
    private var simVoiceDebugBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulated voice input")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                TextField("Type a command, e.g. next", text: $simVoiceText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44)
                    .accessibilityLabel("Simulated voice command")
                Button("Send") {
                    let command = simVoiceText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !command.isEmpty else { return }
                    simVoiceText = ""
                    voiceManager.emitSimulatedTranscript(command)
                }
                .buttonStyle(.borderedProminent)
                .disabled(simVoiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(minHeight: 44)
                .accessibilityHint("Injects the typed command into the voice pipeline")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    #endif

    // Bound to VoiceCookManager: pill toggles drive the manager, reply text
    // and mic-denied state observe it.
    private var voiceBottomBar: some View {
        VStack(spacing: 8) {
            if voiceManager.listeningError != nil {
                voiceErrorView
            }
            if !voiceManager.lastHeardTranscript.isEmpty {
                voiceHeardView
            }
            if !voiceManager.lastReply.isEmpty {
                voiceReplyView
            }
            if voiceManager.micDenied {
                micDeniedPlacard
            }
            #if targetEnvironment(simulator)
            simVoiceDebugBar
            #endif
            stepPillBar
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    /// What the recognizer last delivered, so the cook can distinguish
    /// "heard but not understood" from "not hearing". Shown above the reply.
    /// Updates live as partial words arrive, settling on the final.
    private var voiceHeardView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Heard: “\(voiceManager.lastHeardTranscript)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Heard: \(voiceManager.lastHeardTranscript)")
            if !voiceManager.lastDebugLine.isEmpty {
                Text(voiceManager.lastDebugLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Recognition failure, if any (no network, recognizer busy, ...).
    /// Red so it reads as an error, not a reply.
    private var voiceErrorView: some View {
        Text(voiceManager.listeningError ?? "")
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityLabel("Voice error: \(voiceManager.listeningError ?? "")")
    }

    /// Reply area directly above the pill: last spoken/heard reply.
    private var voiceReplyView: some View {
        Text(voiceManager.lastReply)
            .font(.body)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Voice reply: \(voiceManager.lastReply)")
    }

    /// Shown when listening was requested but mic access was denied.
    private var micDeniedPlacard: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Microphone off — enable in Settings")
                .font(.subheadline).bold()
                .multilineTextAlignment(.leading)
            Spacer()
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Microphone off — enable in Settings")
    }

    /// Paprika-style bottom pill: Step X of N + read-aloud + listening toggles.
    private var stepPillBar: some View {
        HStack(spacing: 8) {
            Text(steps.isEmpty ? "No steps" : "Step \(session.stepIndex + 1) of \(steps.count)")
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel(steps.isEmpty ? "No steps" : "Step \(session.stepIndex + 1) of \(steps.count)")
            Spacer()
            // Read-aloud toggle (speaker icon).
            Button {
                voiceManager.readAloudEnabled.toggle()
                if voiceManager.readAloudEnabled {
                    speakCurrentStep()
                } else {
                    // Read-aloud OFF must silence in-flight TTS immediately.
                    voiceManager.stopSpeakingOutput()
                }
            } label: {
                Image(systemName: voiceManager.readAloudEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voiceManager.readAloudEnabled ? "Read aloud on" : "Read aloud off")
            .accessibilityHint("Toggles spoken step replies")
            // Listening toggle (mic icon + live dot). `listeningEnabled` is the
            // persisted intent; `isListening` is the live engine state —
            // the dot tracks the engine so a dead recognizer can't show a
            // green "listening" that hears nothing.
            Button {
                toggleListening()
            } label: {
                HStack(spacing: 6) {
                    if voiceManager.isListening {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: voiceManager.listeningEnabled ? "mic.fill" : "mic.slash.fill")
                        .font(.title3)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voiceManager.isListening ? "Listening on" : (voiceManager.listeningEnabled ? "Starting listening" : "Listening off"))
            .accessibilityHint("Toggles voice commands")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
    }

    private func speakCurrentStep() {
        #if os(iOS)
        // Interrupting read stops any in-flight utterance first so rapid
        // step changes never pile up. (Manager lane provides the combined
        // call; fallback would be stopSpeakingOutput() + readCurrentStep.)
        voiceManager.readCurrentStepInterrupting(steps: steps.map { $0.text }, session: session, locale: Locale.current)
        #endif
    }

    /// Store-agnostic snapshots mapped to the manager's voice contract.
    private var voiceIngredients: [VoiceIngredient] {
        ingredients.map { VoiceIngredient(id: $0.id, name: $0.name, quantity: $0.quantity, unit: $0.unit) }
    }

    /// Wires manager callbacks. Only scale drives view state; the rest are
    /// intentionally observed via `lastReply` (see comments below).
    private func wireVoiceCallbacks() {
        // Scale voice commands ("double it") drive the sticky servings
        // stepper. Capture the Binding — not self — so the escaping
        // callback can write through (View is a struct).
        let servingsBinding = $targetServings
        let base = baseServings
        voiceManager.onScaleCommand = { factor in
            let lower = max(0.25, base * 0.25)
            let upper = base * 4
            servingsBinding.wrappedValue = min(max(base * factor, lower), upper)
        }
        // onTimerCommand: intentionally unwired. The timer is scheduled by
        // the manager, which retains its notification ids in
        // `scheduledTimerIds`; onDisappear cancels those alongside this
        // view's `scheduledIds` (no double-scheduling, no leaked alerts).
        // Its reply is already set on lastReply and shown in the pill.
        // onStopCooking: intentionally no navigation. This view is
        // store-agnostic with no router; popping mid-cook would strand
        // timers/keep-awake state. The manager's "Done cooking." reply is
        // shown in the pill and the user exits via the normal back button.
        // onAddToList: intentionally unwired. This view only holds snapshot
        // structs (no SwiftData context), so it cannot insert ListItems. The
        // manager gives the honest spoken + pill reply ("Added to your …").
    }

    /// Permission-then-start entry point (shared by toggle-ON + onAppear resume).
    /// Never starts the engine synchronously after requesting — the start
    /// happens inside the permission completion. On the simulator there are
    /// no mic/speech permissions and the mock input needs none, so the
    /// permission gate is skipped there.
    private func beginListening() {
        #if targetEnvironment(simulator)
        voiceManager.startListening { transcript in
            _ = voiceManager.handle(
                transcript: transcript,
                session: session,
                ingredients: voiceIngredients,
                steps: steps.map { $0.text }
            )
        }
        #else
        voiceManager.requestPermissionsThenStart { [voiceManager, session] in
            voiceManager.startListening { transcript in
                _ = voiceManager.handle(
                    transcript: transcript,
                    session: session,
                    ingredients: voiceIngredients,
                    steps: steps.map { $0.text }
                )
            }
        }
        #endif
    }

    private func toggleListening() {
        if voiceManager.listeningEnabled {
            voiceManager.listeningEnabled = false
            voiceManager.stopListening()
        } else {
            voiceManager.listeningEnabled = true
            beginListening()
        }
    }

    private func durationString(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600, m = (seconds % 3600) / 60
            return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
        } else if seconds >= 60 {
            return "\(seconds / 60) min"
        }
        return "\(seconds) sec"
    }
}
