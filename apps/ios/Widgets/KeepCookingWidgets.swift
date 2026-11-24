// Keep Cooking — Lane 5 Organize
// apps/ios/Widgets/KeepCookingWidgets.swift
//
// WidgetKit: Today Plan widget (today's meals) + List Progress widget
// (shopping-list completion). Both read the shared TodaySnapshot written by
// the main app — widgets never touch SwiftData or the network.
//
// SnapshotWriter.refresh() is called by the app (background refresh + after
// plan/list edits). Target membership: main app only for the writer; the
// timeline providers below belong to the widget extension target.

import Foundation
#if canImport(WidgetKit)
import WidgetKit
import SwiftUI

// MARK: - Timeline plumbing

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: TodaySnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in _: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }
    func getSnapshot(in _: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.read()))
    }
    func getTimeline(in _: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.read())
        // Re-read hourly; the app also calls reloadTimelines after edits.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Today Plan widget

struct TodayPlanWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.smidgen.todayPlan", provider: SnapshotProvider()) { entry in
            TodayPlanView(entry: entry)
        }
        .configurationDisplayName("Today's Plan")
        .description("Meals planned for today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayPlanView: View {
    let entry: SnapshotEntry
    var body: some View {
        let plans = WidgetSnapshotStore.todayPlans(entry.snapshot, dayISO: WidgetSnapshotStore.dayISO(entry.date))
        VStack(alignment: .leading, spacing: 4) {
            Text("Today").font(.caption).foregroundStyle(.secondary)
            if plans.isEmpty {
                Text("No meals planned").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(plans.prefix(3)), id: \.id) { item in
                    HStack {
                        Text(item.meal.capitalized).font(.caption).foregroundStyle(.secondary)
                        Text(item.title).font(.callout).lineLimit(1)
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - List Progress widget

struct ListProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.smidgen.listProgress", provider: SnapshotProvider()) { entry in
            ListProgressView(entry: entry)
        }
        .configurationDisplayName("List Progress")
        .description("Shopping-list completion.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ListProgressView: View {
    let entry: SnapshotEntry
    var body: some View {
        let lists = entry.snapshot.lists.prefix(2)
        VStack(alignment: .leading, spacing: 6) {
            Text("Lists").font(.caption).foregroundStyle(.secondary)
            if lists.isEmpty {
                Text("No active lists").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(lists), id: \.listId) { list in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(list.name).font(.callout).lineLimit(1)
                            Spacer()
                            Text("\(list.checked)/\(list.total)").font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: list.fraction)
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Previews (also the source of truth for PREVIEW_NOTES screenshots)

extension TodaySnapshot {
    static var preview: TodaySnapshot {
        TodaySnapshot(
            plans: [
                PlanSnapshotItem(id: "p1", dateISO: WidgetSnapshotStore.dayISO(), meal: "breakfast", title: "Blueberry Pancakes"),
                PlanSnapshotItem(id: "p2", dateISO: WidgetSnapshotStore.dayISO(), meal: "dinner", title: "Weeknight Miso Salmon"),
            ],
            lists: [ListProgressSnapshot(listId: "l1", name: "Weekly shop", checked: 7, total: 12)]
        )
    }
}

#endif

// MARK: - SnapshotWriter (main-app target; SwiftData -> shared snapshot)

#if canImport(SwiftData)
import SwiftData

/// Main-app helper: rebuilds the shared snapshot from SwiftData after plan
/// or list edits and asks WidgetKit to reload. No network, main-actor
/// confined like the rest of Lane 2's SyncCoordinator.
@MainActor
public enum SnapshotWriter {
    public static func refresh(context: ModelContext) {
        let dayISO = WidgetSnapshotStore.dayISO()
        var planItems: [PlanSnapshotItem] = []
        if let plans = try? context.fetch(FetchDescriptor<Plan>()) {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .iso8601)
            f.dateFormat = "yyyy-MM-dd"
            for p in plans where !p.deleted {
                let iso = f.string(from: p.date)
                guard iso == dayISO else { continue }
                let title: String
                if let rid = p.recipeId,
                   let match: Recipe = try? context.fetch(
                       FetchDescriptor<Recipe>(predicate: #Predicate { $0.id == rid })).first
                {
                    title = match.title
                } else if !p.note.isEmpty {
                    title = p.note
                } else {
                    title = p.mealRaw.capitalized
                }
                planItems.append(PlanSnapshotItem(id: p.id, dateISO: iso, meal: p.mealRaw, title: title))
            }
        }
        var listItems: [ListProgressSnapshot] = []
        if let lists = try? context.fetch(FetchDescriptor<ShoppingList>()) {
            for l in lists where !l.deleted {
                let live = l.items.filter { !$0.deleted }
                listItems.append(ListProgressSnapshot(
                    listId: l.id, name: l.name,
                    checked: live.filter { $0.checked }.count, total: live.count))
            }
        }
        WidgetSnapshotStore.write(TodaySnapshot(plans: planItems, lists: listItems))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

@main
struct KeepCookingWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayPlanWidget()
        ListProgressWidget()
    }
}
#endif
