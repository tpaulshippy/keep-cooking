// Smidgen — Lane 4 Cook: CookModeView (SwiftUI)
// Hands-free overhaul: full-screen step pager + progress, sticky servings
// scaler, large-type steps, 44pt targets, ingredient checklist, timers with
// Start, visible keep-awake pill. iPad (.regular) keeps 2-column layout.

import SwiftUI

/// Cook mode for one recipe. Caller passes live SwiftData values as plain
/// snapshots so this view stays store-agnostic (works with @Query or previews).
public struct CookModeView: View {
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

    public init(title: String, baseServings: Double,
                ingredients: [IngredientSnapshot], steps: [StepSnapshot]) {
        self.title = title
        self.baseServings = baseServings
        self.ingredients = ingredients
        self.steps = steps.sorted(by: { $0.position < $1.position })
        _session = State(initialValue: CookSession(stepCount: max(1, steps.count)))
        _targetServings = State(initialValue: baseServings)
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
        }
        .onDisappear {
            KeepAwake.disable()
            CookActivityStub.cancel(ids: scheduledIds)
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
                // Dots double as large jump targets.
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
                    // Last step: mark done instead of dead-ending.
                    if let last = steps.last { session.toggleStep(id: last.id) }
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
                        .accessibilityLabel("\(ing.name), \(done ? "gathered" : "not gathered")")
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
