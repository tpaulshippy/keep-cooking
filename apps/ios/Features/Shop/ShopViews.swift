// Smidgen — Lane 4 Shop/Pantry: multi-list aisle-sorted views + pantry
// Consumes Core ShoppingList/ListItem/PantryItem via snapshots (no new
// persistence, no auth/sync changes). iPad-compatible: NavigationStack
// content for the Lane 2 PadSplitView; pantry gets a two-column grid under
// .regular size class.

import SwiftUI

// MARK: - Snapshots

public struct ShopItemSnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var quantity: String
    public var aisle: String
    public var checked: Bool
    public var recipeId: String?
    public init(id: String, name: String, quantity: String = "",
                aisle: String = "", checked: Bool = false, recipeId: String? = nil) {
        self.id = id; self.name = name; self.quantity = quantity
        self.aisle = aisle; self.checked = checked; self.recipeId = recipeId
    }
}

public struct ShoppingListSnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var items: [ShopItemSnapshot]
    public init(id: String, name: String, items: [ShopItemSnapshot] = []) {
        self.id = id; self.name = name; self.items = items
    }
}

public struct PantrySnapshot: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var quantity: String
    public var location: String
    public var expiresAt: Date?
    public var lowThreshold: String
    public var barcode: String
    public init(id: String, name: String, quantity: String = "", location: String = "",
                expiresAt: Date? = nil, lowThreshold: String = "", barcode: String = "") {
        self.id = id; self.name = name; self.quantity = quantity
        self.location = location; self.expiresAt = expiresAt
        self.lowThreshold = lowThreshold; self.barcode = barcode
    }
}

// MARK: - Shopping lists (aisle-sorted, check-off)

/// Multi-list view: each list groups unchecked items under aisle-sorted
/// Section headers, shows an "X of Y left" progress header, and keeps
/// checked items collapsible. `onToggle(listId:itemId:)` persists the flip
/// via the caller's SwiftData context. `onAddItem(listId:name:)` persists a
/// manually added row (nil = add row hidden).
public struct ShopListsView: View {
    private let lists: [ShoppingListSnapshot]
    var onToggle: ((String, String) -> Void)?
    var onAddRecipeToList: ((String) -> Void)? // recipeId -> scaled add sheet
    var onAddItem: ((String, String) -> Void)? // (listId, name) -> insert item
    @State private var collapsedChecked: Set<String> = []
    @State private var drafts: [String: String] = [:]

    public init(lists: [ShoppingListSnapshot],
                onToggle: ((String, String) -> Void)? = nil,
                onAddRecipeToList: ((String) -> Void)? = nil,
                onAddItem: ((String, String) -> Void)? = nil) {
        self.lists = lists; self.onToggle = onToggle
        self.onAddRecipeToList = onAddRecipeToList; self.onAddItem = onAddItem
    }

    public var body: some View {
        Group {
            if lists.isEmpty {
                ContentUnavailableView("No lists yet", systemImage: "cart",
                    description: Text("Add a week to a list from the Plan tab."))
            } else {
                List {
                    ForEach(lists) { list in
                        listProgressSection(for: list)
                        ForEach(uncheckedAisles(in: list), id: \.self) { aisle in
                            Section(aisleHeader(for: aisle)) {
                                ForEach(uncheckedItems(in: list, aisle: aisle)) { item in
                                    itemRow(listId: list.id, item: item)
                                }
                            }
                        }
                        if !checkedItems(in: list).isEmpty {
                            Section {
                                DisclosureGroup(isExpanded: checkedBinding(for: list.id)) {
                                    ForEach(checkedItems(in: list)) { item in
                                        itemRow(listId: list.id, item: item)
                                    }
                                } label: {
                                    Text("Checked (\(checkedItems(in: list).count))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        } else if list.items.isEmpty {
                            Section {
                                Text(onAddItem == nil ? "Nothing here yet." : "Nothing here yet — add the first item below.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if onAddItem != nil {
                            Section {
                                HStack {
                                    TextField("Add item", text: draftBinding(for: list.id))
                                        .textInputAutocapitalization(.words)
                                        .submitLabel(.done)
                                        .onSubmit { submitDraft(for: list.id) }
                                    Button("Add") { submitDraft(for: list.id) }
                                        .buttonStyle(.bordered)
                                        .disabled(draftText(for: list.id)
                                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                    }
                }
                // Bottom scroll inset so the last rows clear the floating tab bar.
                .contentMargins(.bottom, 48, for: .scrollContent)
            }
        }
        .navigationTitle("Shopping lists")
        .safeAreaPadding(.bottom, 8)
    }

    // MARK: Sections

    private func listProgressSection(for list: ShoppingListSnapshot) -> some View {
        let total = list.items.count
        let left = list.items.filter { !$0.checked }.count
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(list.name).font(.headline)
                    Spacer()
                    Text("\(left) of \(total) left")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if total > 0 {
                    ProgressView(value: Double(total - left), total: Double(total))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func itemRow(listId: String, item: ShopItemSnapshot) -> some View {
        Button { onToggle?(listId, item.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.checked ? .green : .secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .strikethrough(item.checked)
                        .foregroundStyle(item.checked ? .secondary : .primary)
                    if !item.quantity.isEmpty {
                        Text(item.quantity)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: Grouping (aisle-sorted via aisleSortKey)

    private func uncheckedAisles(in list: ShoppingListSnapshot) -> [String] {
        let items = list.items.filter { !$0.checked }
        return aisleGroupedNames(items: items, aisleOf: { $0.aisle }, nameOf: { $0.name })
    }

    private func uncheckedItems(in list: ShoppingListSnapshot, aisle: String) -> [ShopItemSnapshot] {
        let key = normalizedAisleKey(aisle)
        return list.items.filter { !$0.checked && normalizedAisleKey($0.aisle) == key }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func checkedItems(in list: ShoppingListSnapshot) -> [ShopItemSnapshot] {
        list.items.filter { $0.checked }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func aisleHeader(for aisle: String) -> String {
        let trimmed = aisle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Other" : trimmed.capitalized
    }

    private func checkedBinding(for listId: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedChecked.contains(listId) },
            set: {
                if $0 { collapsedChecked.remove(listId) }
                else { collapsedChecked.insert(listId) }
            })
    }

    private func draftText(for listId: String) -> String { drafts[listId] ?? "" }

    private func draftBinding(for listId: String) -> Binding<String> {
        Binding(get: { drafts[listId] ?? "" }, set: { drafts[listId] = $0 })
    }

    private func submitDraft(for listId: String) {
        let text = draftText(for: listId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAddItem?(listId, text)
        drafts[listId] = ""
    }

    // Kept for callers that sort a flat item array (unchecked first, then aisle).
    func sortedItems(_ items: [ShopItemSnapshot]) -> [ShopItemSnapshot] {
        items.sorted {
            let kl = aisleSortKey(aisle: $0.aisle, name: $0.name)
            let kr = aisleSortKey(aisle: $1.aisle, name: $1.name)
            if $0.checked != $1.checked { return !$0.checked } // unchecked first
            if kl.0 != kr.0 { return kl.0 < kr.0 }
            if kl.1 != kr.1 { return kl.1 < kr.1 }
            return kl.2 < kr.2
        }
    }
}

// MARK: - Recipe -> list (scaled)

/// Adds one recipe's ingredients to a list, scaled to `targetServings`.
/// Pure helper so the sheet + tests share logic.
public func recipeLinesToList(inputs: [PlanGroceryInput]) -> [AggregatedItem] {
    aggregateWeekToList(inputs)
}

// MARK: - Pantry (locations + expiry + low-stock + barcode)

public struct PantryView: View {
    private let items: [PantrySnapshot]
    @State private var showScanner = false
    var onBarcode: ((String) -> Void)?

    public init(items: [PantrySnapshot], onBarcode: ((String) -> Void)? = nil) {
        self.items = items; self.onBarcode = onBarcode
    }

    public var body: some View {
        List {
            Section("Needs attention") {
                ForEach(flaggedItems) { item in
                    pantryRow(item)
                }
                if flaggedItems.isEmpty {
                    Text("Nothing expiring or low.").foregroundStyle(.secondary)
                }
            }
            Section("All") {
                ForEach(sortedRest) { item in
                    pantryRow(item)
                }
            }
        }
        .navigationTitle("Pantry")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showScanner = true } label: {
                    Label("Scan", systemImage: "barcode.viewfinder")
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            BarcodeScannerStub { code in onBarcode?(code) }
        }
    }

    private var flaggedItems: [PantrySnapshot] {
        items.filter {
            expiryStatus(expiresAt: $0.expiresAt) != .fresh
                && expiryStatus(expiresAt: $0.expiresAt) != .noDate
                || isLowStock(quantity: $0.quantity, threshold: $0.lowThreshold)
        }
    }

    private var sortedRest: [PantrySnapshot] {
        items.sorted {
            if $0.location.lowercased() != $1.location.lowercased() {
                return $0.location.lowercased() < $1.location.lowercased()
            }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    private func pantryRow(_ item: PantrySnapshot) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(item.name).font(.headline)
                HStack(spacing: 6) {
                    if !item.location.isEmpty {
                        Text(item.location).font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.quantity.isEmpty {
                        Text(item.quantity).font(.caption).foregroundStyle(.secondary)
                    }
                    if isLowStock(quantity: item.quantity, threshold: item.lowThreshold) {
                        Text("Low").font(.caption.bold()).foregroundStyle(.orange)
                    }
                    switch expiryStatus(expiresAt: item.expiresAt) {
                    case .expired:
                        Text("Expired").font(.caption.bold()).foregroundStyle(.red)
                    case .expiringSoon:
                        Text("Expiring soon").font(.caption.bold()).foregroundStyle(.orange)
                    case .fresh, .noDate:
                        EmptyView()
                    }
                }
            }
            Spacer()
        }
    }
}
