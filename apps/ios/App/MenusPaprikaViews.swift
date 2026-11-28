// Keep Cooking — Menus Paprika-style UI
// apps/ios/App/MenusPaprikaViews.swift
//
// Paprika-inspired rebuild of the Menus tab. The old UI stacked "New menu /
// Apply to week / Menus (N)" sections with five buttons crammed in one row
// (Apply/Edit/Rename/Duplicate/Delete wrapped mid-word). This file replaces
// it with three focused surfaces:
//
//   1. PaprikaMenusScreen — black-friendly list: circular menu button left,
//      red "Menus" title, circular + right (alert-based create), one row per
//      menu (book icon + name + chevron, tap pushes the detail). Bottom
//      floating buttons: pencil (edit mode) + sort cycler. Rename /
//      duplicate / delete / quick-apply live in swipe actions + long-press
//      context menus — never five buttons in one row.
//   2. PaprikaMenuDetailView — DAY N red section headers with + buttons,
//      meal label (purple) + divider bar + recipe title rows. Tap edits via
//      the Add Meal flow; swipe deletes. Days stepper, slot renames, and the
//      Apply-to-week section live in the "..." options sheet.
//   3. MenuAddMealFlow — 3-step sheet: kind (Recipe/Note/Ingredient) →
//      recipe picker (search, count pill, thumb cards, stars) or note editor
//      → Choose Type (Breakfast/Lunch/Dinner/Snacks + None + Scale) with
//      progress dots and Next/Save.
//
// Persistence semantics are unchanged: entries via `menu.entries` +
// updatedAt bump (last-write-wins), tombstone deletes, "<name> copy"
// duplicates, rename guard, and apply/skip-filled/overwrite through
// MenuPlanning helpers (expandMenuEntries, planMealForMenuSlot,
// occupiedKeys, filterSkipped). Note-only saves use recipeId "" (empty
// recipeIds survive expansion and apply as nil-recipeId plans); MenuEntry
// has no note-text field in the v0.1.0 schema, so note text is not
// round-tripped — the step says so.
//
// Accessibility identifiers preserved from the old UI:
//   menus-view, menu-create, menu-row-<id>, menu-apply-<id>,
//   menu-rename-<id>, menu-duplicate-<id>, menu-delete-<id>,
//   menu-editor-<id>, menu-daycount-stepper, menu-slots-field.

import SwiftUI
import SwiftData

// MARK: - Shared styling

/// Paprika red + meal purple. Background/card adapt to the color scheme
/// (pure black cards-on-black in dark mode, grouped background in light).
enum MenusPaprikaStyle {
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let mealPurple = Color(red: 0.74, green: 0.52, blue: 0.98)

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(.systemGroupedBackground)
    }

    static func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.13) : Color(.secondarySystemBackground)
    }

    static func circleFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.13) : .white
    }
}

/// Circular 52pt icon button (Paprika top bar / floating buttons).
struct PaprikaCircleButton: View {
    let systemImage: String
    var tint: Color = .primary
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color(.secondarySystemBackground)))
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Step progress dots (current step red, rest gray).
struct PaprikaDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i == current ? MenusPaprikaStyle.accent : Color.gray.opacity(0.6))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// 5-star rating row (filled by rounding the optional rating).
struct MenuStarsRow: View {
    let rating: Double?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: (rating ?? 0) >= Double(i) + 0.75 ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Local photo resolver (mirrors the private helper in DemoFlows): only
/// absolute http(s) URLs resolve; relative R2 keys render placeholders.
func paprikaPhotoURL(forKey key: String?) -> URL? {
    guard let key, !key.isEmpty,
        let url = URL(string: key),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
    else { return nil }
    return url
}

/// Parses Paprika-style scale input: fractions ("1/2", "1 1/2"), percents
/// ("50%"), and plain decimals ("0.5"). Returns nil when unparseable.
func parseMenuScale(_ raw: String) -> Double? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty else { return nil }
    if text.hasSuffix("%") {
        let number = text.dropLast().trimmingCharacters(in: .whitespaces)
        if let value = Double(number) { return value / 100 }
        return nil
    }
    if text.contains("/") {
        let words = text.split(separator: " ")
        if words.count == 2, let whole = Double(words[0]) {
            let frac = words[1].split(separator: "/")
            if frac.count == 2, let num = Double(frac[0]), let den = Double(frac[1]), den != 0 {
                return whole + num / den
            }
            return nil
        }
        let frac = text.split(separator: "/")
        if frac.count == 2, let num = Double(frac[0]), let den = Double(frac[1]), den != 0 {
            return num / den
        }
        return nil
    }
    return Double(text)
}

// MARK: - List sort

enum MenusPaprikaSort: String, CaseIterable {
    case name
    case newest
    case entries

    var title: String {
        switch self {
        case .name: return "Name"
        case .newest: return "Newest"
        case .entries: return "Most entries"
        }
    }

    var icon: String {
        switch self {
        case .name: return "textformat"
        case .newest: return "clock"
        case .entries: return "list.number"
        }
    }
}

// MARK: - 1. Menus list screen

/// Paprika-style menus list. Data + persistence callbacks come from
/// MenusTabView (the logic owner); this view owns presentation state only
/// (create/rename alerts). `detail` builds the pushed detail view.
struct PaprikaMenusScreen<Detail: View>: View {
    @Environment(\.colorScheme) private var scheme
    let menus: [Menu]
    let confirm: String?
    @Binding var sort: MenusPaprikaSort
    @Binding var editMode: EditMode
    var onCreate: (String) -> Void
    var onRename: (Menu, String) -> Void
    var onDuplicate: (Menu) -> Void
    var onDelete: (Menu) -> Void
    var onApply: (Menu) -> Void
    /// Opens the navigation drawer (drawer shell). The Paprika header is
    /// the sole top bar on the Menus section, so its hamburger owns this.
    /// Defaults to no-op for non-drawer contexts (More-tab push).
    var onOpenDrawer: () -> Void = {}
    @ViewBuilder var detail: (Menu) -> Detail

    @State private var showCreate = false
    @State private var createName = ""
    @State private var renameTarget: Menu?
    @State private var renameDraft = ""

    private var sortedMenus: [Menu] {
        switch sort {
        case .name:
            return menus.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .newest:
            return menus.sorted { $0.updatedAt > $1.updatedAt }
        case .entries:
            return menus.sorted {
                if $0.entries.count == $1.entries.count {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.entries.count > $1.entries.count
            }
        }
    }

    var body: some View {
        ZStack {
            MenusPaprikaStyle.background(for: scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if let confirm {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(confirm).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                if sortedMenus.isEmpty {
                    Spacer()
                    Text("No menus yet — tap + to create one.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    List {
                        ForEach(sortedMenus, id: \.id) { menu in
                            NavigationLink {
                                detail(menu)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "book")
                                        .font(.title3)
                                        .foregroundStyle(MenusPaprikaStyle.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(menu.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        Text("\(menu.entries.count) entries")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .accessibilityIdentifier("menu-row-\(menu.id)")
                            .contextMenu {
                                Button("Apply to week") { onApply(menu) }
                                Button("Rename") {
                                    renameDraft = menu.name
                                    renameTarget = menu
                                }
                                .accessibilityIdentifier("menu-rename-\(menu.id)")
                                Button("Duplicate") { onDuplicate(menu) }
                                    .accessibilityIdentifier("menu-duplicate-\(menu.id)")
                                Button("Delete", role: .destructive) { onDelete(menu) }
                                    .accessibilityIdentifier("menu-delete-\(menu.id)")
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets where sortedMenus.indices.contains(i) {
                                onDelete(sortedMenus[i])
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, $editMode)
                }
            }
            floatingTools
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert("New menu", isPresented: $showCreate) {
            TextField("Menu name", text: $createName)
            Button("Cancel", role: .cancel) { createName = "" }
            Button("Create") {
                onCreate(createName)
                createName = ""
            }
            .accessibilityIdentifier("menu-create")
        }
        .alert("Rename menu", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Menu name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let target = renameTarget {
                    onRename(target, renameDraft)
                }
                renameTarget = nil
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onOpenDrawer) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MenusPaprikaStyle.accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color(.secondarySystemBackground)))
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open navigation menu")
            .accessibilityIdentifier("drawer-hamburger")
            Spacer()
            Text("Menus")
                .font(.title2.weight(.bold))
                .foregroundStyle(MenusPaprikaStyle.accent)
            Spacer()
            PaprikaCircleButton(systemImage: "plus", tint: MenusPaprikaStyle.accent, label: "New menu") {
                showCreate = true
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var floatingTools: some View {
        VStack {
            Spacer()
            HStack {
                PaprikaCircleButton(
                    systemImage: editMode == .active ? "checkmark" : "pencil",
                    label: editMode == .active ? "Done editing" : "Edit menus"
                ) {
                    editMode = editMode == .active ? .inactive : .active
                }
                Spacer()
                PaprikaCircleButton(
                    systemImage: "arrow.up.arrow.down",
                    label: "Sort menus: \(sort.title)"
                ) {
                    let all = MenusPaprikaSort.allCases
                    if let i = all.firstIndex(of: sort) {
                        sort = all[(i + 1) % all.count]
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - 2. Menu detail

/// Paprika-style menu detail: DAY N sections with + buttons, meal rows with
/// a purple label + divider bar + recipe title. Days/slots/apply live in the
/// "..." options sheet so rows never wrap. Persistence is inline (menu +
/// modelContext); only apply needs the owner's plans query via `onApply`.
struct PaprikaMenuDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let menu: Menu
    let recipes: [Recipe]
    @Binding var weekStart: Date
    @Binding var skipFilled: Bool
    var onApply: (Menu) -> Void

    @State private var dayCount: Int
    @State private var mealRequest: MenuMealRequest?
    @State private var showOptions = false
    @State private var detailEditMode: EditMode = .inactive

    init(menu: Menu, recipes: [Recipe], weekStart: Binding<Date>, skipFilled: Binding<Bool>, onApply: @escaping (Menu) -> Void) {
        self.menu = menu
        self.recipes = recipes
        self._weekStart = weekStart
        self._skipFilled = skipFilled
        self.onApply = onApply
        _dayCount = State(initialValue: menuDayCount(entries: menu.entries))
    }

    private var recipesById: [String: Recipe] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
    }

    private var entryBackedDays: Int {
        (menu.entries.map(\.dayOffset).max() ?? -1) + 1
    }

    private var gridDays: Int {
        min(max(dayCount, entryBackedDays), menuMaxDayCount)
    }

    private var slots: [String] {
        menuMealSlots(entries: menu.entries)
    }

    private func entries(for day: Int) -> [MenuEntry] {
        let order = slots
        return menu.entries.filter { $0.dayOffset == day }.sorted {
            let lhs = order.firstIndex(of: normalizeMeal($0.meal)) ?? Int.max
            let rhs = order.firstIndex(of: normalizeMeal($1.meal)) ?? Int.max
            if lhs == rhs { return $0.recipeId < $1.recipeId }
            return lhs < rhs
        }
    }

    var body: some View {
        ZStack {
            MenusPaprikaStyle.background(for: scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if menu.entries.isEmpty {
                    Spacer()
                    Text("No meals yet — tap + to add.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    List {
                        ForEach(0..<gridDays, id: \.self) { day in
                            Section {
                                let dayEntries = entries(for: day)
                                if dayEntries.isEmpty {
                                    Text("Nothing planned yet")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(Array(dayEntries.enumerated()), id: \.offset) { _, entry in
                                        Button {
                                            mealRequest = MenuMealRequest(dayOffset: day, entry: entry)
                                        } label: {
                                            entryRow(entry)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .onDelete { offsets in
                                        var current = menu.entries
                                        for i in offsets {
                                            let dayList = entries(for: day)
                                            if dayList.indices.contains(i),
                                               let idx = current.firstIndex(of: dayList[i])
                                            {
                                                current.remove(at: idx)
                                            }
                                        }
                                        persist(current)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("DAY \(day + 1)")
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(MenusPaprikaStyle.accent)
                                    Spacer()
                                    Button {
                                        mealRequest = MenuMealRequest(dayOffset: day, entry: nil)
                                    } label: {
                                        Image(systemName: "plus")
                                            .font(.headline.weight(.semibold))
                                            .foregroundStyle(MenusPaprikaStyle.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Add meal to day \(day + 1)")
                                }
                            }
                        }
                        if gridDays < menuMaxDayCount {
                            Section {
                                Button {
                                    applyDayCount(gridDays + 1)
                                } label: {
                                    Label("Add day", systemImage: "plus.circle")
                                        .foregroundStyle(MenusPaprikaStyle.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, $detailEditMode)
                }
            }
            floatingTools
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("menu-editor-\(menu.id)")
        .onChange(of: menu.tombstoned) { _, isDeleted in
            if isDeleted { dismiss() }
        }
        .sheet(item: $mealRequest) { request in
            MenuAddMealFlow(
                menu: menu,
                recipes: recipes,
                dayOffset: request.dayOffset,
                editingEntry: request.entry
            )
        }
        .sheet(isPresented: $showOptions) {
            MenuOptionsSheet(
                menu: menu,
                recipes: recipes,
                weekStart: $weekStart,
                skipFilled: $skipFilled,
                dayCount: $dayCount,
                onApply: { onApply(menu) }
            )
        }
    }

    private var topBar: some View {
        HStack {
            PaprikaCircleButton(systemImage: "chevron.left", tint: MenusPaprikaStyle.accent, label: "Back") {
                dismiss()
            }
            Spacer()
            Text(menu.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            SwiftUI.Menu {
                ForEach(0..<gridDays, id: \.self) { day in
                    Button("Day \(day + 1)") {
                        mealRequest = MenuMealRequest(dayOffset: day, entry: nil)
                    }
                }
                if gridDays < menuMaxDayCount {
                    Button("Add day") { applyDayCount(gridDays + 1) }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MenusPaprikaStyle.accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color(.secondarySystemBackground)))
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
            }
            .accessibilityLabel("Add meal")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var floatingTools: some View {
        VStack {
            Spacer()
            HStack {
                PaprikaCircleButton(
                    systemImage: detailEditMode == .active ? "checkmark" : "pencil",
                    label: detailEditMode == .active ? "Done editing" : "Edit meals"
                ) {
                    detailEditMode = detailEditMode == .active ? .inactive : .active
                }
                Spacer()
                PaprikaCircleButton(systemImage: "ellipsis", label: "Menu options") {
                    showOptions = true
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func entryRow(_ entry: MenuEntry) -> some View {
        HStack(spacing: 10) {
            Text(PlanView.displayName(for: entry.meal))
                .font(.body)
                .foregroundStyle(MenusPaprikaStyle.mealPurple)
                .frame(minWidth: 84, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(MenusPaprikaStyle.mealPurple)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entryTitle(for: entry))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(fractionDisplayString(for: entry.servings)) servings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func entryTitle(for entry: MenuEntry) -> String {
        if let recipe = recipesById[entry.recipeId] { return recipe.title }
        return entry.recipeId.isEmpty ? "(Note)" : "(removed recipe)"
    }

    private func persist(_ entries: [MenuEntry]) {
        menu.entries = entries
        menu.updatedAt = Date()
        try? context.save()
        dayCount = max(dayCount, menuDayCount(entries: entries))
    }

    private func applyDayCount(_ newValue: Int) {
        dayCount = validateDayCount(newValue)
        if menu.entries.contains(where: { $0.dayOffset >= dayCount }) {
            persist(menu.entries.filter { $0.dayOffset < dayCount })
        }
    }
}

/// Identifiable wrapper for presenting the Add Meal sheet (add or edit).
private struct MenuMealRequest: Identifiable {
    let id = UUID()
    let dayOffset: Int
    let entry: MenuEntry?
}

// MARK: - Options sheet (days / slots / apply / danger zone)

/// "..." sheet for one menu: rename, days stepper (shrink confirms because
/// entries past the new length are dropped), entry-derived slot renames,
/// Apply-to-week (week start + skip-filled + Apply), duplicate, delete.
private struct MenuOptionsSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let menu: Menu
    let recipes: [Recipe]
    @Binding var weekStart: Date
    @Binding var skipFilled: Bool
    @Binding var dayCount: Int
    var onApply: () -> Void

    @State private var draftName: String
    @State private var shrinkAlert = false
    @State private var pendingShrinkTo = 1
    @State private var confirmDelete = false

    init(menu: Menu, recipes: [Recipe], weekStart: Binding<Date>, skipFilled: Binding<Bool>, dayCount: Binding<Int>, onApply: @escaping () -> Void) {
        self.menu = menu
        self.recipes = recipes
        self._weekStart = weekStart
        self._skipFilled = skipFilled
        self._dayCount = dayCount
        self.onApply = onApply
        _draftName = State(initialValue: menu.name)
    }

    private var entryBackedDays: Int {
        (menu.entries.map(\.dayOffset).max() ?? -1) + 1
    }

    private var beyondRangeCount: Int {
        menu.entries.filter { $0.dayOffset < 0 || $0.dayOffset > menuMaxDayCount - 1 }.count
    }

    private var slots: [String] {
        menuMealSlots(entries: menu.entries)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Menu") {
                    HStack {
                        TextField("Menu name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit(saveName)
                        Button("Save", action: saveName)
                            .buttonStyle(.bordered)
                            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Length") {
                    Stepper("Days: \(dayCount)",
                        value: Binding(get: { dayCount }, set: requestDayCount),
                        in: 1...menuMaxDayCount)
                        .accessibilityIdentifier("menu-daycount-stepper")
                    if dayCount > entryBackedDays {
                        Text("Extra days save once filled — days without recipes are editor-local.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if beyondRangeCount > 0 {
                        Text("\(beyondRangeCount) entries outside days 1–28 (e.g. synced) are kept but Apply ignores them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Meals") {
                    ForEach(slots, id: \.self) { slot in
                        MenuSlotRenameRow(slot: slot) { renameSlot(from: slot, to: $0) }
                    }
                    Text("Slots come from saved entries. Rename rewrites every matching entry (collisions deduped, first wins).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("menu-slots-field")
                Section("Apply to week") {
                    DatePicker("Week start", selection: $weekStart, displayedComponents: .date)
                    Toggle("Skip filled slots", isOn: $skipFilled)
                    Button("Apply to week") {
                        onApply()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("menu-apply-\(menu.id)")
                }
                Section {
                    Button("Duplicate menu") {
                        let copy = Menu(householdId: menu.householdId, name: menu.name + " copy",
                            entries: menu.entries, deviceId: menu.deviceId)
                        context.insert(copy)
                        try? context.save()
                        dismiss()
                    }
                    Button("Delete menu", role: .destructive) {
                        confirmDelete = true
                    }
                    .confirmationDialog("Delete \(menu.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            menu.tombstoned = true
                            menu.updatedAt = Date()
                            try? context.save()
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .navigationTitle(menu.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Shorten menu?", isPresented: $shrinkAlert) {
                Button("Remove", role: .destructive) { applyDayCount(pendingShrinkTo) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Entries on day \(pendingShrinkTo + 1) and later will be removed.")
            }
        }
    }

    private func saveName() {
        let text = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != menu.name else { return }
        menu.name = text
        menu.updatedAt = Date()
        try? context.save()
    }

    private func requestDayCount(_ newValue: Int) {
        let clamped = validateDayCount(newValue)
        if clamped >= dayCount {
            applyDayCount(clamped)
            return
        }
        if menu.entries.contains(where: { $0.dayOffset >= clamped }) {
            pendingShrinkTo = clamped
            shrinkAlert = true
        } else {
            applyDayCount(clamped)
        }
    }

    private func applyDayCount(_ newValue: Int) {
        dayCount = newValue
        if menu.entries.contains(where: { $0.dayOffset >= newValue }) {
            menu.entries = menu.entries.filter { $0.dayOffset < newValue }
            menu.updatedAt = Date()
            try? context.save()
        }
    }

    private func renameSlot(from old: String, to new: String) {
        let updated = renameMenuSlot(entries: menu.entries, from: old, to: new)
        guard updated != menu.entries else { return }
        menu.entries = updated
        menu.updatedAt = Date()
        try? context.save()
    }
}

/// Rename field for one entry-derived meal slot.
private struct MenuSlotRenameRow: View {
    let slot: String
    var onSave: (String) -> Void
    @State private var draft: String

    init(slot: String, onSave: @escaping (String) -> Void) {
        self.slot = slot
        self.onSave = onSave
        _draft = State(initialValue: slot)
    }

    var body: some View {
        HStack {
            TextField("Meal name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { onSave(draft) }
                .accessibilityIdentifier("menu-slot-rename-\(slot)")
            Button("Save") { onSave(draft) }
                .buttonStyle(.bordered)
                .disabled(normalizeMeal(draft).isEmpty || normalizeMeal(draft) == slot)
        }
    }
}

// MARK: - 3. Add Meal flow

private enum MenuMealKind: String {
    case recipe
    case note
    case ingredient
}

/// 3-step Add Meal sheet for one menu day: kind → recipe picker / note
/// editor → Choose Type + scale. Editing an existing entry starts at the
/// Choose Type step with its values prefilled and saves in place.
struct MenuAddMealFlow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let menu: Menu
    let recipes: [Recipe]
    let dayOffset: Int
    let editingEntry: MenuEntry?

    @State private var step: Int
    @State private var kind: MenuMealKind
    @State private var pickedRecipeId: String?
    @State private var noteText: String
    @State private var meal: String
    @State private var servings: Double
    @State private var scaleText: String
    @State private var search: String

    private let mealTypes = ["breakfast", "lunch", "dinner", "snack"]

    init(menu: Menu, recipes: [Recipe], dayOffset: Int, editingEntry: MenuEntry?) {
        self.menu = menu
        self.recipes = recipes
        self.dayOffset = dayOffset
        self.editingEntry = editingEntry
        let entryMeal = editingEntry.map { normalizeMeal($0.meal) } ?? "dinner"
        let entryServings = editingEntry?.servings ?? 2
        _step = State(initialValue: editingEntry == nil ? 0 : 2)
        _kind = State(initialValue: (editingEntry?.recipeId.isEmpty ?? false) ? .note : .recipe)
        _pickedRecipeId = State(initialValue: editingEntry?.recipeId)
        _noteText = State(initialValue: "")
        _meal = State(initialValue: entryMeal)
        _servings = State(initialValue: entryServings)
        _scaleText = State(initialValue: "")
        _search = State(initialValue: "")
    }

    private var isEditing: Bool { editingEntry != nil }

    private var filtered: [Recipe] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return recipes }
        return recipes.filter { $0.title.lowercased().contains(q) }
    }

    private var canSave: Bool {
        !normalizeMeal(meal).isEmpty && (kind == .note || pickedRecipeId != nil)
    }

    var body: some View {
        ZStack {
            MenusPaprikaStyle.background(for: scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Group {
                    switch step {
                    case 0: kindStep
                    case 1: kindBody
                    default: typeStep
                    }
                }
                Spacer(minLength: 8)
                footer
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack {
            if step > (isEditing ? 2 : 0) {
                PaprikaCircleButton(systemImage: "chevron.left", tint: MenusPaprikaStyle.accent, label: "Back") {
                    step -= 1
                }
            } else {
                Color.clear.frame(width: 52, height: 52)
            }
            Spacer()
            Text(isEditing ? "Edit Meal" : "Add Meal")
                .font(.title3.weight(.semibold))
            Spacer()
            PaprikaCircleButton(systemImage: "xmark", tint: MenusPaprikaStyle.accent, label: "Close") {
                dismiss()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: Step 0 — kind

    private var kindStep: some View {
        VStack {
            VStack(spacing: 0) {
                kindRow(icon: "fork.knife", title: "Recipe", id: "menu-meal-kind-recipe") {
                    kind = .recipe
                    step = 1
                }
                Divider().padding(.leading, 56)
                kindRow(icon: "note.text", title: "Note", id: "menu-meal-kind-note") {
                    kind = .note
                    step = 1
                }
                Divider().padding(.leading, 56)
                kindRow(icon: "leaf", title: "Add Ingredient", id: "menu-meal-kind-ingredient") {
                    kind = .ingredient
                    step = 1
                }
            }
            .background(RoundedRectangle(cornerRadius: 20).fill(MenusPaprikaStyle.card(for: scheme)))
            .padding(.horizontal)
            .padding(.top, 24)
            Spacer()
        }
    }

    private func kindRow(icon: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(MenusPaprikaStyle.accent)
                    .frame(width: 32)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: Step 1a — recipe picker

    @ViewBuilder
    private var kindBody: some View {
        switch kind {
        case .recipe: recipeStep
        case .note: noteStep
        case .ingredient: ingredientStep
        }
    }

    private var recipeStep: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Text("All Recipes")
                        .font(.subheadline.weight(.semibold))
                    Text("/ \(filtered.count) recipe\(filtered.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(MenusPaprikaStyle.accent)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                Spacer()
            }
            .padding(.top, 4)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search recipes", text: $search)
                    .submitLabel(.search)
                    .accessibilityIdentifier("menu-meal-search")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(MenusPaprikaStyle.card(for: scheme)))
            .padding(.horizontal)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filtered, id: \.id) { recipe in
                        Button {
                            pickedRecipeId = recipe.id
                            if recipe.servings > 0 { servings = recipe.servings }
                        } label: {
                            HStack(spacing: 12) {
                                recipeThumb(for: recipe)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recipe.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(recipe.categories.first ?? "Uncategorized")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    MenuStarsRow(rating: recipe.rating)
                                }
                                Spacer()
                                if pickedRecipeId == recipe.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(MenusPaprikaStyle.accent)
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(MenusPaprikaStyle.card(for: scheme)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("menu-meal-recipe-\(recipe.id)")
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func recipeThumb(for recipe: Recipe) -> some View {
        Group {
            if let url = paprikaPhotoURL(forKey: recipe.photoThumb) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default:
                        Image(systemName: "fork.knife.circle.fill")
                            .resizable().scaledToFit().padding(8)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "fork.knife.circle.fill")
                    .resizable().scaledToFit().padding(10)
                    .frame(width: 56, height: 56)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Step 1b — note editor

    private var noteStep: some View {
        VStack(spacing: 12) {
            TextEditor(text: $noteText)
                .frame(minHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 16).fill(MenusPaprikaStyle.card(for: scheme)))
                .accessibilityIdentifier("menu-meal-note")
                .padding(.horizontal)
                .padding(.top, 16)
            Text("Menu notes save as placeholders without a recipe (the menu schema has no note-text field yet).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: Step 1c — ingredient (soon)

    private var ingredientStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .padding(.top, 40)
            Text("Ingredient-level menu items aren't available yet.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: Step 2 — choose type + scale

    private var typeStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                ForEach(mealTypes, id: \.self) { type in
                    Button {
                        meal = type
                    } label: {
                        HStack {
                            Text(PlanView.displayName(for: type))
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            if normalizeMeal(meal) == type {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(MenusPaprikaStyle.accent)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("menu-meal-type-\(type)")
                    if type != mealTypes.last {
                        Divider().padding(.leading, 20)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 20).fill(MenusPaprikaStyle.card(for: scheme)))
            .padding(.horizontal)
            .padding(.top, 16)
            HStack {
                Text("None")
                    .font(.subheadline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(normalizeMeal(meal).isEmpty ? MenusPaprikaStyle.accent.opacity(0.25) : Color(.secondarySystemBackground)))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .onTapGesture { meal = "" }
                    .accessibilityIdentifier("menu-meal-type-none")
                    .accessibilityLabel("No meal type")
                Spacer()
            }
            .padding(.horizontal, 24)
            VStack(spacing: 8) {
                HStack {
                    Text("Scale")
                        .font(.headline)
                    Spacer()
                    TextField("1/2, 50%, 0.5", text: $scaleText)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .submitLabel(.done)
                        .onChange(of: scaleText) { _, new in
                            if let value = parseMenuScale(new) {
                                servings = min(max(value, 0.25), 24)
                            }
                        }
                        .accessibilityIdentifier("menu-meal-scale")
                }
                Stepper("\(fractionDisplayString(for: servings)) servings",
                    value: $servings, in: 0.25...24, step: 0.5)
            }
            .padding(.horizontal, 24)
            if normalizeMeal(meal).isEmpty {
                Text("Pick a meal type to save — empty types are ignored when applying.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
    }

    // MARK: Footer — dots + Next/Save

    private var footer: some View {
        HStack {
            Spacer()
            PaprikaDots(total: 3, current: min(step, 2))
            Spacer()
            if step < 2 {
                Button("Next") {
                    if kind == .ingredient { return }
                    step += 1
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
                .accessibilityIdentifier("menu-meal-next")
            } else {
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .accessibilityIdentifier("menu-meal-save")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var canAdvance: Bool {
        switch step {
        case 0: return true
        case 1:
            switch kind {
            case .recipe: return pickedRecipeId != nil
            case .note: return true
            case .ingredient: return false
            }
        default: return true
        }
    }

    private func save() {
        guard canSave else { return }
        let recipeId: String
        switch kind {
        case .recipe: recipeId = pickedRecipeId ?? ""
        case .note, .ingredient: recipeId = ""
        }
        var entries = menu.entries
        let fresh = MenuEntry(dayOffset: dayOffset, meal: normalizeMeal(meal),
            recipeId: recipeId, servings: servings)
        if let editing = editingEntry, let i = entries.firstIndex(of: editing) {
            entries[i] = fresh
        } else {
            entries.append(fresh)
        }
        menu.entries = entries
        menu.updatedAt = Date()
        try? context.save()
        dismiss()
    }
}
