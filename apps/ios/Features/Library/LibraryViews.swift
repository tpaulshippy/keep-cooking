// Keep Cooking — Lane 5 Organize
// apps/ios/Features/Library/LibraryViews.swift
//
// Library UI: categories, cookbooks, full-text + advanced search with saved
// searches, and the fuzzy duplicate review flow. Every button performs a
// real action (insert/delete/merge/persist) — no placeholders.

import SwiftUI
import SwiftData

// MARK: - Library home

/// Entry point for the Library tab. Sections: Search, Categories, Cookbooks,
/// Duplicates (badge = group count), Saved searches.
public struct LibraryHomeView: View {
    @Query(filter: #Predicate<Recipe> { !$0.deleted },
           sort: [SortDescriptor(\Recipe.title)])
    private var recipes: [Recipe]
    @Query(sort: [SortDescriptor(\Cookbook.name)])
    private var cookbooks: [Cookbook]
    @Query(sort: [SortDescriptor(\SavedSearch.createdAt, order: .reverse)])
    private var savedSearches: [SavedSearch]

    public init() {}

    private var duplicateGroups: [[Recipe]] { findDuplicateGroups(recipes) }

    private var allCategories: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for r in recipes {
            for c in r.categories {
                let key = c.lowercased()
                counts[key, default: 0] += 1
                display[key] = display[key] ?? c
            }
        }
        return counts.map { (display[$0.key] ?? $0.key, $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Find") {
                    NavigationLink {
                        LibrarySearchView(recipes: recipes)
                    } label: {
                        Label("Search recipes", systemImage: "magnifyingglass")
                    }
                    NavigationLink {
                        DuplicateReviewView(recipes: recipes)
                    } label: {
                        Label {
                            HStack {
                                Text("Duplicates")
                                Spacer()
                                if !duplicateGroups.isEmpty {
                                    Text("\(duplicateGroups.count)")
                                        .font(.caption).padding(6)
                                        .background(.orange.opacity(0.2)).clipShape(Capsule())
                                }
                            }
                        } icon: { Image(systemName: "square.stack.3d.up") }
                    }
                }
                Section("Categories") {
                    if allCategories.isEmpty {
                        Text("No categories yet — add one from a search.").foregroundStyle(.secondary)
                    }
                    ForEach(allCategories, id: \.name) { cat in
                        NavigationLink {
                            LibrarySearchView(recipes: recipes, initialFilter: AdvancedFilter(categories: [cat.name]))
                        } label: {
                            HStack { Text(cat.name); Spacer(); Text("\(cat.count)").foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("Cookbooks") {
                    ForEach(cookbooks.filter { !$0.deleted }, id: \.id) { book in
                        NavigationLink {
                            CookbookDetailView(cookbook: book, recipes: recipes)
                        } label: {
                            HStack {
                                Text(book.name)
                                Spacer()
                                Text("\(book.recipeIds.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        CookbookEditView(recipes: recipes)
                    } label: {
                        Label("New cookbook", systemImage: "plus")
                    }
                }
                if !savedSearches.isEmpty {
                    Section("Saved searches") {
                        ForEach(savedSearches, id: \.id) { saved in
                            if let filter = saved.filter {
                                NavigationLink {
                                    LibrarySearchView(recipes: recipes, initialFilter: filter)
                                } label: {
                                    Label(saved.name, systemImage: "bookmark")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
        }
    }
}

// MARK: - Search view

public struct LibrarySearchView: View {
    let recipes: [Recipe]
    @Environment(\.modelContext) private var context
    @State private var filter: AdvancedFilter
    @State private var showAdvanced = false
    @State private var saveName = ""
    @State private var showSave = false

    public init(recipes: [Recipe], initialFilter: AdvancedFilter = AdvancedFilter()) {
        self.recipes = recipes
        _filter = State(initialValue: initialFilter)
    }

    private var results: [Recipe] { filterRecipes(recipes, filter: filter) }

    public var body: some View {
        List {
            Section {
                TextField("Search title, ingredient, category…", text: $filter.query)
                Toggle("Advanced filters", isOn: $showAdvanced)
                if showAdvanced {
                    AdvancedFilterForm(filter: $filter)
                }
            }
            Section("Results (\(results.count))") {
                if results.isEmpty {
                    Text("No matches. Loosen a filter.").foregroundStyle(.secondary)
                }
                ForEach(results, id: \.id) { recipe in
                    VStack(alignment: .leading) {
                        Text(recipe.title).font(.headline)
                        Text(summaryLine(recipe)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("Save this search") { showSave = true }
                    .disabled(filter.isEmpty)
            }
        }
        .navigationTitle("Search")
        .alert("Name this search", isPresented: $showSave) {
            TextField("e.g. Quick vegetarian dinners", text: $saveName)
            Button("Save") {
                let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                context.insert(SavedSearch(name: name, filter: filter))
                try? context.save()
                saveName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func summaryLine(_ r: Recipe) -> String {
        var bits: [String] = []
        if let t = r.totalMinutes { bits.append("\(t) min") }
        if let rating = r.rating { bits.append(String(format: "★ %.1f", rating)) }
        if !r.source.isEmpty { bits.append(r.source) }
        if !r.categories.isEmpty { bits.append(r.categories.joined(separator: ", ")) }
        return bits.joined(separator: " · ")
    }
}

public struct AdvancedFilterForm: View {
    @Binding var filter: AdvancedFilter
    @State private var includeText = ""
    @State private var excludeText = ""

    public init(filter: Binding<AdvancedFilter>) { _filter = filter }

    public var body: some View {
        Group {
            TextField("Must include (comma-separated)", text: $includeText, onCommit: commitTerms)
            TextField("Must exclude (comma-separated)", text: $excludeText, onCommit: commitTerms)
            if !filter.includeTerms.isEmpty {
                Text("Including: \(filter.includeTerms.joined(separator: ", "))").font(.caption)
            }
            if !filter.excludeTerms.isEmpty {
                Text("Excluding: \(filter.excludeTerms.joined(separator: ", "))").font(.caption)
            }
            HStack {
                Text("Max time")
                Spacer()
                Picker("Max time", selection: $filter.maxTotalMinutes) {
                    Text("Any").tag(nil as Int?)
                    Text("15 min").tag(15 as Int?)
                    Text("30 min").tag(30 as Int?)
                    Text("60 min").tag(60 as Int?)
                }.pickerStyle(.menu)
            }
            HStack {
                Text("Min rating")
                Spacer()
                Picker("Min rating", selection: $filter.minRating) {
                    Text("Any").tag(nil as Double?)
                    Text("3+").tag(3.0 as Double?)
                    Text("4+").tag(4.0 as Double?)
                    Text("4.5+").tag(4.5 as Double?)
                }.pickerStyle(.menu)
            }
            TextField("Source contains…", text: Binding(
                get: { filter.sourceContains ?? "" },
                set: { filter.sourceContains = $0.isEmpty ? nil : $0 }
            ))
            Button("Clear all filters") {
                filter = AdvancedFilter(query: filter.query)
                includeText = ""; excludeText = ""
            }.disabled(filter.includeTerms.isEmpty && filter.excludeTerms.isEmpty
                && filter.maxTotalMinutes == nil && filter.minRating == nil
                && (filter.sourceContains ?? "").isEmpty && filter.categories.isEmpty)
        }
        .onAppear {
            includeText = filter.includeTerms.joined(separator: ", ")
            excludeText = filter.excludeTerms.joined(separator: ", ")
        }
    }

    private func commitTerms() {
        filter.includeTerms = includeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        filter.excludeTerms = excludeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Cookbooks

public struct CookbookEditView: View {
    let recipes: [Recipe]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedIds = Set<String>()
    @State private var householdId = "hh-demo"

    public init(recipes: [Recipe]) { self.recipes = recipes }

    public var body: some View {
        Form {
            TextField("Cookbook name", text: $name)
            TextField("Household id", text: $householdId)
            Section("Recipes (\(selectedIds.count) selected)") {
                ForEach(recipes, id: \.id) { r in
                    Button {
                        if selectedIds.contains(r.id) { selectedIds.remove(r.id) } else { selectedIds.insert(r.id) }
                    } label: {
                        HStack {
                            Text(r.title)
                            Spacer()
                            if selectedIds.contains(r.id) { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Create cookbook") {
                let book = Cookbook(householdId: householdId, name: name.isEmpty ? "Untitled" : name,
                                    recipeIds: Array(selectedIds),
                                    deviceId: currentDeviceId())
                context.insert(book)
                try? context.save()
                dismiss()
            }
        }
        .navigationTitle("New cookbook")
    }

    private func currentDeviceId() -> String {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }
}

public struct CookbookDetailView: View {
    @Bindable var cookbook: Cookbook
    let recipes: [Recipe]
    @Environment(\.modelContext) private var context

    public init(cookbook: Cookbook, recipes: [Recipe]) {
        self.cookbook = cookbook
        self.recipes = recipes
    }

    private var members: [Recipe] {
        let ids = Set(cookbook.recipeIds)
        return recipes.filter { ids.contains($0.id) }
    }

    public var body: some View {
        List {
            Section("Recipes") {
                if members.isEmpty {
                    Text("No recipes in this cookbook yet.").foregroundStyle(.secondary)
                }
                ForEach(members, id: \.id) { r in
                    HStack {
                        Text(r.title)
                        Spacer()
                        Button { removeFromCookbook(r) } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.plain)
                    }
                }
            }
            Section("Share") {
                NavigationLink {
                    CookbookShareView(cookbook: cookbook)
                } label: {
                    Label("Share cookbook link", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(cookbook.name)
    }

    private func removeFromCookbook(_ r: Recipe) {
        cookbook.recipeIds = cookbook.recipeIds.filter { $0 != r.id }
        cookbook.updatedAt = Date()
        try? context.save()
    }
}

// MARK: - Duplicate review + merge

public struct DuplicateReviewView: View {
    let recipes: [Recipe]
    @Environment(\.modelContext) private var context
    @State private var dismissedKeys: Set<String> = Set(
        (UserDefaults.standard.stringArray(forKey: "smidgen.dismissedDupeGroups") ?? []))

    public init(recipes: [Recipe]) { self.recipes = recipes }

    private var groups: [[Recipe]] {
        findDuplicateGroups(recipes).filter { !dismissedKeys.contains(groupKey($0)) }
    }

    private func groupKey<R: DuplicableRecipe>(_ group: [R]) -> String {
        group.map { $0.recipeId }.sorted().joined(separator: "+")
    }

    public var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "checkmark.circle",
                    description: Text("Fuzzy matching found no duplicate recipes."))
            }
            ForEach(groups.indices, id: \.self) { i in
                Section("Group \(i + 1)") {
                    ForEach(groups[i], id: \.id) { r in
                        VStack(alignment: .leading) {
                            Text(r.title).font(.headline)
                            Text("\(r.ingredientNames.count) ingredients · \(r.stepTexts.count) steps · \(r.photoOriginal ?? "no photo")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let plan = planMerge(group: groups[i]) {
                        Button("Merge into best (\(plan.survivorTitle))") {
                            applyMerge(plan: plan)
                        }
                    }
                    Button("Keep both (not duplicates)") {
                        dismissedKeys.insert(groupKey(groups[i]))
                        UserDefaults.standard.set(Array(dismissedKeys), forKey: "smidgen.dismissedDupeGroups")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Duplicates")
    }

    /// Applies a merge plan: survivor absorbs union ingredients/categories,
    /// best photo and best rating; losers are tombstoned (sync-safe delete).
    private func applyMerge(plan: DuplicateMergePlan) {
        let byId = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        guard let survivor = byId[plan.survivorId] else { return }
        survivor.categories = plan.mergedCategories
        if let best = plan.bestPhotoOriginal { survivor.photoOriginal = best }
        if let thumb = plan.bestPhotoThumb { survivor.photoThumb = thumb }
        if let rating = plan.bestRating { survivor.rating = rating }
        survivor.updatedAt = Date()
        // Union ingredients: append missing (case-insensitive) as new rows.
        let have = Set(survivor.ingredients.map { ($0.display.isEmpty ? $0.name : $0.display).lowercased() })
        var position = (survivor.ingredients.map { $0.position }.max() ?? -1) + 1
        for name in plan.mergedIngredientNames where !have.contains(name.lowercased()) {
            let ing = Ingredient(recipeId: survivor.id, name: name, display: name,
                                 position: position, updatedAt: Date(), deviceId: survivor.deviceId)
            ing.recipe = survivor
            context.insert(ing)
            position += 1
        }
        for id in plan.absorbedIds {
            byId[id]?.deleted = true
            byId[id]?.updatedAt = Date()
        }
        try? context.save()
    }
}
