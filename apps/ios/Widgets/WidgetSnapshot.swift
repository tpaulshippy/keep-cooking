// Smidgen — Lane 5 Organize
// apps/ios/Widgets/WidgetSnapshot.swift
//
// Shared snapshot that powers Widgets + Watch + Shortcuts without touching
// SwiftData outside the main app. The app writes it (see SnapshotWriter in
// SmidgenWidgets.swift); extensions only read. Foundation only so watch,
// widgets, and tests share the exact same decode path.
//
// Storage: App Group `group.com.smidgen.shared`, key `smidgen.snapshot.v1`.
// Extensions never crash on corrupt data — decode failures yield `.empty`.

import Foundation

// MARK: - Snapshot schema (v1)

public struct PlanSnapshotItem: Sendable, Codable, Hashable {
    public var id: String
    public var dateISO: String // YYYY-MM-DD
    public var meal: String
    public var title: String // recipe title, note, or meal fallback
    public init(id: String, dateISO: String, meal: String, title: String) {
        self.id = id; self.dateISO = dateISO; self.meal = meal; self.title = title
    }
}

public struct ListProgressSnapshot: Sendable, Codable, Hashable {
    public var listId: String
    public var name: String
    public var checked: Int
    public var total: Int
    public init(listId: String, name: String, checked: Int, total: Int) {
        self.listId = listId; self.name = name; self.checked = checked; self.total = total
    }
    public var fraction: Double { total > 0 ? Double(checked) / Double(total) : 0 }
}

public struct TodaySnapshot: Sendable, Codable {
    public var plans: [PlanSnapshotItem] // today's plans, meal order
    public var lists: [ListProgressSnapshot] // active lists by progress
    public var updatedAt: Date
    public init(plans: [PlanSnapshotItem] = [], lists: [ListProgressSnapshot] = [], updatedAt: Date = Date()) {
        self.plans = plans; self.lists = lists; self.updatedAt = updatedAt
    }
    public static var empty: TodaySnapshot { TodaySnapshot() }
}

// MARK: - Store

public enum WidgetSnapshotStore {
    public static let suiteName = "group.com.smidgen.shared"
    public static let snapshotKey = "smidgen.snapshot.v1"

    public static func write(_ snapshot: TodaySnapshot, defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        guard let defaults,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    /// Never throws, never crashes: corrupt/missing data yields `.empty`.
    public static func read(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> TodaySnapshot {
        guard let defaults,
              let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(TodaySnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    /// Today's plans in canonical meal order (breakfast→lunch→dinner→snack),
    /// unknown meals last.
    public static func todayPlans(_ snapshot: TodaySnapshot, dayISO: String) -> [PlanSnapshotItem] {
        let order = ["breakfast": 0, "lunch": 1, "dinner": 2, "snack": 3]
        return snapshot.plans.filter { $0.dateISO == dayISO }
            .sorted { (order[$0.meal.lowercased()] ?? 99) < (order[$1.meal.lowercased()] ?? 99) }
    }

    public static func dayISO(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
