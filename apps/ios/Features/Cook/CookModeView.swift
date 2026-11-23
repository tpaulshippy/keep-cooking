// Smidgen — Lane 4 Cook: CookModeView (SwiftUI)
// Step pager + scaler (0.25x–4x, fraction-rounded) + cross-off + timers.
// iPad-compatible: plain NavigationStack content — embeds in the Lane 2
// PadSplitView detail column; on iPad the pager gets a two-column layout
// via horizontalSizeClass (.regular = ingredients beside steps).

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
    @Environment(\.horizontalSizeClass) private var sizeClass

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

    public var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: ingredients beside the step pager.
                HStack(alignment: .top, spacing: 24) {
                    ingredientList
                        .frame(maxWidth: 320)
                    Divider()
                    stepPager
                }
                .padding()
            } else {
                List {
                    Section("Scaled ingredients") { ingredientList }
                    Section("Steps") { stepPager }
                    Section("Timers") { timerList }
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

    // MARK: - Ingredients (scaled + cross-off)

    private var ingredientList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: $targetServings, in: max(0.25, baseServings * 0.25)...(baseServings * 4),
                    step: baseServings <= 4 ? 0.5 : 1) {
                Text("\(fractionDisplayString(for: targetServings)) servings (\(String(format: "%.2g", factor))×)")
                    .font(.subheadline)
            }
            ForEach(ingredients, id: \.id) { ing in
                Button { session.toggleIngredient(id: ing.id) } label: {
                    HStack {
                        Image(systemName: session.crossedOffIngredients.contains(ing.id)
                            ? "checkmark.circle.fill" : "circle")
                        Text(scaledDisplay(name: ing.name, quantity: ing.quantity,
                                           unit: ing.unit, factor: factor))
                            .strikethrough(session.crossedOffIngredients.contains(ing.id))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Step pager (cross-off)

    private var stepPager: some View {
        VStack(alignment: .leading, spacing: 12) {
            if steps.isEmpty {
                Text("No steps yet.").foregroundStyle(.secondary)
            } else {
                TabView(selection: Binding(
                    get: { session.stepIndex },
                    set: { session.go(to: $0) })) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Step \(idx + 1) of \(steps.count)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(step.text).font(.title3)
                            Button(session.crossedOffSteps.contains(step.id) ? "Unmark step" : "Mark done") {
                                session.toggleStep(id: step.id)
                            }
                            .buttonStyle(.bordered)
                        }
                        .tag(idx)
                        .padding()
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .frame(minHeight: 220)
                HStack {
                    Button("Back") { session.previous() }.disabled(session.stepIndex == 0)
                    Spacer()
                    Button("Next") { session.next() }.disabled(session.stepIndex >= steps.count - 1)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Timers

    private var timerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.timers.isEmpty {
                Text("No timers found in these steps.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(session.timers.enumerated()), id: \.offset) { _, timer in
                    HStack {
                        Image(systemName: "timer")
                        Text(timer.label).font(.headline)
                        Spacer()
                        Text(durationString(timer.seconds)).foregroundStyle(.secondary)
                    }
                }
                Button("Start all timers (background alerts)") {
                    scheduledIds = CookActivityStub.schedule(timers: session.timers)
                }
                .buttonStyle(.borderedProminent)
            }
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
