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
    var onAddDay: ((Date) -> Void)? // empty-day "Add" affordance target

    public init(entries: [PlanEntrySnapshot], menus: [MenuSnapshot] = [], feedURL: URL? = nil,
                onAddWeekToList: ((Date) -> Void)? = nil,
                onApplyMenu: ((String, Date) -> Void)? = nil,
                onAddDay: ((Date) -> Void)? = nil) {
        self.entries = entries; self.menus = menus; self.feedURL = feedURL
        self.onAddWeekToList = onAddWeekToList; self.onApplyMenu = onApplyMenu
        self.onAddDay = onAddDay
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sticky header: span switcher + prominent week title + primary CTA.
            // Lives outside the List so it never scrolls away (and never hides
            // behind the floating pill tab bar as a toolbar bubble did).
            VStack(alignment: .leading, spacing: 10) {
                Picker("Span", selection: $span) {
                    ForEach(PlanSpan.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }
                .pickerStyle(.segmented)
                Text(spanTitle)
                    .font(.title2.bold())
                Button("Add week to list") {
                    onAddWeekToList?(Self.weekStart(containing: anchor))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.background)
            Divider()
            List {
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
            // Bottom scroll inset so the last rows clear the floating tab bar.
            .contentMargins(.bottom, 48, for: .scrollContent)
        }
        .navigationTitle("Plan")
        .safeAreaPadding(.bottom, 8)
    }

    // MARK: Title

    private var spanTitle: String {
        switch span {
        case .day: Self.dayTitle(anchor)
        case .week: "Week of \(Self.dayTitle(Self.weekStart(containing: anchor)))"
        case .month: Self.monthTitle(anchor)
        }
    }

    // MARK: Sections

    private func daySection(for date: Date) -> some View {
        Section {
            dayRows(for: date)
        }
    }

    private func weekSections(weekStart: Date) -> some View {
        ForEach(Self.days(in: weekStart, count: 7), id: \.self) { day in
            Section(Self.dayTitle(day)) {
                dayRows(for: day)
            }
        }
    }

    private func monthSection(containing date: Date) -> some View {
        let days = Self.daysInMonth(containing: date)
        return Section {
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.dayTitle(day)).font(.subheadline.bold())
                    dayRows(for: day)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func dayRows(for day: Date) -> some View {
        Group {
            let dayEntries = entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            if dayEntries.isEmpty {
                HStack {
                    Text("No meals planned").foregroundStyle(.secondary)
                    Spacer()
                    if let onAddDay = onAddDay {
                        Button {
                            onAddDay(day)
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                ForEach(dayEntries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.meal.capitalized).font(.headline)
                            let detail = entry.recipeTitle ?? entry.note
                            if !detail.isEmpty {
                                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let s = entry.servings {
                            Text("\(fractionDisplayString(for: s)) servings").font(.caption).foregroundStyle(.tertiary)
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
