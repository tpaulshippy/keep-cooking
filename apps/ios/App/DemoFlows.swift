// Keep Cooking — PASS 2 demos
// apps/ios/App/DemoFlows.swift
//
// Wires the Lane 3/4 snapshot views (Clip/Caption/OCR, Plan, Shop, Cook)
// to live SwiftData so the three demo videos record the REAL app offline:
//   1. offline-launch — seeded recipes list with no backend configured.
//   2. ingest-save — OCRScanView: paste text → Parse → Save (fully local).
//   3. plan-to-list — PlanView week → "Add week to list" aggregates into an
//      aisle-sorted ShoppingList → check-off; cook mode reachable from detail.
//
// Accessibility identifiers (used by KeepCookingUITests):
//   recipe-list, recipe-detail-title, cook-button, add-to-list-button,
//   added-confirm, plan-view, week-to-list-confirm, lists-view,
//   more-clip, more-caption, more-ocr (+ ocr-* ids in OCRScanView).

import SwiftUI
import SwiftData

// MARK: - Aisle guess (local heuristic for demo aggregation)

/// Keyword → canonical aisle (see ShopHelpers.canonicalAisles). Unknown → "".
func guessAisle(for name: String) -> String {
    let n = name.lowercased()
    let table: [(aisle: String, keys: [String])] = [
        ("produce", ["onion", "garlic", "tomato", "lettuce", "spinach", "carrot", "potato",
                     "avocado", "lemon", "lime", "herb", "basil", "cilantro", "parsley",
                     "mushroom", "pepper", "cucumber", "broccoli", "apple", "banana", "berry", "berries"]),
        ("bakery", ["bread", "baguette", "bun", "roll", "tortilla", "pita"]),
        ("dairy", ["milk", "cheese", "butter", "cream", "yogurt", "egg", "parmesan", "mozzarella"]),
        ("meat", ["chicken", "beef", "pork", "bacon", "sausage", "turkey"]),
        ("seafood", ["salmon", "tuna", "shrimp", "cod", "fish"]),
        ("frozen", ["frozen", "ice cream"]),
        ("canned", ["canned", "can ", "beans", "tomato paste", "broth", "stock"]),
        ("pasta", ["pasta", "spaghetti", "ramen", "noodle", "lasagna"]),
        ("baking", ["flour", "sugar", "baking", "yeast", "vanilla", "chocolate", "cocoa"]),
        ("spices", ["salt", "pepper", "cumin", "paprika", "oregano", "gochujang", "pesto",
                    "spice", "cinnamon", "curry", "masala"]),
        ("beverages", ["coffee", "tea", "juice", "wine"]),
        ("dry goods", ["rice", "oat", "cereal", "quinoa", "lentil"]),
    ]
    for (aisle, keys) in table where keys.contains(where: { n.contains($0) }) {
        return aisle
    }
    return ""
}

/// Resolves a stored photo value to a loadable remote URL.
///
/// Stored `photoThumb` values are relative R2 keys (e.g.
/// `photos/<id>/thumb.jpg`) and there is no public-URL resolver wired yet, so
/// those return nil and photos render as placeholders. Absolute http(s) URLs
/// pass through for forward-compat.
private func photoURL(forKey key: String?) -> URL? {
    guard let key, !key.isEmpty,
          let url = URL(string: key),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return nil }
    return url
}

// MARK: - Recipes tab (live list → detail → cook / add-to-list)

// MARK: - Library sections + sort (bottom-bar revamp, Paprika-inspired)

/// Top-pill filter sections. All/Favorites/Uncategorized/Trash are real
/// SwiftData-backed filters; Most Recent sorts by updatedAt; Top Rated
/// filters rating >= 4. No favorite flag exists on Recipe, so Favorites
/// matches the "Favorites" category (case-insensitive).
enum LibrarySection: String, CaseIterable, Hashable {
    case all, recent, topRated, favorites, uncategorized, trash

    var title: String {
        switch self {
        case .all: return "All Recipes"
        case .recent: return "Most Recent"
        case .topRated: return "Top Rated"
        case .favorites: return "Favorites"
        case .uncategorized: return "Uncategorized"
        case .trash: return "Trash"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .recent: return "clock"
        case .topRated: return "star"
        case .favorites: return "heart"
        case .uncategorized: return "tag.slash"
        case .trash: return "trash"
        }
    }
}

enum LibrarySort: String, CaseIterable, Hashable {
    case title, recent, rating

    var title: String {
        switch self {
        case .title: return "Title"
        case .recent: return "Most Recent"
        case .rating: return "Top Rated"
        }
    }

    var icon: String {
        switch self {
        case .title: return "textformat"
        case .recent: return "clock"
        case .rating: return "star"
        }
    }
}

/// Add-menu navigation targets (Menu buttons can't host NavigationLinks).
enum LibraryAddDestination: Hashable {
    case clip, ocr, caption, duplicates
}

struct RecipeLibraryView: View {
    @Environment(\.modelContext) private var context
    /// Shell quick-add "Create New Recipe" trigger: the drawer shell owns
    /// the single + menu, so blank-recipe creation is requested through
    /// this binding and consumed here (insert + navigate to detail).
    @Binding var requestBlankRecipe: Bool
    @Query(filter: #Predicate<Recipe> { !$0.deleted },
           sort: [SortDescriptor(\Recipe.title)])
    private var recipes: [Recipe]
    @Query(filter: #Predicate<Recipe> { $0.deleted },
           sort: [SortDescriptor(\Recipe.updatedAt, order: .reverse)])
    private var trashed: [Recipe]
    @Query(sort: [SortDescriptor(\Cookbook.name)])
    private var cookbooks: [Cookbook]
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil
    @State private var section: LibrarySection = .all
    @State private var sort: LibrarySort = .title
    @State private var showFilterSheet = false
    @State private var showCategorize = false
    @State private var showCookbookPicker = false
    @State private var showNewCookbook = false
    @State private var newCookbookName = ""
    @State private var newCategoryText = ""
    @State private var pendingCats: Set<String> = []
    @State private var addDestination: LibraryAddDestination?
    @State private var createdRecipe: Recipe?
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var notice: String?

    private var allCategories: [String] {
        Array(Set(recipes.flatMap { $0.categories })).sorted()
    }

    private var base: [Recipe] {
        switch section {
        case .all, .recent:
            return recipes
        case .topRated:
            return recipes.filter { ($0.rating ?? 0) >= 4 }
        case .favorites:
            return recipes.filter { $0.categories.contains { $0.lowercased() == "favorites" } }
        case .uncategorized:
            return recipes.filter { $0.categories.isEmpty }
        case .trash:
            return trashed
        }
    }

    private func count(for target: LibrarySection) -> Int {
        switch target {
        case .all, .recent:
            return recipes.count
        case .topRated:
            return recipes.filter { ($0.rating ?? 0) >= 4 }.count
        case .favorites:
            return recipes.filter { $0.categories.contains { $0.lowercased() == "favorites" } }.count
        case .uncategorized:
            return recipes.filter { $0.categories.isEmpty }.count
        case .trash:
            return trashed.count
        }
    }

    private var recipesById: [String: Recipe] {
        Dictionary(uniqueKeysWithValues: (recipes + trashed).map { ($0.id, $0) })
    }

    private var filtered: [Recipe] {
        // Single source of truth for search behavior — see LibrarySearch.swift.
        // A selection whose category vanished (e.g. last recipe deleted) is
        // ignored so the list can't strand on an empty "No results" state.
        // Category chips don't apply inside Trash.
        let categories = (section == .trash) ? [] : selectedCategory.flatMap { sel in
            allCategories.contains(sel) ? [sel] : nil
        } ?? []
        let searched = filterRecipes(base, filter: AdvancedFilter(
            query: searchText, categories: categories))
        switch sort {
        case .title:
            return searched.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .recent:
            return searched.sorted { $0.updatedAt > $1.updatedAt }
        case .rating:
            return searched.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top section pill: "<Filter> / N recipes" opens the filter sheet.
                Button {
                    showFilterSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                        Text("\(filtered.count) recipes")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .padding(.top, 8)
                .accessibilityIdentifier("filter-pill")
                if !allCategories.isEmpty && section != .trash {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            categoryChip(title: "All", selected: selectedCategory == nil) {
                                selectedCategory = nil
                            }
                            ForEach(allCategories, id: \.self) { cat in
                                categoryChip(title: cat, selected: selectedCategory == cat) {
                                    selectedCategory = (selectedCategory == cat) ? nil : cat
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
                if let notice {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("library-notice")
                }
                Group {
                    if section == .trash && trashed.isEmpty {
                        ContentUnavailableView("Trash is empty", systemImage: "trash",
                            description: Text("Deleted recipes move here and sync as tombstones."))
                    } else if section != .trash && recipes.isEmpty {
                        VStack(spacing: 8) {
                            ContentUnavailableView("No recipes yet", systemImage: "book.pages",
                                description: Text("Seeds load on first launch — airplane mode works."))
                            ActionsCTA()
                        }
                    } else if filtered.isEmpty {
                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView("No recipes here", systemImage: section.icon,
                                description: Text("Nothing in \(section.title) yet."))
                        } else {
                            ContentUnavailableView.search(text: searchText)
                        }
                    } else {
                        List {
                            ForEach(filtered, id: \.id) { recipe in
                                if isSelecting {
                                    Button {
                                        toggleSelection(recipe)
                                    } label: {
                                        rowContent(for: recipe, showCheck: true)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("select-row-\(recipe.id)")
                                } else if section == .trash {
                                    HStack {
                                        rowContent(for: recipe, showCheck: false)
                                        Spacer()
                                        Button("Restore") { restore(recipe) }
                                            .buttonStyle(.bordered)
                                            .frame(minHeight: 44)
                                    }
                                } else {
                                    NavigationLink {
                                        RecipeDetailView(recipe: recipe)
                                    } label: {
                                        rowContent(for: recipe, showCheck: false)
                                    }
                                }
                            }
                            .onDelete(perform: section == .trash || isSelecting ? nil : tombstone)
                        }
                        .listStyle(.insetGrouped)
                        .contentMargins(.bottom, 148, for: .scrollContent)
                        .accessibilityIdentifier("recipe-list")
                    }
                }
            }
            .navigationTitle("Recipes")
            .overlay(alignment: .bottom) {
                if isSelecting { selectionBar } else { bottomBar }
            }
            // Shell quick-add "Create New Recipe" lands here: consume the
            // request whether the library was already visible (onChange) or
            // was just switched to (onAppear, same update as the trigger).
            .onAppear {
                if requestBlankRecipe { consumeBlankRequest() }
            }
            .onChange(of: requestBlankRecipe) {
                if requestBlankRecipe { consumeBlankRequest() }
            }
            .sheet(isPresented: $showFilterSheet) { filterSheet }
            .sheet(isPresented: $showCategorize) { categorizeSheet }
            .sheet(isPresented: $showCookbookPicker) { cookbookSheet }
            .onChange(of: section) {
                // Filters changed underfoot: drop IDs that are no longer
                // visible so bulk actions can't hit hidden recipes.
                selection.formIntersection(filtered.map { $0.id })
            }
            .onChange(of: selectedCategory) {
                selection.formIntersection(filtered.map { $0.id })
            }
            .alert("New cookbook", isPresented: $showNewCookbook) {
                TextField("Name", text: $newCookbookName)
                Button("Create", action: createCookbook)
                Button("Cancel", role: .cancel) { newCookbookName = "" }
            }
            .navigationDestination(item: $addDestination) { dest in
                switch dest {
                case .clip: ClipView()
                case .ocr: OCRScanView()
                case .caption: CaptionsImportView()
                case .duplicates: DuplicateReviewView(recipes: Array(recipes))
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { createdRecipe != nil },
                set: { if !$0 { createdRecipe = nil } }
            )) {
                if let createdRecipe { RecipeDetailView(recipe: createdRecipe) }
            }
        }
    }

    // MARK: - Rows

    private func rowContent(for recipe: Recipe, showCheck: Bool) -> some View {
        HStack(spacing: 12) {
            if showCheck {
                Image(systemName: selection.contains(recipe.id)
                    ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selection.contains(recipe.id) ? Color.accentColor : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            recipeThumb(for: recipe)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title).font(.headline)
                Text(librarySubtitle(for: recipe))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Bottom pill bar (normal mode)

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if section != .trash {
                Button("Edit") { enterSelection() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("edit-button")
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .accessibilityIdentifier("library-search-field")
                    .submitLabel(.search)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
            SwiftUI.Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
                Button {
                    addDestination = .duplicates
                } label: {
                    Label("Review duplicates", systemImage: "square.stack.3d.up")
                }
                Button {
                    newCookbookName = ""
                    showNewCookbook = true
                } label: {
                    Label("New cookbook", systemImage: "book.closed")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("more-button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("bottom-bar")
    }

    // MARK: - Selection toolbar

    private var allVisibleSelected: Bool {
        let visibleIds = Set(filtered.map { $0.id })
        return !visibleIds.isEmpty && selection == visibleIds
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Text("\(selection.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            HStack(spacing: 4) {
                Button {
                    if allVisibleSelected {
                        selection = []
                    } else {
                        selection = Set(filtered.map { $0.id })
                    }
                } label: {
                    Image(systemName: allVisibleSelected
                        ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("select-all-button")
                Button {
                    pendingCats = []
                    newCategoryText = ""
                    showCategorize = true
                } label: {
                    Image(systemName: "tag")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("categorize-button")
                Button {
                    addSelectedToShoppingList()
                } label: {
                    Image(systemName: "cart.badge.plus")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("bulk-add-to-list-button")
                SwiftUI.Menu {
                    Button {
                        showCookbookPicker = true
                    } label: {
                        Label("Change cookbook", systemImage: "book.closed")
                    }
                    .disabled(selection.isEmpty)
                    Button {
                        addSelectedToPlanner()
                    } label: {
                        Label("Add to meal planner", systemImage: "calendar.badge.plus")
                    }
                    .disabled(selection.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("bulk-more-button")
                }
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("bulk-delete-button")
                Spacer(minLength: 0)
                Button("Cancel") { exitSelection() }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("selection-cancel-button")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("selection-bar")
    }

    // MARK: - Filter sheet

    private var filterSheet: some View {
        NavigationStack {
            List {
                ForEach(LibrarySection.allCases, id: \.self) { target in
                    Button {
                        section = target
                        // Sections with an intrinsic order adopt it as the sort.
                        if target == .recent { sort = .recent }
                        else if target == .topRated { sort = .rating }
                        else if sort == .recent || sort == .rating { sort = .title }
                        if target != .trash { /* keep chips */ } else { selectedCategory = nil }
                        showFilterSheet = false
                    } label: {
                        HStack {
                            Image(systemName: target.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            Text(target.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(count(for: target))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if target == section {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("filter-row-\(target.rawValue)")
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFilterSheet = false }
                        .frame(minHeight: 44)
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Categorize sheet (bulk)

    private var categorizeSheet: some View {
        NavigationStack {
            List {
                Section("Apply to \(selection.count) recipes") {
                    ForEach(allCategories, id: \.self) { cat in
                        Button {
                            if pendingCats.contains(cat) { pendingCats.remove(cat) }
                            else { pendingCats.insert(cat) }
                        } label: {
                            HStack {
                                Text(cat).foregroundStyle(.primary)
                                Spacer()
                                if pendingCats.contains(cat) {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
                Section("New category") {
                    HStack {
                        TextField("Category name", text: $newCategoryText)
                            .submitLabel(.done)
                        Button("Add") { applyCategorize() }
                            .disabled(pendingCats.isEmpty
                                && newCategoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Categorize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCategorize = false }
                        .frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: applyCategorize)
                        .frame(minHeight: 44)
                        .disabled(pendingCats.isEmpty
                            && newCategoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Cookbook picker sheet (bulk)

    private var cookbookSheet: some View {
        NavigationStack {
            List {
                if cookbooks.filter({ !$0.deleted }).isEmpty {
                    Text("No cookbooks yet — create one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(cookbooks.filter { !$0.deleted }, id: \.id) { book in
                    Button {
                        toggleCookbookMembership(book)
                    } label: {
                        HStack {
                            Text(book.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(book.recipeIds.count)")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if selection.allSatisfy({ book.recipeIds.contains($0) }) && !selection.isEmpty {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    .frame(minHeight: 44)
                }
                Section("New cookbook") {
                    HStack {
                        TextField("Name", text: $newCookbookName)
                            .submitLabel(.done)
                        Button("Create & add") {
                            let book = Cookbook(householdId: "hh-demo", name: newCookbookName
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                                deviceId: currentDeviceId())
                            context.insert(book)
                            try? context.save()
                            for id in selection {
                                var ids = book.recipeIds
                                if !ids.contains(id) { ids.append(id) }
                                book.recipeIds = ids
                            }
                            book.updatedAt = Date()
                            try? context.save()
                            newCookbookName = ""
                            flash("Added \(selection.count) to \(book.name)")
                        }
                        .disabled(newCookbookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Change cookbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showCookbookPicker = false }
                        .frame(minHeight: 44)
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Selection + bulk actions

    private func enterSelection() {
        selection = []
        isSelecting = true
    }

    private func exitSelection() {
        selection = []
        isSelecting = false
    }

    private func toggleSelection(_ recipe: Recipe) {
        if selection.contains(recipe.id) { selection.remove(recipe.id) }
        else { selection.insert(recipe.id) }
    }

    private func flash(_ message: String) {
        notice = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if notice == message { notice = nil }
        }
    }

    private func createNew() {
        let recipe = Recipe(householdId: "hh-demo", title: "Untitled Recipe",
            deviceId: currentDeviceId())
        context.insert(recipe)
        try? context.save()
        createdRecipe = recipe
    }

    /// Consume the shell's blank-recipe request: reset the trigger first so
    /// a re-appear can't double-insert, then create + navigate to detail.
    private func consumeBlankRequest() {
        requestBlankRecipe = false
        createNew()
    }

    private func restore(_ recipe: Recipe) {
        recipe.deleted = false
        recipe.updatedAt = Date()
        try? context.save()
    }

    private func createCookbook() {
        let name = newCookbookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.insert(Cookbook(householdId: "hh-demo", name: name,
            deviceId: currentDeviceId()))
        try? context.save()
        newCookbookName = ""
        flash("Created \(name)")
    }

    private func applyCategorize() {
        var cats = pendingCats
        let typed = newCategoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { cats.insert(typed) }
        guard !cats.isEmpty else { return }
        var count = 0
        let byId = recipesById
        for id in selection {
            guard let recipe = byId[id], !recipe.deleted else { continue }
            var existing = recipe.categories
            for cat in cats where !existing.contains(where: { $0.lowercased() == cat.lowercased() }) {
                existing.append(cat)
            }
            recipe.categories = existing
            recipe.updatedAt = Date()
            count += 1
        }
        try? context.save()
        pendingCats = []
        newCategoryText = ""
        showCategorize = false
        flash("Categorized \(count) recipes")
    }

    private func toggleCookbookMembership(_ book: Cookbook) {
        let ids = Array(selection)
        var members = book.recipeIds
        if ids.allSatisfy({ members.contains($0) }) {
            members.removeAll(where: { selection.contains($0) })
        } else {
            for id in ids where !members.contains(id) { members.append(id) }
        }
        book.recipeIds = members
        book.updatedAt = Date()
        try? context.save()
    }

    /// Aggregates the selected recipes' ingredients into the "Shopping" list
    /// (same aisle-guess + scale pipeline as plan-to-list).
    private func addSelectedToShoppingList() {
        let deviceId = currentDeviceId()
        let byId = recipesById
        let inputs = selection.compactMap { byId[$0] }.flatMap { recipe in
            recipe.ingredients.map { ing in
                PlanGroceryInput(name: ing.name, quantity: ing.quantity, unit: ing.unit,
                    baseServings: recipe.servings, targetServings: recipe.servings,
                    recipeId: recipe.id)
            }
        }
        let lines = aggregateWeekToList(inputs)
        let list: ShoppingList
        if let existing = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.name == "Shopping" && !$0.deleted
        }) {
            list = existing
        } else {
            list = ShoppingList(householdId: "hh-demo", name: "Shopping", deviceId: deviceId)
            context.insert(list)
        }
        for line in lines {
            // Same pipeline as plan-to-list: fraction display with unit, and
            // the relationship set so ListsTabView (which renders list.items)
            // shows the rows.
            let qty = line.totalQuantity.map { scaledDisplay(name: "", quantity: $0, unit: line.unit, factor: 1).trimmingCharacters(in: .whitespaces) } ?? ""
            let item = ListItem(listId: list.id, name: line.name, quantity: qty,
                aisle: guessAisle(for: line.name),
                recipeId: line.recipeIds.first, deviceId: deviceId)
            item.shoppingList = list
            context.insert(item)
        }
        try? context.save()
        flash("Added \(lines.count) items to Shopping")
    }

    /// Plans each selected recipe as dinner today.
    private func addSelectedToPlanner() {
        let deviceId = currentDeviceId()
        let today = Calendar.current.startOfDay(for: Date())
        var count = 0
        let byId = recipesById
        for id in selection {
            guard let recipe = byId[id], !recipe.deleted else { continue }
            context.insert(Plan(householdId: "hh-demo", date: today, meal: .dinner,
                recipeId: recipe.id, servings: recipe.servings, deviceId: deviceId))
            count += 1
        }
        try? context.save()
        flash("Planned \(count) meals for today")
    }

    private func deleteSelected() {
        let byId = recipesById
        for id in selection {
            guard let recipe = byId[id] else { continue }
            recipe.deleted = true
            recipe.updatedAt = Date()
        }
        try? context.save()
        exitSelection()
    }

    private func categoryChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-chip-\(title)")
    }

    private func recipeThumb(for recipe: Recipe) -> some View {
        Group {
            if let url = photoURL(forKey: recipe.photoThumb) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default:
                        Image(systemName: "fork.knife.circle.fill")
                            .resizable().scaledToFit().padding(8)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "fork.knife.circle.fill")
                    .resizable().scaledToFit().padding(8)
                    .frame(width: 52, height: 52)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func librarySubtitle(for recipe: Recipe) -> String {
        let n = recipe.ingredients.count, m = recipe.steps.count
        var parts = [
            n == 1 ? "1 ingredient" : "\(n) ingredients",
            m == 1 ? "1 step" : "\(m) steps",
        ]
        if let total = totalMinutes(for: recipe) { parts.append("\(total) min") }
        if recipe.servings > 0 {
            parts.append("Serves \(fractionDisplayString(for: recipe.servings))")
        }
        let cats = recipe.categories.prefix(2).joined(separator: " · ")
        if !cats.isEmpty { parts.append(cats) }
        return parts.joined(separator: " · ")
    }

    private func totalMinutes(for recipe: Recipe) -> Int? {
        switch (recipe.prepMinutes, recipe.cookMinutes) {
        case let (p?, c?): return p + c
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    private func tombstone(at offsets: IndexSet) {
        for i in offsets {
            filtered[i].deleted = true
            // Sync is last-write-wins on updatedAt: bump it so this delete
            // tombstone beats a remote copy (mirrors applyMerge in LibraryViews).
            filtered[i].updatedAt = Date()
        }
        try? context.save()
    }
}

private struct ActionsCTA: View {
    var body: some View {
        VStack(spacing: 8) {
            NavigationLink("Clip a recipe URL") { ClipView() }
                .buttonStyle(.borderedProminent)
            NavigationLink("Scan a cookbook") { OCRScanView() }
                .buttonStyle(.bordered)
        }
        .padding(.top, 8)
    }
}

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var context
    let recipe: Recipe
    @State private var addedMessage: String?
    @State private var checked: Set<String> = []
    @State private var servings: Double
    @State private var pane: DetailPane = .ingredients

    /// Paprika-style segmented pane (custom capsule toggle, no copy).
    private enum DetailPane: String, CaseIterable {
        case ingredients
        case directions
        var title: String {
            switch self {
            case .ingredients: return "Ingredients"
            case .directions: return "Directions"
            }
        }
    }

    init(recipe: Recipe) {
        self.recipe = recipe
        _servings = State(initialValue: recipe.servings)
        _addedMessage = State(initialValue: nil)
    }

    private var sortedIngredients: [Ingredient] {
        recipe.ingredients.sorted(by: { $0.position < $1.position })
    }

    private var sortedSteps: [Step] {
        recipe.steps.sorted(by: { $0.position < $1.position })
    }

    private var totalMinutes: Int? {
        switch (recipe.prepMinutes, recipe.cookMinutes) {
        case let (p?, c?): return p + c
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 0) {
                    heroHeader
                    VStack(alignment: .leading, spacing: 14) {
                        titleBlock
                        metaRow
                        if let addedMessage {
                            confirmRow(addedMessage)
                        }
                        paneToggle
                        if pane == .ingredients {
                            ingredientsPane
                        } else {
                            directionsPane
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    // Clearance so the floating action cluster never
                    // covers the last step / ingredient.
                    .padding(.bottom, 110)
                }
            }
            floatingActions
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("recipe-detail-title")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { addToList() } label: {
                    Image(systemName: "cart.badge.plus")
                }
                .accessibilityIdentifier("add-to-list-button")
                .accessibilityLabel("Add to shopping list")
                Button { addToPlan() } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .accessibilityLabel("Add to tonight's plan")
                Button { toggleFavorite() } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .primary)
                }
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share recipe")
            }
        }
    }

    private var servingsDisplay: String {
        fractionDisplayString(for: servings)
    }

    @ViewBuilder
    private var heroHeader: some View {
        if let url = photoURL(forKey: recipe.photoThumb) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(height: 180).clipped()
                default:
                    placeholderHero
                }
            }
        } else {
            placeholderHero
        }
    }

    private var placeholderHero: some View {
        ZStack {
            LinearGradient(colors: [.orange, .red.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 180)
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: - Revamp: header / panes / floating actions

    private var isFavorite: Bool { recipe.isFavorite }

    private var shareText: String {
        [recipe.title, recipe.recipeDescription]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private var breadcrumb: String {
        "My Cookbook › \(recipe.categories.first ?? "Uncategorized")"
    }

    private var cookDestination: some View {
        CookModeView(
            title: recipe.title,
            baseServings: recipe.servings,
            ingredients: recipe.ingredients.map {
                CookModeView.IngredientSnapshot(id: $0.id, name: $0.name,
                    quantity: $0.quantity, unit: $0.unit)
            },
            steps: recipe.steps.map {
                CookModeView.StepSnapshot(id: $0.id, position: $0.position, text: $0.text)
            },
            initialServings: servings)
    }

    /// Title + tappable 1–5 star rating + source link + breadcrumb.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recipe.title)
                .font(.title2.weight(.bold))
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { star in
                    let filled = Double(star) <= (recipe.rating ?? 0)
                    Button { setRating(star) } label: {
                        Image(systemName: filled ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(filled ? .yellow : .secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
                }
            }
            .padding(.leading, -12)
            if !recipe.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = URL(string: recipe.sourceUrl),
               url.scheme != nil {
                Link(destination: url) {
                    Label(recipe.source.isEmpty ? (url.host ?? "Source") : recipe.source,
                        systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }
            }
            Text(breadcrumb)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Prep / total / servings meta row with icons.
    private var metaRow: some View {
        HStack(spacing: 16) {
            if let prep = recipe.prepMinutes {
                Label("\(prep) min prep", systemImage: "clock")
            }
            if let total = totalMinutes {
                Label("\(total) min total", systemImage: "timer")
            }
            Label("Serves \(servingsDisplay)", systemImage: "person.2.fill")
                .accessibilityLabel("Serves \(servingsDisplay)")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func confirmRow(_ message: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("added-confirm")
    }

    /// Custom capsule Ingredients|Directions toggle (44pt targets).
    private var paneToggle: some View {
        HStack(spacing: 0) {
            ForEach(DetailPane.allCases, id: \.self) { item in
                Button { pane = item } label: {
                    Text(item.title)
                        .font(.subheadline.weight(item == pane ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == pane ? .isSelected : [])
                .background(item == pane ? Color(.systemBackground) : Color.clear)
                .clipShape(Capsule())
                .foregroundStyle(item == pane ? .primary : .secondary)
            }
        }
        .padding(4)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
    }

    private var ingredientsPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Reset servings") { servings = recipe.servings }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Text("Serves \(servingsDisplay)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Stepper("", value: $servings, in: 1...24, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("Servings")
            }
            .padding(.vertical, 4)
            ForEach(sortedIngredients) { ing in
                Button {
                    if checked.contains(ing.id) { checked.remove(ing.id) }
                    else { checked.insert(ing.id) }
                } label: {
                    HStack {
                        Image(systemName: checked.contains(ing.id)
                            ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(checked.contains(ing.id) ? .green : .secondary)
                        Text(ing.display.isEmpty ? ing.name : ing.display)
                            .strikethrough(checked.contains(ing.id))
                            .foregroundStyle(checked.contains(ing.id) ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var directionsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("DESCRIPTION")
            Text(recipe.recipeDescription.isEmpty
                ? "No description yet." : recipe.recipeDescription)
                .font(.body)
                .foregroundStyle(recipe.recipeDescription.isEmpty ? .secondary : .primary)
            sectionHeader("DIRECTIONS")
            NavigationLink { cookDestination } label: {
                Label("Start Cooking", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .controlSize(.large)
            .accessibilityIdentifier("cook-button")
            ForEach(Array(sortedSteps.enumerated()), id: \.element.id) { idx, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(idx + 1)")
                        .font(.headline)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.text)
                            .font(.body)
                        if let hint = timerHint(for: step.text) {
                            Label(hint, systemImage: "timer")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Bottom-right floating cluster: cook-mode timer + pin/favorite.
    /// Overlay only spans its own buttons, so scrolling stays unblocked.
    private var floatingActions: some View {
        VStack(spacing: 12) {
            NavigationLink { cookDestination } label: {
                Image(systemName: "timer")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color(.systemBackground))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            .accessibilityLabel("Open cook mode")
            .accessibilityIdentifier("floating-timer-button")
            Button { toggleFavorite() } label: {
                Image(systemName: isFavorite ? "pin.fill" : "pin")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color(.systemBackground))
                    .foregroundStyle(isFavorite ? .red : .secondary)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            .accessibilityLabel(isFavorite ? "Unpin favorite" : "Pin favorite")
        }
        .padding(.trailing, 16)
        .padding(.bottom, 24)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Detects "N min/minutes" or "N hour(s)" in step text; label only.
    private func timerHint(for text: String) -> String? {
        let pattern = "(\\d+)\\s*(hours?|hrs?|minutes?|mins?)"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let match = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let num = ns.substring(with: match.range(at: 1))
        let unit = ns.substring(with: match.range(at: 2)).lowercased()
        let short = (unit.hasPrefix("hour") || unit.hasPrefix("hr")) ? "hr" : "min"
        return "~\(num) \(short)"
    }

    private func setRating(_ stars: Int) {
        if recipe.rating == Double(stars) {
            recipe.rating = nil
        } else {
            recipe.rating = Double(stars)
        }
        recipe.updatedAt = Date()
        try? context.save()
    }

    private func toggleFavorite() {
        recipe.isFavorite.toggle()
        recipe.updatedAt = Date()
        try? context.save()
    }

    /// Real SwiftData insert: this recipe planned for tonight's dinner.
    /// Skips the insert when a matching non-deleted plan already exists,
    /// so a double tap can't double that recipe's grocery quantities
    /// (addWeekToList aggregates every plan entry).
    private func addToPlan() {
        let tonight = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: tonight) ?? tonight
        let householdId = recipe.householdId
        let recipeId = recipe.id
        let mealRaw = MealSlot.dinner.rawValue
        let dup = (try? context.fetch(FetchDescriptor<Plan>(predicate: #Predicate<Plan> {
            !$0.deleted && $0.householdId == householdId
                && $0.date >= tonight && $0.date < tomorrow && $0.mealRaw == mealRaw
        })))?.contains(where: { $0.recipeId == recipeId }) ?? false
        if !dup {
            context.insert(Plan(householdId: recipe.householdId, date: tonight,
                meal: .dinner, recipeId: recipe.id,
                servings: servings, deviceId: currentDeviceId()))
            try? context.save()
        }
        addedMessage = "Planned \(recipe.title) for tonight"
    }

    private func addToList() {
        let deviceId = currentDeviceId()
        let inputs = recipe.ingredients.map { ing in
            PlanGroceryInput(name: ing.name, quantity: ing.quantity, unit: ing.unit,
                baseServings: recipe.servings, targetServings: servings, recipeId: recipe.id)
        }
        let lines = aggregateWeekToList(inputs)
        let list: ShoppingList
        if let existing = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.name == "Shopping" && !$0.deleted
        }) {
            list = existing
        } else {
            list = ShoppingList(householdId: recipe.householdId, name: "Shopping", deviceId: deviceId)
            context.insert(list)
        }
        for line in lines {
            let qty = line.totalQuantity.map { scaledDisplay(name: "", quantity: $0, unit: line.unit, factor: 1).trimmingCharacters(in: .whitespaces) } ?? ""
            let item = ListItem(listId: list.id, name: line.name, quantity: qty,
                aisle: guessAisle(for: line.name),
                recipeId: line.recipeIds.first, deviceId: deviceId)
            item.shoppingList = list
            context.insert(item)
        }
        try? context.save()
        addedMessage = "Added \(lines.count) items to Shopping"
    }
}

// MARK: - Plan tab (live week → add week to list)

struct PlanTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Plan.date)]) private var plans: [Plan]
    @Query(sort: [SortDescriptor(\Menu.name)]) private var menus: [Menu]
    @Query private var recipes: [Recipe]
    @State private var confirm: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let confirm {
                    Text(confirm)
                        .font(.subheadline).foregroundStyle(.green)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("week-to-list-confirm")
                }
                PlanView(entries: entries, menus: menuSnapshots, onAddWeekToList: addWeekToList,
                    onAddDay: addDay)
                    .accessibilityIdentifier("plan-view")
            }
        }
    }

    private var recipesById: [String: Recipe] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
    }

    private var entries: [PlanEntrySnapshot] {
        plans.filter { !$0.deleted }.map { plan in
            let recipe = plan.recipeId.flatMap { recipesById[$0] }
            return PlanEntrySnapshot(id: plan.id, date: plan.date,
                meal: plan.mealRaw, recipeId: plan.recipeId,
                recipeTitle: recipe?.title ?? (plan.note.isEmpty ? nil : plan.note),
                note: recipe == nil ? plan.note : "", servings: plan.servings)
        }
    }

    private var menuSnapshots: [MenuSnapshot] {
        menus.filter { !$0.deleted }.map {
            MenuSnapshot(id: $0.id, name: $0.name, entryCount: $0.entries.count)
        }
    }

    /// Empty-day "Add" affordance: inserts a blank dinner shell for `day`
    /// (recipe/note filled in later); the day row re-renders with content.
    private func addDay(_ day: Date) {
        context.insert(Plan(householdId: "hh-demo", date: day, meal: .dinner,
            deviceId: currentDeviceId()))
        try? context.save()
    }

    private func addWeekToList(_ weekStart: Date) {
        let cal = Calendar.current
        let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let weekPlans = plans.filter { !$0.deleted && $0.date >= weekStart && $0.date < weekEnd }
        var inputs: [PlanGroceryInput] = []
        for plan in weekPlans {
            guard let rid = plan.recipeId, let recipe = recipesById[rid] else { continue }
            for ing in recipe.ingredients {
                inputs.append(PlanGroceryInput(name: ing.name, quantity: ing.quantity,
                    unit: ing.unit, baseServings: recipe.servings,
                    targetServings: plan.servings, recipeId: rid))
            }
        }
        let lines = aggregateWeekToList(inputs)
        let deviceId = currentDeviceId()
        let list: ShoppingList
        if let existing = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.name == "Weekly shop" && !$0.deleted
        }) {
            list = existing
            for item in list.items { context.delete(item) }
            list.items.removeAll()
        } else {
            list = ShoppingList(householdId: "hh-demo", name: "Weekly shop", deviceId: deviceId)
            context.insert(list)
        }
        for line in lines {
            let qty = line.totalQuantity.map { scaledDisplay(name: "", quantity: $0, unit: line.unit, factor: 1).trimmingCharacters(in: .whitespaces) } ?? ""
            let item = ListItem(listId: list.id, name: line.name, quantity: qty,
                aisle: guessAisle(for: line.name),
                recipeId: line.recipeIds.first, deviceId: deviceId)
            item.shoppingList = list
            context.insert(item)
        }
        try? context.save()
        confirm = "Added \(lines.count) items to Weekly shop"
    }
}

// MARK: - Lists tab (live aisle-sorted lists + check-off)

struct ListsTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\ShoppingList.updatedAt, order: .reverse)])
    private var lists: [ShoppingList]

    var body: some View {
        NavigationStack {
            Group {
                if lists.filter({ !$0.deleted }).isEmpty {
                    ContentUnavailableView("No lists yet", systemImage: "cart",
                        description: Text("Add a week to a list from the Plan tab."))
                } else {
                    ShopListsView(lists: snapshots, onToggle: toggle, onAddItem: addItem)
                        .accessibilityIdentifier("lists-view")
                }
            }
        }
    }

    private var snapshots: [ShoppingListSnapshot] {
        lists.filter { !$0.deleted }.map { list in
            ShoppingListSnapshot(id: list.id, name: list.name, items: list.items.map { item in
                ShopItemSnapshot(id: item.id, name: item.name, quantity: item.quantity,
                    aisle: item.aisle, checked: item.checked, recipeId: item.recipeId)
            })
        }
    }

    private func toggle(listId: String, itemId: String) {
        guard let item = (try? context.fetch(FetchDescriptor<ListItem>()))?.first(where: { $0.id == itemId }) else { return }
        item.checked.toggle()
        try? context.save()
    }

    /// Manually added row: persists a new unchecked `ListItem` on `listId`
    /// with a locally guessed aisle; the list re-renders with the item.
    private func addItem(listId: String, name: String) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let list = (try? context.fetch(FetchDescriptor<ShoppingList>()))?.first(where: {
            $0.id == listId && !$0.deleted
        }) else { return }
        let item = ListItem(listId: listId, name: text, aisle: guessAisle(for: text),
            deviceId: currentDeviceId())
        item.shoppingList = list
        context.insert(item)
        try? context.save()
    }
}

// MARK: - More tab (ingest entry points + library + sync)

struct MoreTabView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Add") {
                    NavigationLink("Clip recipe URL") { ClipView() }
                        .accessibilityIdentifier("more-clip")
                    NavigationLink("Import caption") { CaptionsImportView() }
                        .accessibilityIdentifier("more-caption")
                    NavigationLink("Scan cookbook (OCR)") { OCRScanView() }
                        .accessibilityIdentifier("more-ocr")
                }
                Section("Library") {
                    NavigationLink {
                        PantryTabView()
                    } label: {
                        Label("Pantry", systemImage: "refrigerator")
                    }
                    .accessibilityIdentifier("more-pantry")
                    NavigationLink {
                        MenusTabView()
                    } label: {
                        Label("Menus", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("more-menus")
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .accessibilityIdentifier("more-settings")
                }
                Section("Sync") {
                    SyncStatusRow()
                }
            }
            .navigationTitle("More")
        }
    }
}

// MARK: - Pantry tab (live SwiftData → PantryView snapshots)

struct PantryTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\PantryItem.name)]) private var items: [PantryItem]
    @State private var name = ""
    @State private var location = ""
    @State private var quantity = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Add pantry item", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(addItem)
                Button("Add", action: addItem)
                    .buttonStyle(.bordered)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            PantryView(items: snapshots, onBarcode: insertBarcode)
        }
    }

    private var snapshots: [PantrySnapshot] {
        items.filter { !$0.deleted }.map {
            PantrySnapshot(id: $0.id, name: $0.name, quantity: $0.quantity,
                location: $0.location, expiresAt: $0.expiresAt,
                lowThreshold: $0.lowThreshold, barcode: $0.barcode)
        }
    }

    private func addItem() {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        context.insert(PantryItem(householdId: "hh-demo", name: text,
            quantity: quantity, location: location,
            deviceId: currentDeviceId()))
        try? context.save()
        name = ""; location = ""; quantity = ""
    }

    private func insertBarcode(_ code: String) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let existing = items.first(where: { $0.barcode == text && !$0.deleted }) {
            existing.updatedAt = Date()
        } else {
            context.insert(PantryItem(householdId: "hh-demo", name: text,
                barcode: text, deviceId: currentDeviceId()))
        }
        try? context.save()
    }
}

// MARK: - Menus tab (live SwiftData menus + apply to current week)

struct MenusTabView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Menu.name)]) private var menus: [Menu]
    @State private var name = ""
    @State private var confirm: String?

    var body: some View {
        List {
            if let confirm {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(confirm)
                    }
                }
            }
            Section("New menu") {
                HStack {
                    TextField("Menu name", text: $name)
                        .submitLabel(.done)
                        .onSubmit(createMenu)
                    Button("Create", action: createMenu)
                        .buttonStyle(.bordered)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Menus (\(liveMenus.count))") {
                if liveMenus.isEmpty {
                    Text("No menus yet — name one above. Apply copies its entries into this week's plan.")
                        .foregroundStyle(.secondary)
                }
                ForEach(liveMenus, id: \.id) { menu in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(menu.name).font(.headline)
                            Spacer()
                            Text("\(menu.entries.count) entries")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Apply to this week") { apply(menu) }
                                .buttonStyle(.bordered)
                            Spacer()
                            Button(role: .destructive) { tombstone(menu) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Menus")
    }

    private var liveMenus: [Menu] { menus.filter { !$0.deleted } }

    private func createMenu() {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        context.insert(Menu(householdId: "hh-demo", name: text, deviceId: currentDeviceId()))
        try? context.save()
        name = ""
    }

    private func tombstone(_ menu: Menu) {
        menu.deleted = true
        menu.updatedAt = Date()
        try? context.save()
    }

    private func apply(_ menu: Menu) {
        let start = DemoSeeds.weekStart(containing: Date())
        let cal = Calendar.current
        var count = 0
        for entry in menu.entries {
            guard let day = cal.date(byAdding: .day, value: entry.dayOffset, to: start) else { continue }
            let meal = MealSlot(rawValue: entry.meal) ?? .dinner
            context.insert(Plan(householdId: "hh-demo", date: day, meal: meal,
                recipeId: entry.recipeId.isEmpty ? nil : entry.recipeId,
                servings: entry.servings, deviceId: currentDeviceId()))
            count += 1
        }
        try? context.save()
        confirm = count > 0 ? "Applied \(menu.name): \(count) meals planned" : "\(menu.name) has no entries to apply"
    }
}

// MARK: - Settings (device, counts, sync, BYO backend, E2E)

struct SettingsView: View {
    @Query private var recipes: [Recipe]
    @Query private var lists: [ShoppingList]
    @Query private var plans: [Plan]
    @State private var baseURLString: String = UserDefaults.standard.string(forKey: "smidgen.apiBaseURL") ?? ""
    @State private var token: String = UserDefaults.standard.string(forKey: "smidgen.betaToken") ?? ""
    @State private var syncing = false
    @State private var status: String = ""
    // BYO backend test state
    @State private var healthResult: String = ""
    @State private var testing = false
    // E2E state (thin: identifiers from the Sync layer; the syncCode itself
    // lives only in the Keychain and never surfaces here)
    @State private var householdName: String = E2EKeyStore.loadMetadata()?.householdId ?? "hh-demo"
    @State private var kid: String = E2EKeyStore.loadMetadata()?.kid ?? ""
    @State private var hashPrefix: String = E2EKeyStore.loadMetadata().map { String($0.hash.prefix(8)) } ?? ""
    @State private var inviteBundle: String = ""
    @State private var pasteInput: String = ""
    @State private var joinResult: String = ""
    @State private var showQR = false
    // Pending endpoint hint from the last joined invite bundle. NEVER
    // auto-applied: the user must explicitly confirm AND the hint must pass
    // GET /health before it becomes the backend URL.
    @State private var pendingEndpointHint: String? = nil
    @State private var hintHealthResult: String = ""
    @State private var hintTesting = false

    /// Effective base URL with the locked fallback chain:
    /// UserDefaults smidgen.apiBaseURL (blank = skip) -> Bundle
    /// SMIDGEN_API_BASE_URL -> prod Worker.
    private var effectiveBaseURL: String { SyncConfig.baseURLString }

    var body: some View {
        List {
            Section {
                TextField("API base URL (blank = default)", text: $baseURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                SecureField("Beta token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(syncing ? "Syncing…" : "Save & sync now") {
                    Task { await saveAndSync() }
                }
                .disabled(syncing)
                HStack {
                    Button(testing ? "Testing…" : "Test") {
                        Task { await testHealth() }
                    }
                    .disabled(testing)
                    Spacer()
                    Button("Reset to default") { resetBackend() }
                }
                Text("Using: \(effectiveBaseURL)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if !healthResult.isEmpty {
                    Text(healthResult).font(.caption).foregroundStyle(.secondary)
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Server (BYO backend)")
            } footer: {
                Text("Blank URL = Bundle SMIDGEN_API_BASE_URL, else prod \(SyncConfig.prodBaseURL). Paste the Worker URL printed by scripts/deploy-backend.sh.")
            }
            Section {
                HStack { Text("Household"); Spacer(); Text(householdName).font(.caption.monospaced()).foregroundStyle(.secondary) }
                HStack { Text("Key ID"); Spacer(); Text(kid.isEmpty ? "—" : kid).font(.caption.monospaced()).foregroundStyle(.secondary) }
                HStack { Text("Code hash"); Spacer(); Text(hashPrefix.isEmpty ? "—" : hashPrefix).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Button("Show invite bundle (QR / copy)") {
                    if let json = e2eInviteBundleJSON(householdId: householdName, endpointHint: effectiveBaseURL) {
                        inviteBundle = json
                        refreshE2EState()
                        showQR = true
                    } else {
                        joinResult = "Could not access the Keychain — invite unavailable."
                    }
                }
                .sheet(isPresented: $showQR) {
                    NavigationStack {
                        List {
                            InviteQRImage(payload: inviteBundle)
                                .frame(maxWidth: .infinity, minHeight: 220)
                            Section("Manual copy") {
                                Text(inviteBundle)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Button("Copy bundle") {
                                    #if os(iOS)
                                    UIPasteboard.general.string = inviteBundle
                                    #endif
                                }
                            }
                            Section {
                                Text("Send this to your second device out-of-band (Messages, Mail, AirDrop). It holds householdId, syncCode, kid, hash, and endpointHint.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .navigationTitle("Invite bundle")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showQR = false }
                            }
                        }
                    }
                }
                TextField("Paste invite bundle to join", text: $pasteInput, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                Button("Join with bundle") { joinWithBundle() }
                    .disabled(pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !joinResult.isEmpty {
                    Text(joinResult).font(.caption).foregroundStyle(.secondary)
                }
                if let hint = pendingEndpointHint {
                    Section("Suggested server (from invite)") {
                        Text(hint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                        Text("This came from the invite bundle — it is not your server until you confirm it. Confirming checks GET /health first.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(hintTesting ? "Checking…" : "Test & use this server") {
                                Task { await confirmEndpointHint() }
                            }
                            .disabled(hintTesting)
                            Spacer()
                            Button("Keep current server") { dismissEndpointHint() }
                                .disabled(hintTesting)
                        }
                        if !hintHealthResult.isEmpty {
                            Text(hintHealthResult).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("End-to-end encryption")
            } footer: {
                Text("Keep Cooking can't see or recover your recipes. Lose code+devices = permanent loss. Got a new phone or iPad? Add it now while you still have this one — open Settings here on both devices.")
            }
            Section("Sync") {
                SyncStatusRow()
            }
            Section("Library") {
                HStack { Text("Recipes"); Spacer(); Text("\(recipes.filter { !$0.deleted }.count)").foregroundStyle(.secondary) }
                HStack { Text("Shopping lists"); Spacer(); Text("\(lists.filter { !$0.deleted }.count)").foregroundStyle(.secondary) }
                HStack { Text("Planned meals"); Spacer(); Text("\(plans.filter { !$0.deleted }.count)").foregroundStyle(.secondary) }
                HStack {
                    Text("Endpoint")
                    Spacer()
                    Text(SyncConfig.baseURLString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Section("Device") {
                HStack {
                    Text("Device ID")
                    Spacer()
                    Text(ShortDevice.id).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Section("About") {
                Text("Keep Cooking \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") — offline-first, MIT.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }

    private func saveAndSync() async {
        syncing = true
        defer { syncing = false }
        UserDefaults.standard.set(baseURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "smidgen.apiBaseURL")
        UserDefaults.standard.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "smidgen.betaToken")
        await SyncCoordinator.shared.sync()
        status = await SyncCoordinator.shared.describe()
    }

    /// GET <base>/health against the typed URL (blank = effective default).
    private func testHealth() async {
        testing = true
        defer { testing = false }
        let typed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = typed.isEmpty ? effectiveBaseURL : typed
        guard let url = URL(string: base + "/health") else {
            healthResult = "Bad URL — check the backend field."
            return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            healthResult = code == 200 ? "Healthy (\(code)): \(body.prefix(120))"
                : "Unhealthy (HTTP \(code)): \(body.prefix(120))"
        } catch {
            healthResult = "Unreachable: \(error.localizedDescription)"
        }
    }

    private func resetBackend() {
        UserDefaults.standard.removeObject(forKey: "smidgen.apiBaseURL")
        baseURLString = ""
        healthResult = "Reset — using \(effectiveBaseURL)."
    }

    private func joinWithBundle() {
        do {
            let res = try e2eJoin(pasted: pasteInput)
            kid = res.kid
            hashPrefix = res.hashPrefix8
            householdName = res.householdId
            // SECURITY: never auto-apply the invite's endpointHint. An
            // attacker-controlled bundle must not silently redirect this
            // device's backend. Stage it for explicit user confirmation +
            // GET /health validation instead (see pendingEndpointHint UI).
            if let hint = res.endpointHint?.trimmingCharacters(in: .whitespacesAndNewlines),
               !hint.isEmpty, hint != baseURLString, hint != effectiveBaseURL {
                pendingEndpointHint = hint
                hintHealthResult = ""
                joinResult = "Joined household \(res.householdId) — kid \(res.kid) · hash \(res.hashPrefix8). Verify the hash matches the other device. The invite suggests a server below — review it before switching."
            } else {
                pendingEndpointHint = nil
                hintHealthResult = ""
                joinResult = "Joined household \(res.householdId) — kid \(res.kid) · hash \(res.hashPrefix8). Verify the hash matches the other device."
            }
            pasteInput = ""
        } catch {
            joinResult = error.localizedDescription
        }
    }

    /// Confirmed adoption of the staged endpoint hint: validates
    /// GET <hint>/health, then — and only then — persists the hint as the
    /// backend URL. Requires explicit user action; never called implicitly.
    private func confirmEndpointHint() async {
        let rawHint = pendingEndpointHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawHint.isEmpty else {
            hintHealthResult = "Invalid server URL — keeping current server."
            return
        }
        // Normalize: a hint ending in "/" would otherwise probe "<hint>//health".
        var hint = rawHint
        while hint.hasSuffix("/") && hint.count > 1 { hint = String(hint.dropLast()) }
        guard let hintURL = URL(string: hint),
              let scheme = hintURL.scheme?.lowercased(),
              let host = hintURL.host?.lowercased(),
              URL(string: hint + "/health") != nil
        else {
            hintHealthResult = "Invalid server URL — keeping current server."
            return
        }
        // SECURITY: the beta bearer token is sent to this server, so a
        // cleartext http:// hint would leak it on the wire. Require HTTPS,
        // except explicitly local dev targets (localhost / 127.0.0.1 / *.local).
        let isLocalDev = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        guard scheme == "https" || (scheme == "http" && isLocalDev) else {
            hintHealthResult = "Invite server must use HTTPS (http:// is only allowed for localhost / 127.0.0.1 / *.local dev servers) — keeping current server."
            return
        }
        let healthURL = URL(string: hint + "/health")!
        hintTesting = true
        defer { hintTesting = false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: healthURL)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                hintHealthResult = "Server rejected (HTTP \(code)): \(body.prefix(120)) — keeping current server."
                return
            }
            // A second invite may have been joined while the health check was
            // in flight: only apply when the staged hint is still the one probed.
            let current: String? = pendingEndpointHint.map { pending in
                var normalized = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                while normalized.hasSuffix("/") && normalized.count > 1 { normalized = String(normalized.dropLast()) }
                return normalized
            }
            guard current == hint else {
                hintHealthResult = "A newer invite arrived — review the suggested server again before switching."
                return
            }
            baseURLString = hint
            UserDefaults.standard.set(hint, forKey: "smidgen.apiBaseURL")
            pendingEndpointHint = nil
            hintHealthResult = ""
            joinResult = "Server updated — now using \(hint)."
        } catch {
            hintHealthResult = "Unreachable: \(error.localizedDescription) — keeping current server."
        }
    }

    private func dismissEndpointHint() {
        pendingEndpointHint = nil
        hintHealthResult = ""
    }

    /// Re-reads Keychain/UserDefaults identifiers into the displayed state.
    private func refreshE2EState() {
        if let meta = E2EKeyStore.loadMetadata() {
            kid = meta.kid
            hashPrefix = String(meta.hash.prefix(8))
            householdName = meta.householdId
        } else {
            kid = ""
            hashPrefix = ""
            householdName = "hh-demo"
        }
    }
}

private enum ShortDevice {
    static var id: String {
        #if os(iOS)
        UIDevice.current.identifierForVendor?.uuidString ?? "simulator"
        #else
        "mac"
        #endif
    }
}

// MARK: - Demo plan seeding (current week, idempotent)

enum DemoSeeds {
    static func weekStart(containing date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    /// Ensures Mon/Wed/Fri dinner plans exist for the current week so the
    /// plan→list video is deterministic. Skips entries already present.
    static func seedDemoPlans(context: ModelContext, deviceId: String) {
        let recipes = ((try? context.fetch(
            FetchDescriptor<Recipe>(sortBy: [SortDescriptor(\Recipe.title)]))) ?? [])
            .filter { !$0.deleted }
        guard recipes.count >= 3 else { return }
        let cal = Calendar.current
        let start = weekStart(containing: Date())
        let picks: [(dayOffset: Int, meal: MealSlot)] = [
            (0, .dinner), (2, .dinner), (4, .dinner),
        ]
        let existing = (try? context.fetch(FetchDescriptor<Plan>())) ?? []
        for (i, pick) in picks.enumerated() {
            guard let day = cal.date(byAdding: .day, value: pick.dayOffset, to: start) else { continue }
            let recipe = recipes[i % recipes.count]
            let dayStart = cal.startOfDay(for: day)
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? day
            let dup = existing.contains {
                !$0.deleted && $0.date >= dayStart && $0.date < dayEnd
                    && $0.mealRaw == pick.meal.rawValue && $0.recipeId == recipe.id
            }
            if dup { continue }
            context.insert(Plan(householdId: "hh-demo", date: day, meal: pick.meal,
                recipeId: recipe.id, servings: recipe.servings, deviceId: deviceId))
        }
        try? context.save()
    }
}

private func currentDeviceId() -> String {
    #if os(iOS)
    return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    #else
    return UUID().uuidString
    #endif
}
