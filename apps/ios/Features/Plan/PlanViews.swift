// Smidgen — Lane 4 Plan: day/week/month views + reusable menus + add-week-to-list
// Consumes Core Plan/Menu/ShoppingList/ListItem via snapshots (no new
// persistence, no auth/sync changes). iPad-compatible: NavigationStack
// content that sits in the Lane 2 PadSplitView content column; week/month
// grids expand to full width under .regular size class.

import SwiftUI

// MARK: - Snapshots (store-agnostic; fill from SwiftData @Query at call site)

public struct PlanEntrySnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var date: Date
    public var meal: String
    public var recipeId: String?
    public var recipeTitle: String?
    public var note: String
    public var servings: Double?
    public init(id: String = UUID().uuidString, date: Date, meal: String,
                recipeId: String? = nil, recipeTitle: String? = nil,
                note: String = "", servings: Double? = nil) {
        self.id = id; self.date = date; self.meal = meal
        self.recipeId = recipeId; self.recipeTitle = recipeTitle
        self.note = note; self.servings = servings
    }
}

public struct MenuSnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var entryCount: Int
    public init(id: String, name: String, entryCount: Int) {
        self.id = id; self.name = name; self.entryCount = entryCount
    }
}

public enum PlanSpan: String, Hashable, CaseIterable {
    case day, week, month
}

// MARK: - Plan view

/// Day / week / month planner. `onAddWeekToList` receives the ISO week-start
/// date the user wants aggregated into a shopping list (see PlanAggregation).
public struct PlanView: View {
    private let entries: [PlanEntrySnapshot]
    private let menus: [MenuSnapshot]
    private let feedURL: URL?
    @State private var span: PlanSpan = .week
    @State private var anchor: Date = Date()
    var onAddWeekToList: ((Date) -> Void)?
    var onApplyMenu: ((String, Date) -> Void)? // (menuId, weekStart)

    public init(entries: [PlanEntrySnapshot], menus: [MenuSnapshot] = [], feedURL: URL? = nil,
                onAddWeekToList: ((Date) -> Void)? = nil,
                onApplyMenu: ((String, Date) -> Void)? = nil) {
        self.entries = entries; self.menus = menus; self.feedURL = feedURL
        self.onAddWeekToList = onAddWeekToList; self.onApplyMenu = onApplyMenu
    }

    public var body: some View {
        List {
            Section {
                Picker("Span", selection: $span) {
                    ForEach(PlanSpan.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }
                .pickerStyle(.segmented)
            }
            switch span {
            case .day: daySection(for: anchor)
            case .week: weekSections(weekStart: Self.weekStart(containing: anchor))
            case .month: monthSection(containing: anchor)
            }
            if !menus.isEmpty {
                Section("Reusable menus") {
                    ForEach(menus) { menu in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(menu.name).font(.headline)
                                Text("\(menu.entryCount) entries").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Apply to week") {
                                onApplyMenu?(menu.id, Self.weekStart(containing: anchor))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if let feedURL {
                Section("Calendar") {
                    SubscribeRow(feedURL: feedURL)
                }
            }
        }
        .navigationTitle("Plan")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add week to list") {
                    onAddWeekToList?(Self.weekStart(containing: anchor))
                }
            }
        }
    }

    // MARK: Sections

    private func daySection(for date: Date) -> some View {
        Section(Self.dayTitle(date)) {
            rows(for: Self.days(in: date, count: 1))
        }
    }

    private func weekSections(weekStart: Date) -> some View {
        Section("Week of \(Self.dayTitle(weekStart))") {
            rows(for: Self.days(in: weekStart, count: 7))
        }
    }

    private func monthSection(containing date: Date) -> some View {
        let days = Self.daysInMonth(containing: date)
        return Section(Self.monthTitle(date)) {
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading) {
                    Text(Self.dayTitle(day)).font(.subheadline.bold())
                    rows(for: [day])
                }
            }
        }
    }

    private func rows(for days: [Date]) -> some View {
        ForEach(days, id: \.self) { day in
            let dayEntries = entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            if dayEntries.isEmpty {
                HStack {
                    Text(Self.dayTitle(day)).foregroundStyle(.secondary)
                    Spacer()
                    Text("—").foregroundStyle(.tertiary)
                }
            } else {
                ForEach(dayEntries) { entry in
                    HStack {
                        Text(entry.meal.capitalized).font(.headline)
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(entry.recipeTitle ?? entry.note).foregroundStyle(.secondary)
                            if let s = entry.servings {
                                Text("\(fractionDisplayString(for: s)) servings").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Date helpers

    static func weekStart(containing date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    static func days(in start: Date, count: Int) -> [Date] {
        (0..<count).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    static func daysInMonth(containing date: Date) -> [Date] {
        let cal = Calendar.current
        guard let month = cal.dateInterval(of: .month, for: date) else { return [date] }
        var days: [Date] = []
        var d = month.start
        while d < month.end { days.append(d); d = cal.date(byAdding: .day, value: 1, to: d) ?? month.end }
        return days
    }

    static func dayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month().day())
    }

    static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }
}

// MARK: - webcal subscribe row

/// Opens the webcal:// feed URL so iOS Calendar offers a subscribe sheet.
public struct SubscribeRow: View {
    let feedURL: URL
    @Environment(\.openURL) private var openURL

    public init(feedURL: URL) { self.feedURL = feedURL }

    public var body: some View {
        Button {
            openURL(feedURL)
        } label: {
            Label("Subscribe in Calendar (webcal)", systemImage: "calendar.badge.plus")
        }
    }
}
