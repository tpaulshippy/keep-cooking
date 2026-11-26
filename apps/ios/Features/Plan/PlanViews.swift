// Keep Cooking — Lane 4 Plan: day/week/month views + reusable menus + add-week-to-list
// Paprika-inspired rebuild: segmented span switcher, chevron date navigator,
// per-meal day sections, week day rows, month calendar grid, bottom edit bar,
// and a multi-step Add Meal wizard sheet. Dark-mode aware (system colors only).

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

/// Searchable recipe row for the Add Meal wizard (filled from @Query at call site).
public struct RecipeOptionSnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var category: String
    public var rating: Double
    public var thumbKey: String?
    public init(id: String, title: String, category: String = "",
                rating: Double = 0, thumbKey: String? = nil) {
        self.id = id; self.title = title; self.category = category
        self.rating = rating; self.thumbKey = thumbKey
    }
}

/// Prefill + result payload for the Add Meal wizard.
public struct AddMealRequest: Hashable, Sendable {
    public var date: Date
    public var meal: String
    public var recipeId: String?
    public var note: String
    public var servings: Double?
    public init(date: Date = Date(), meal: String = "dinner",
                recipeId: String? = nil, note: String = "",
                servings: Double? = nil) {
        self.date = date; self.meal = meal; self.recipeId = recipeId
        self.note = note; self.servings = servings
    }
}

public enum PlanSpan: String, Hashable, CaseIterable {
    case day, week, month
}

// MARK: - Meal presentation helpers

/// Canonical meal order (matches MealSlot raw values).
public let planMealOrder: [String] = ["breakfast", "lunch", "dinner", "snack"]

// MARK: - Plan view

/// Day / week / month planner. `onAddWeekToList` receives the ISO week-start
/// date the user wants aggregated into a shopping list (see PlanAggregation).
public struct PlanView: View {
    private let entries: [PlanEntrySnapshot]
    private let menus: [MenuSnapshot]
    private let feedURL: URL?
    private let recipeOptions: [RecipeOptionSnapshot]
    @State private var span: PlanSpan = .week
    @State private var anchor: Date = Date()
    @State private var monthSelection: Date?
    @State private var editMode: Bool = false
    @State private var sheetRequest: AddMealRequest?
    @State private var sheetPresented: Bool = false
    var onAddWeekToList: ((Date) -> Void)?
    var onApplyMenu: ((String, Date) -> Void)? // (menuId, weekStart)
    var onAddDay: ((Date) -> Void)? // empty-day "Add" affordance target
    var onSelectEntry: ((String) -> Void)?
    var onDeleteEntry: ((String) -> Void)?
    var onSaveMeal: ((Date, String, String?, String, Double?) -> Void)?
    var onSearchRecipes: ((String) -> Void)?

    public init(entries: [PlanEntrySnapshot], menus: [MenuSnapshot] = [], feedURL: URL? = nil,
                recipeOptions: [RecipeOptionSnapshot] = [],
                onAddWeekToList: ((Date) -> Void)? = nil,
                onApplyMenu: ((String, Date) -> Void)? = nil,
                onAddDay: ((Date) -> Void)? = nil,
                onSelectEntry: ((String) -> Void)? = nil,
                onDeleteEntry: ((String) -> Void)? = nil,
                onSaveMeal: ((Date, String, String?, String, Double?) -> Void)? = nil,
                onSearchRecipes: ((String) -> Void)? = nil) {
        self.entries = entries; self.menus = menus; self.feedURL = feedURL
        self.recipeOptions = recipeOptions
        self.onAddWeekToList = onAddWeekToList; self.onApplyMenu = onApplyMenu
        self.onAddDay = onAddDay
        self.onSelectEntry = onSelectEntry; self.onDeleteEntry = onDeleteEntry
        self.onSaveMeal = onSaveMeal; self.onSearchRecipes = onSearchRecipes
    }

    // MARK: Meal display

    public static func displayName(for meal: String) -> String {
        switch meal.lowercased() {
        case "breakfast": return "Breakfast"
        case "lunch": return "Lunch"
        case "dinner": return "Dinner"
        case "snack", "snacks": return "Snacks"
        default: return meal.capitalized
        }
    }

    public static func color(for meal: String) -> Color {
        switch meal.lowercased() {
        case "breakfast": return .orange
        case "lunch": return .green
        case "dinner": return .indigo
        case "snack", "snacks": return .pink
        default: return Color.accentColor
        }
    }

    // MARK: Body

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Segmented span switcher.
            Picker("Span", selection: $span) {
                ForEach(PlanSpan.allCases, id: \.self) { Text($0.rawValue.capitalized) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("plan-span-picker")

            // 2. Date navigator bar.
            HStack {
                Button {
                    shiftAnchor(by: -1)
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("plan-prev")
                Spacer()
                Text(navigatorTitle)
                    .font(.headline)
                    .accessibilityIdentifier("plan-title")
                Spacer()
                Button {
                    shiftAnchor(by: 1)
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("plan-next")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // 3–5. Span content.
            Group {
                switch span {
                case .day:
                    dayContent
                case .week:
                    weekContent
                case .month:
                    monthContent
                }
            }

            Divider()

            // 6. Bottom bar.
            bottomBar
        }
        .accessibilityIdentifier("plan-view")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSheet(date: anchor, meal: "dinner")
                } label: {
                    Label("Add meal", systemImage: "plus")
                }
                .accessibilityIdentifier("plan-quick-add")
            }
        }
        .sheet(isPresented: $sheetPresented) {
            if let req = sheetRequest {
                AddMealSheet(recipeOptions: recipeOptions,
                             initialDate: req.date, initialMeal: req.meal,
                             onSearch: onSearchRecipes,
                             onSave: { saved in
                                onSaveMeal?(saved.date, saved.meal, saved.recipeId, saved.note, saved.servings)
                                sheetPresented = false
                             },
                             onCancel: { sheetPresented = false })
            }
        }
    }

    // MARK: Navigator

    private var navigatorTitle: String {
        let cal = Calendar.current
        switch span {
        case .day:
            return anchor.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
        case .week:
            let start = Self.weekStart(containing: anchor)
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            let fmt = Date.FormatStyle().month(.abbreviated).day().year()
            return "\(start.formatted(fmt)) - \(end.formatted(fmt))"
        case .month:
            return Self.monthTitle(anchor)
        }
    }

    private func shiftAnchor(by steps: Int) {
        let cal = Calendar.current
        switch span {
        case .day:
            if let d = cal.date(byAdding: .day, value: steps, to: anchor) { anchor = d }
        case .week:
            if let d = cal.date(byAdding: .day, value: steps * 7, to: anchor) { anchor = d }
        case .month:
            if let d = cal.date(byAdding: .month, value: steps, to: anchor) { anchor = d }
        }
        monthSelection = nil
    }

    private func openSheet(date: Date, meal: String) {
        sheetRequest = AddMealRequest(date: date, meal: meal)
        sheetPresented = true
    }

    // MARK: Day view

    private var dayContent: some View {
        List {
            ForEach(planMealOrder, id: \.self) { meal in
                Section {
                    let list = entriesForDay(anchor, meal: meal)
                    if list.isEmpty {
                        EmptyMealRow()
                    } else {
                        ForEach(list) { entry in
                            entryRow(entry, showMealLabel: false)
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                let all = entriesForDay(anchor, meal: meal)
                                if all.indices.contains(i) { onDeleteEntry?(all[i].id) }
                            }
                        }
                    }
                } header: {
                    MealSectionHeader(meal: meal, date: anchor) {
                        openSheet(date: anchor, meal: meal)
                        onAddDay?(anchor)
                    }
                }
            }
            // Keep the prominent CTA reachable (existing UITest looks for it).
            Section {
                Button("Add week to list") {
                    onAddWeekToList?(Self.weekStart(containing: anchor))
                }
                .buttonStyle(.borderedProminent)
                if !menus.isEmpty {
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
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Week view

    private var weekContent: some View {
        let start = Self.weekStart(containing: anchor)
        let days = Self.days(in: start, count: 7)
        return List {
            ForEach(days, id: \.self) { day in
                Section {
                    let list = entriesForDay(day, meal: nil)
                    if list.isEmpty {
                        EmptyMealRow()
                    } else {
                        ForEach(list) { entry in
                            weekEntryRow(entry)
                        }
                        .onDelete { offsets in
                            for i in offsets {
                                let all = entriesForDay(day, meal: nil)
                                if all.indices.contains(i) { onDeleteEntry?(all[i].id) }
                            }
                        }
                    }
                    if days.first == day {
                        Button("Add week to list") {
                            onAddWeekToList?(Self.weekStart(containing: anchor))
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                } header: {
                    WeekDayHeader(day: day,
                                  isToday: Calendar.current.isDateInToday(day)) {
                        openSheet(date: day, meal: "dinner")
                        onAddDay?(day)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Month view

    private var monthContent: some View {
        List {
            Section {
                MonthGrid(anchor: anchor, entries: entries,
                          selection: monthSelection ?? anchor,
                          onPick: { monthSelection = $0 })
            }
            Section {
                let focus = monthSelection ?? anchor
                let list = entriesForDay(focus, meal: nil)
                if list.isEmpty {
                    EmptyMealRow()
                } else {
                    ForEach(list) { entry in
                        entryRow(entry, showMealLabel: true)
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            if list.indices.contains(i) { onDeleteEntry?(list[i].id) }
                        }
                    }
                }
            } header: {
                Text((monthSelection ?? anchor).formatted(.dateTime.weekday(.abbreviated).month().day()))
                    .font(.subheadline.bold())
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Entry rows

    private func entriesForDay(_ day: Date, meal: String?) -> [PlanEntrySnapshot] {
        let cal = Calendar.current
        return entries.filter { entry in
            guard cal.isDate(entry.date, inSameDayAs: day) else { return false }
            if let meal { return entry.meal.lowercased() == meal.lowercased() || (meal == "snack" && entry.meal.lowercased() == "snacks") }
            return true
        }
        .sorted { planMealOrderIndex($0.meal) < planMealOrderIndex($1.meal) }
    }

    private func planMealOrderIndex(_ meal: String) -> Int {
        let lower = meal.lowercased() == "snacks" ? "snack" : meal.lowercased()
        return planMealOrder.firstIndex(of: lower) ?? 99
    }

    private func entryTitle(_ entry: PlanEntrySnapshot) -> String {
        if let t = entry.recipeTitle, t.isEmpty == false { return t }
        if entry.note.isEmpty == false { return entry.note }
        return Self.displayName(for: entry.meal)
    }

    private func entryRow(_ entry: PlanEntrySnapshot, showMealLabel: Bool) -> some View {
        Button {
            onSelectEntry?(entry.id)
        } label: {
            HStack(spacing: 12) {
                entryThumb(entry)
                VStack(alignment: .leading, spacing: 2) {
                    if showMealLabel {
                        Text(Self.displayName(for: entry.meal).uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(Self.color(for: entry.meal))
                    }
                    Text(entryTitle(entry))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let s = entry.servings {
                        Text("\(fractionDisplayString(for: s)) servings")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if entry.recipeId == nil, entry.note.isEmpty == false, entry.recipeTitle == nil {
                        Text(entry.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if editMode {
                    Button {
                        onDeleteEntry?(entry.id)
                    } label: {
                        Label("Delete", systemImage: "minus.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { onDeleteEntry?(entry.id) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func weekEntryRow(_ entry: PlanEntrySnapshot) -> some View {
        Button {
            onSelectEntry?(entry.id)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.color(for: entry.meal))
                    .frame(width: 4)
                Text(Self.displayName(for: entry.meal))
                    .font(.subheadline.bold())
                    .foregroundStyle(Self.color(for: entry.meal))
                    .frame(minWidth: 76, alignment: .leading)
                Text("|")
                    .foregroundStyle(.tertiary)
                Text(entryTitle(entry))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if editMode {
                    Button {
                        onDeleteEntry?(entry.id)
                    } label: {
                        Label("Delete", systemImage: "minus.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { onDeleteEntry?(entry.id) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func entryThumb(_ entry: PlanEntrySnapshot) -> some View {
        Group {
            if entry.recipeId != nil {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Self.color(for: entry.meal).opacity(0.25))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "fork.knife")
                            .foregroundStyle(Self.color(for: entry.meal))
                    }
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "note.text")
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Button {
                editMode.toggle()
            } label: {
                Label(editMode ? "Done" : "Edit", systemImage: "pencil")
            }
            Spacer()
            Button("Today") {
                anchor = Date()
                monthSelection = nil
            }
            .accessibilityIdentifier("plan-today")
            Spacer()
            SwiftUI.Menu {
                Button("Add week to list") {
                    onAddWeekToList?(Self.weekStart(containing: anchor))
                }
                if !menus.isEmpty {
                    SwiftUI.Menu("Apply menu") {
                        ForEach(menus) { menu in
                            Button(menu.name) {
                                onApplyMenu?(menu.id, Self.weekStart(containing: anchor))
                            }
                        }
                    }
                }
                if feedURL != nil {
                    // Subscribe row lives in the overflow menu; keep type backed by URL.
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            if let feedURL {
                SubscribeRow(feedURL: feedURL)
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
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

    /// yyyy-MM-dd identifier suffix (locale/timezone stable).
    static func isoDayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Day helpers

private struct EmptyMealRow: View {
    var body: some View {
        Text("No meals planned")
            .foregroundStyle(.secondary)
            .font(.subheadline)
    }
}

private struct MealSectionHeader: View {
    let meal: String
    let date: Date
    let onAdd: () -> Void

    var body: some View {
        HStack {
            Text(PlanView.displayName(for: meal).uppercased())
                .font(.caption.bold())
            Spacer()
            Button {
                onAdd()
            } label: {
                Label("Add \(PlanView.displayName(for: meal))", systemImage: "plus.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("plan-add-\(meal.lowercased())-\(PlanView.isoDayString(date))")
        }
    }
}

private struct WeekDayHeader: View {
    let day: Date
    let isToday: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.subheadline.bold())
                .textCase(.uppercase)
            if isToday {
                Text("TODAY")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }
            Spacer()
            Button {
                onAdd()
            } label: {
                Label("Add", systemImage: "plus.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("plan-add-day-\(PlanView.isoDayString(day))")
        }
    }
}

// MARK: - Month grid (shared by month view + wizard date step)

struct MonthGrid: View {
    let anchor: Date
    let entries: [PlanEntrySnapshot]
    let selection: Date
    let onPick: (Date) -> Void
    var idPrefix: String = "plan-month-day"

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        VStack(spacing: 4) {
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"], id: \.self) { d in
                    Text(d).font(.caption2.bold()).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(cells(), id: \.id) { cell in
                    Button {
                        if let date = cell.date { onPick(date) }
                    } label: {
                        VStack(spacing: 2) {
                            Text(cell.label)
                                .font(.subheadline)
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle()
                                        .fill(cell.isSelected ? Color.red : Color.clear)
                                )
                                .foregroundStyle(cell.isSelected ? .white : (cell.isCurrentMonth ? .primary : .secondary))
                                .opacity(cell.isCurrentMonth ? 1 : 0.45)
                            Circle()
                                .fill(cell.hasEntries ? Color.red.opacity(0.9) : Color.clear)
                                .frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(cell.date == nil)
                    .accessibilityIdentifier(cell.date.map { "\(idPrefix)-\(PlanView.isoDayString($0))" } ?? "\(idPrefix)-empty")
                }
            }
        }
    }

    private struct Cell: Hashable {
        var id: String
        var date: Date?
        var label: String
        var isCurrentMonth: Bool
        var isSelected: Bool
        var hasEntries: Bool
    }

    private func cells() -> [Cell] {
        let cal = Calendar.current
        let monthDays = PlanView.daysInMonth(containing: anchor)
        guard let first = monthDays.first else { return [] }
        let leading = cal.component(.weekday, from: first) - 1 // SUN=1
        var out: [Cell] = []
        let prevDays: [Date] = {
            var arr: [Date] = []
            for i in stride(from: leading, to: 0, by: -1) {
                if let d = cal.date(byAdding: .day, value: -i, to: first) { arr.append(d) }
            }
            return arr
        }()
        for d in prevDays {
            out.append(Cell(id: "lead-\(PlanView.isoDayString(d))", date: d,
                            label: "\(cal.component(.day, from: d))",
                            isCurrentMonth: false,
                            isSelected: cal.isDate(d, inSameDayAs: selection),
                            hasEntries: hasEntries(on: d)))
        }
        for d in monthDays {
            out.append(Cell(id: PlanView.isoDayString(d), date: d,
                            label: "\(cal.component(.day, from: d))",
                            isCurrentMonth: true,
                            isSelected: cal.isDate(d, inSameDayAs: selection),
                            hasEntries: hasEntries(on: d)))
        }
        while out.count < 42 {
            let last = out.last?.date ?? first
            if let next = cal.date(byAdding: .day, value: 1, to: last) {
                out.append(Cell(id: "trail-\(PlanView.isoDayString(next))", date: next,
                                label: "\(cal.component(.day, from: next))",
                                isCurrentMonth: false,
                                isSelected: cal.isDate(next, inSameDayAs: selection),
                                hasEntries: hasEntries(on: next)))
            } else { break }
        }
        return out
    }

    private func hasEntries(on day: Date) -> Bool {
        entries.contains { Calendar.current.isDate($0.date, inSameDayAs: day) }
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

// MARK: - Add Meal wizard

public enum AddMealKind: String, Hashable, CaseIterable {
    case recipe, note, menu, ingredient
}

/// Multi-step Add Meal wizard: kind -> detail -> date -> type+scale.
public struct AddMealSheet: View {
    private let recipeOptions: [RecipeOptionSnapshot]
    @State private var step: Int = 0
    @State private var kind: AddMealKind = .recipe
    @State private var searchText: String = ""
    @State private var pickedRecipeId: String?
    @State private var noteText: String = ""
    @State private var date: Date
    @State private var meal: String
    @State private var servings: Double = 2
    var onSearch: ((String) -> Void)?
    var onSave: ((AddMealRequest) -> Void)?
    var onCancel: (() -> Void)?

    public init(recipeOptions: [RecipeOptionSnapshot] = [],
                initialDate: Date = Date(), initialMeal: String = "dinner",
                onSearch: ((String) -> Void)? = nil,
                onSave: ((AddMealRequest) -> Void)? = nil,
                onCancel: (() -> Void)? = nil) {
        self.recipeOptions = recipeOptions
        self._date = State(initialValue: initialDate)
        self._meal = State(initialValue: initialMeal)
        self.onSearch = onSearch; self.onSave = onSave; self.onCancel = onCancel
    }

    private var filteredRecipes: [RecipeOptionSnapshot] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.isEmpty == false else { return recipeOptions }
        return recipeOptions.filter {
            $0.title.lowercased().contains(q) || $0.category.lowercased().contains(q)
        }
    }

    private var canAdvance: Bool {
        switch step {
        case 1:
            switch kind {
            case .recipe: return pickedRecipeId != nil
            case .note: return noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            case .menu, .ingredient: return false
            }
        default: return true
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressDots
                    .padding(.top, 8)
                Group {
                    switch step {
                    case 0: kindStep
                    case 1: detailStep
                    case 2: dateStep
                    default: typeStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Spacer(minLength: 8)
                wizardFooter
            }
            .padding()
            .navigationTitle("Add Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel?()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
            }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var kindStep: some View {
        List {
            ForEach(AddMealKind.allCases, id: \.self) { k in
                Button {
                    kind = k
                    if step < 3 { step = 1 }
                } label: {
                    HStack {
                        Image(systemName: icon(for: k))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        Text(k.rawValue.capitalized)
                            .foregroundStyle(.primary)
                        Spacer()
                        if kind == k {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .accessibilityIdentifier("addmeal-kind-\(k.rawValue)")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var detailStep: some View {
        Group {
            switch kind {
            case .recipe:
                VStack(spacing: 8) {
                    TextField("Search recipes", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("addmeal-search")
                        .onChange(of: searchText) { _, v in onSearch?(v) }
                    List {
                        ForEach(filteredRecipes) { r in
                            Button {
                                pickedRecipeId = r.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(r.title).foregroundStyle(.primary)
                                        if r.category.isEmpty == false {
                                            Text(r.category).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if pickedRecipeId == r.id {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .accessibilityIdentifier("addmeal-recipe-\(r.id)")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            case .note:
                TextField("Note (e.g. Takeout night)", text: $noteText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("addmeal-note")
                    .padding(.top, 8)
            case .menu, .ingredient:
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Coming soon — \(kind.rawValue.capitalized) planning isn't available yet.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
    }

    private var dateStep: some View {
        VStack(spacing: 8) {
            Text("Choose Date")
                .font(.headline)
            MonthGrid(anchor: date, entries: [], selection: date,
                      onPick: { date = $0 }, idPrefix: "addmeal-date")
        }
    }

    private var typeStep: some View {
        VStack(spacing: 12) {
            List {
                ForEach(planMealOrder, id: \.self) { m in
                    Button {
                        meal = m
                    } label: {
                        HStack {
                            Circle()
                                .fill(PlanView.color(for: m))
                                .frame(width: 10, height: 10)
                            Text(PlanView.displayName(for: m))
                                .foregroundStyle(.primary)
                            Spacer()
                            if meal.lowercased() == m {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .accessibilityIdentifier("addmeal-type-\(m)")
                }
            }
            .listStyle(.insetGrouped)
            HStack {
                Text("Scale")
                    .font(.headline)
                Spacer()
                Stepper("\(fractionDisplayString(for: servings)) servings", value: $servings, in: 0.25...24, step: 0.5)
                    .accessibilityIdentifier("addmeal-scale")
            }
            .padding(.horizontal, 4)
        }
    }

    private var wizardFooter: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if step < 3 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 1 && canAdvance == false)
            } else {
                Button("Save") {
                    let note: String = kind == .note ? noteText : ""
                    let rid: String? = kind == .recipe ? pickedRecipeId : nil
                    onSave?(AddMealRequest(date: date, meal: meal, recipeId: rid, note: note, servings: servings))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func icon(for kind: AddMealKind) -> String {
        switch kind {
        case .recipe: return "book"
        case .note: return "note.text"
        case .menu: return "list.bullet.rectangle"
        case .ingredient: return "carrot"
        }
    }
}
