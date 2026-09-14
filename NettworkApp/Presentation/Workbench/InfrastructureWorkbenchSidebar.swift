import NetworkModel
import SwiftUI

struct InfrastructureWorkbenchSidebar: View {
    @Bindable var inventory: InventoryExploreModel
    @Bindable var router: AppRouter
    let onSelect: (ObjectID) -> Void
    @State private var browseTools = false
    @State private var filtersPresented = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $browseTools) {
                Text("Inventory").tag(false)
                Text("Workspace").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(NettworkSpacing.standard)
            .accessibilityIdentifier("workbench.sidebar-mode")

            if browseTools {
                List(selection: $router.selectedSection) {
                    WorkspaceNavigationRows()
                }
                .listStyle(.sidebar)
            } else {
                inventoryList
            }
        }
        .navigationTitle("Nettwork")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        .sheet(isPresented: $filtersPresented) {
            InventoryFilterSheet(model: inventory, identifierPrefix: "workbench")
        }
        .onChange(of: router.selectedSection) { _, section in
            if section == .explore {
                browseTools = false
            } else if let section, WorkbenchObjectMode(section: section) == nil {
                browseTools = true
            }
        }
        .accessibilityIdentifier("workbench.inventory-sidebar")
    }

    private var inventoryList: some View {
        List(selection: selectionBinding) {
            Section {
                Button {
                    filtersPresented = true
                } label: {
                    HStack {
                        Label("Filter inventory", systemImage: "line.3.horizontal.decrease")
                        Spacer()
                        if activeFilterCount > 0 {
                            Text(activeFilterCount.formatted()).font(.caption.monospacedDigit())
                        }
                    }
                }
                .accessibilityIdentifier("workbench.filters")
            }
            if inventory.query.text.isEmpty && activeFilterCount == 0 {
                objectSection("Favorites", results: inventory.favoriteResults)
                objectSection("Recent", results: inventory.recentResults)
            }
            Section {
                if inventory.results.isEmpty {
                    InventorySearchStateRow(state: inventory.state)
                } else {
                    inventoryRows(inventory.results)
                }
            } header: {
                HStack {
                    Text("Results")
                    Spacer()
                    Text(inventory.results.count.formatted()).monospacedDigit()
                }
            } footer: {
                if inventory.results.count == min(max(inventory.query.maximumResults, 1), 50) {
                    Text("Refine your search to find more specific results.")
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $inventory.query.text, prompt: "Search inventory")
        .onSubmit(of: .search) { Task { await inventory.search() } }
        .task(id: inventory.query.text) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                await inventory.search()
            } catch {}
        }
    }

    private var activeFilterCount: Int {
        inventory.query.kinds.count + (inventory.query.siteID == nil ? 0 : 1)
    }

    private var selectionBinding: Binding<ObjectID?> {
        Binding(
            get: { inventory.selectedDetails?.result.id },
            set: { id in
                if let id {
                    onSelect(id)
                    Task { await inventory.select(id) }
                }
            })
    }

    @ViewBuilder
    private func objectSection(_ title: String, results: [InventorySearchResult]) -> some View {
        if !results.isEmpty {
            Section(title) { inventoryRows(results) }
        }
    }

    private func inventoryRows(_ results: [InventorySearchResult]) -> some View {
        ForEach(results) { result in
            WorkbenchInventoryRow(
                result: result,
                isFavorite: inventory.favorites.contains(result.id),
                select: inventory.select,
                onSelect: onSelect
            )
            .tag(result.id)
            .contextMenu {
                Button {
                    Task { await inventory.toggleFavorite(result.id) }
                } label: {
                    Label(
                        inventory.favorites.contains(result.id) ? "Remove favorite" : "Add favorite",
                        systemImage: "star")
                }
            }
        }
    }
}

private struct WorkbenchInventoryRow: View {
    let result: InventorySearchResult
    let isFavorite: Bool
    let select: (ObjectID) async -> Void
    let onSelect: (ObjectID) -> Void

    var body: some View {
        Button {
            onSelect(result.id)
            Task { await select(result.id) }
        } label: {
            HStack(alignment: .top, spacing: NettworkSpacing.standard) {
                Image(systemName: result.kind.symbolName)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                    HStack(spacing: NettworkSpacing.small) {
                        Text(result.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(Color.nettworkAccent)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(result.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: NettworkSpacing.minimumControlSize)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workbench.object.\(result.id.description)")
        .accessibilityLabel("\(result.kind.title), \(result.title), \(result.subtitle)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Open this object in the workbench.")
    }

    private var accessibilityValue: String {
        if let status = WorkbenchObjectStatus(result: result) {
            return status.title
        }
        return isFavorite ? "Favorite" : "Available"
    }
}

private struct WorkbenchObjectStatus {
    let title: String
    let role: NettworkStatusRole

    private init(title: String, role: NettworkStatusRole) {
        self.title = title
        self.role = role
    }

    init?(result: InventorySearchResult) {
        if result.isConflicted {
            self = .init(title: "Conflict", role: .conflict)
        } else if result.isPending {
            self = .init(title: "Pending change", role: .pending)
        } else if result.isTombstoned {
            self = .init(title: "Unavailable", role: .offline)
        } else {
            return nil
        }
    }
}
