// Keep Cooking — Lane 5 Organize
// apps/ios/watch/WatchViews.swift
//
// watchOS companion: today's steps + timers + shopping list. Reads the same
// shared TodaySnapshot as widgets (App Group) plus a lightweight recipe-step
// payload the phone writes for the currently cooking recipe — the watch never
// touches SwiftData or the network directly.
//
// Data contract (App Group `group.com.smidgen.shared`):
//   `smidgen.snapshot.v1`      -> TodaySnapshot (lists + plans; see Widgets)
//   `smidgen.nowcooking.v1`    -> NowCookingPayload (steps + timers, JSON)
// The phone writes NowCookingPayload when Cook mode starts a recipe.

import Foundation
#if canImport(SwiftUI)
import SwiftUI

// MARK: - Now-cooking payload

public struct WatchStepItem: Sendable, Codable, Hashable {
    public var position: Int
    public var text: String
    public var done: Bool
    public init(position: Int, text: String, done: Bool = false) {
        self.position = position; self.text = text; self.done = done
    }
}

public struct WatchTimerItem: Sendable, Codable, Hashable {
    public var label: String
    public var seconds: Int
    public init(label: String, seconds: Int) { self.label = label; self.seconds = seconds }
    public var display: String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

public struct NowCookingPayload: Sendable, Codable {
    public var recipeId: String
    public var title: String
    public var steps: [WatchStepItem]
    public var timers: [WatchTimerItem]
    public var updatedAt: Date
    public init(recipeId: String, title: String, steps: [WatchStepItem] = [],
                timers: [WatchTimerItem] = [], updatedAt: Date = Date()) {
        self.recipeId = recipeId; self.title = title
        self.steps = steps; self.timers = timers; self.updatedAt = updatedAt
    }
}

public enum WatchStore {
    public static let suiteName = "group.com.smidgen.share"
    public static let nowCookingKey = "smidgen.nowcooking.v1"

    /// Never throws: missing/corrupt payload yields nil (views show empty state).
    public static func readNowCooking(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> NowCookingPayload? {
        guard let defaults,
              let data = defaults.data(forKey: nowCookingKey),
              let payload = try? JSONDecoder().decode(NowCookingPayload.self, from: data)
        else { return nil }
        return payload
    }

    public static func writeNowCooking(_ payload: NowCookingPayload,
                                       defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        guard let defaults, let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: nowCookingKey)
    }
}

// MARK: - Watch views

/// Root watch view: Now Cooking steps, timers, today's list progress.
public struct WatchRootView: View {
    public init() {}
    public var body: some View {
        TabView {
            WatchStepsView()
                .tabItem { Label("Steps", systemImage: "list.number") }
            WatchTimersView()
                .tabItem { Label("Timers", systemImage: "timer") }
            WatchListView()
                .tabItem { Label("List", systemImage: "cart") }
        }
    }
}

public struct WatchStepsView: View {
    @State private var payload: NowCookingPayload?
    @State private var doneIds = Set<Int>()

    public init() {}

    public var body: some View {
        List {
            if let payload, !payload.steps.isEmpty {
                Section(payload.title) {
                    ForEach(payload.steps.sorted { $0.position < $1.position }, id: \.position) { step in
                        Button {
                            if doneIds.contains(step.position) { doneIds.remove(step.position) }
                            else { doneIds.insert(step.position) }
                        } label: {
                            HStack {
                                Image(systemName: doneIds.contains(step.position) ? "checkmark.circle.fill" : "circle")
                                Text(step.text).strikethrough(doneIds.contains(step.position))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ContentUnavailableView("No recipe", systemImage: "frying.pan",
                    description: Text("Start cooking on iPhone to see steps here."))
            }
        }
        .navigationTitle("Steps")
        .onAppear { payload = WatchStore.readNowCooking() }
    }
}

public struct WatchTimersView: View {
    @State private var payload: NowCookingPayload?
    @State private var remaining: [String: Int] = [:]
    @State private var running: Set<String> = []

    public init() {}

    public var body: some View {
        List {
            let timers = payload?.timers ?? []
            if timers.isEmpty {
                ContentUnavailableView("No timers", systemImage: "timer",
                    description: Text("Timers from Cook mode appear here."))
            } else {
                ForEach(timers, id: \.label) { timer in
                    let left = remaining[timer.label] ?? timer.seconds
                    HStack {
                        VStack(alignment: .leading) {
                            Text(timer.label).font(.headline)
                            Text(Self.format(left)).font(.system(.title2, design: .monospaced))
                        }
                        Spacer()
                        Button(running.contains(timer.label) ? "Stop" : "Start") {
                            if running.contains(timer.label) {
                                running.remove(timer.label)
                            } else {
                                remaining[timer.label] = remaining[timer.label] ?? timer.seconds
                                running.insert(timer.label)
                                tick(label: timer.label)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("Timers")
        .onAppear { payload = WatchStore.readNowCooking() }
    }

    /// Simple countdown using detached concurrency — no wall-clock drift
    /// correction needed at watch granularity; stopping cancels via `running`.
    private func tick(label: String) {
        Task {
            while running.contains(label), (remaining[label] ?? 0) > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    if running.contains(label) {
                        remaining[label] = max(0, (remaining[label] ?? 0) - 1)
                        if remaining[label] == 0 { running.remove(label) }
                    }
                }
            }
        }
    }

    private static func format(_ total: Int) -> String {
        String(format: "%d:%02d", total / 60, total % 60)
    }
}

public struct WatchListView: View {
    @State private var snapshot: TodaySnapshot = .empty

    public init() {}

    public var body: some View {
        List {
            if snapshot.lists.isEmpty {
                ContentUnavailableView("No lists", systemImage: "cart",
                    description: Text("Shopping lists sync from iPhone."))
            } else {
                ForEach(snapshot.lists, id: \.listId) { list in
                    VStack(alignment: .leading) {
                        Text(list.name).font(.headline)
                        ProgressView(value: list.fraction)
                        Text("\(list.checked) of \(list.total) done")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Lists")
        .onAppear { snapshot = WidgetSnapshotStore.read() }
    }
}
#endif
