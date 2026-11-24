// Smidgen — PASS 2 demos
// apps/ios/App/DemoFlows.swift
//
// Wires the Lane 3/4 snapshot views (Clip/Caption/OCR, Plan, Shop, Cook)
// to live SwiftData so the three demo videos record the REAL app offline:
//   1. offline-launch — seeded recipes list with no backend configured.
//   2. ingest-save — OCRScanView: paste text → Parse → Save (fully local).
//   3. plan-to-list — PlanView week → "Add week to list" aggregates into an
//      aisle-sorted ShoppingList → check-off; cook mode reachable from detail.
//
// Accessibility identifiers (used by SmidgenUITests):
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

struct RecipeLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Recipe> { !$0.deleted },
           sort: [SortDescriptor(\Recipe.title)])
    private var recipes: [Recipe]
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil

    private var allCategories: [String] {
        Array(Set(recipes.flatMap { $0.categories })).sorted()
    }

    private var filtered: [Recipe] {
        // Single source of truth for search behavior — see LibrarySearch.swift.
        // A selection whose category vanished (e.g. last recipe deleted) is
        // ignored so the list can't strand on an empty "No results" state.
        let categories = selectedCategory.flatMap { sel in
            allCategories.contains(sel) ? [sel] : nil
        } ?? []
        return filterRecipes(recipes, filter: AdvancedFilter(
            query: searchText, categories: categories))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !allCategories.isEmpty {
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
                Group {
                    if recipes.isEmpty {
                        VStack(spacing: 8) {
                            ContentUnavailableView("No recipes yet", systemImage: "book.pages",
                                description: Text("Seeds load on first launch — airplane mode works."))
                            ActionsCTA()
                        }
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        List {
                            ForEach(filtered, id: \.id) { recipe in
                                NavigationLink {
                                    RecipeDetailView(recipe: recipe)
                                } label: {
                                    HStack(spacing: 12) {
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
                            }
                            .onDelete(perform: tombstone)
                        }
                        .listStyle(.insetGrouped)
                        .contentMargins(.bottom, 90, for: .scrollContent)
                        .safeAreaPadding(.bottom, 8)
                        .accessibilityIdentifier("recipe-list")
                    }
                }
            }
            .navigationTitle("Recipes")
            .searchable(text: $searchText, prompt: "Search recipes")
            .toolbar(content: {
                ToolbarItem(placement: .topBarTrailing) {
                    SwiftUI.Menu(content: {
                        NavigationLink(destination: ClipView()) {
                            Text("Clip recipe URL")
                        }
                        NavigationLink(destination: OCRScanView()) {
                            Text("Scan cookbook (OCR)")
                        }
                    }, label: {
                        Image(systemName: "plus")
                            .accessibilityIdentifier("add-recipe-button")
                    })
                }
            })
        }
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
        List {
            // Photo hero
            Section {
                heroHeader
            }
            .listRowInsets(EdgeInsets())
            // Meta row — Serves label never compresses: fixedSize + layoutPriority
            // keep "Serves 4" on one line; time/rating hug trailing edge.
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Serves \(servingsDisplay)")
                            .font(.subheadline)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(2)
                            .accessibilityLabel("Serves \(servingsDisplay)")
                        Stepper("", value: $servings, in: 1...24, step: 1)
                            .labelsHidden()
                            .fixedSize()
                            .layoutPriority(1)
                            .accessibilityLabel("Servings")
                        Spacer(minLength: 8)
                        if let total = totalMinutes {
                            Label("\(total) min", systemImage: "clock")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                        }
                        if let rating = recipe.rating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                        }
                    }
                    if !recipe.categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(recipe.categories, id: \.self) { cat in
                                    Text(cat).font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            }
            Section("Ingredients (\(sortedIngredients.count))") {
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
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Steps (\(sortedSteps.count))") {
                ForEach(Array(sortedSteps.enumerated()), id: \.element.id) { idx, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Circle())
                        Text(step.text)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                NavigationLink {
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
                } label: {
                    Label("Cook", systemImage: "frying.pan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("cook-button")
                Button {
                    addToList()
                } label: {
                    Label("Add to shopping list", systemImage: "cart.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("add-to-list-button")
            }
            // Confirmation sits directly under the button that triggers it.
            if let addedMessage {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(addedMessage).foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("added-confirm")
                }
            }
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("recipe-detail-title")
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
                        .frame(height: 220).clipped()
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
                .frame(height: 140)
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.9))
        }
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
            context.insert(ListItem(listId: list.id, name: line.name,
                quantity: line.totalQuantity.map { String(format: "%.2g", $0) } ?? "",
                aisle: guessAisle(for: line.name), deviceId: deviceId))
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
                Text("Smidgen can't see or recover your recipes. Lose code+devices = permanent loss. Got a new phone or iPad? Add it now while you still have this one — open Settings here on both devices.")
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
                Text("Smidgen \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") — offline-first, MIT.")
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
        guard let hint = pendingEndpointHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty,
              let url = URL(string: hint + "/health"),
              let scheme = URL(string: hint)?.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            hintHealthResult = "Invalid server URL — keeping current server."
            return
        }
        hintTesting = true
        defer { hintTesting = false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                hintHealthResult = "Server rejected (HTTP \(code)): \(body.prefix(120)) — keeping current server."
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
