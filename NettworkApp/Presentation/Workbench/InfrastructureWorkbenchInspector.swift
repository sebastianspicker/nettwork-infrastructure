import SwiftUI

struct InfrastructureWorkbenchInspector: View {
    @Bindable var inventory: InventoryExploreModel

    var body: some View {
        Group {
            if let details = inventory.selectedDetails {
                detailsList(details)
            } else {
                WorkbenchSelectionGuidance(state: inventory.state, title: "No object selected")
            }
        }
        .accessibilityIdentifier("workbench.inspector")
    }

    private func detailsList(_ details: InventoryObjectDetails) -> some View {
        List {
            Section("Identity") {
                WorkbenchAuthorityBadge(result: details.result)
                InspectorPropertyRow("Name", value: details.result.title)
                InspectorPropertyRow("Kind", value: details.result.kind.title)
                InspectorPropertyRow("Identifier", value: details.result.id.description, isIdentifier: true)
                InspectorPropertyRow("Description", value: details.result.subtitle)
                if let siteName = details.result.siteName {
                    InspectorPropertyRow("Site", value: siteName)
                }
            }
            inspectorValues("Containment", values: details.containment)
            Section("Connectivity") {
                InspectorPropertyRow("Summary", value: details.connectivitySummary)
                InspectorPropertyRow("Trace", value: details.traceSummary)
            }
            inspectorValues("Logical context", values: details.logicalContext)
            if let reservation = details.reservationSummary {
                Section("Reservation") { Text(reservation) }
            }
            if let pending = details.pendingSummary {
                Section("Pending change") { Text(pending) }
            }
            auditSection(details.recentAuditSummary)
            Section("Attachments") { Text(attachmentSummary(details.attachmentCount)) }
            favoriteSection(for: details)
        }
        .listStyle(.plain)
        .navigationTitle("Inspector")
    }

    private func auditSection(_ entries: [String]) -> some View {
        Section("Recent audit") {
            if entries.isEmpty {
                Text("No recent audit activity.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.self) { entry in Text(entry) }
            }
        }
    }

    private func favoriteSection(for details: InventoryObjectDetails) -> some View {
        Section {
            Button {
                Task { await inventory.toggleFavorite(details.result.id) }
            } label: {
                Label(
                    inventory.favorites.contains(details.result.id) ? "Remove favorite" : "Add favorite",
                    systemImage: inventory.favorites.contains(details.result.id) ? "star.slash" : "star"
                )
            }
            .nettworkMinimumControlTarget()
            .accessibilityIdentifier("workbench.favorite-toggle")
        }
    }

    @ViewBuilder
    private func inspectorValues(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            Section(title) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                }
            }
        }
    }

    private func attachmentSummary(_ count: Int) -> String {
        count == 1 ? "1 attachment" : "\(count) attachments"
    }
}

struct WorkbenchAuthorityBadge: View {
    let result: InventorySearchResult

    var body: some View {
        StatusBadge(title: title, role: role)
    }

    private var title: String {
        if result.isConflicted { return "Conflict" }
        if result.isPending { return "Pending change" }
        if result.isTombstoned { return "Unavailable" }
        return "Authoritative"
    }

    private var role: NettworkStatusRole {
        if result.isConflicted { return .conflict }
        if result.isPending { return .pending }
        if result.isTombstoned { return .offline }
        return .ready
    }
}

struct WorkbenchSummaryRow: View {
    let title: String
    let values: [String]

    init(_ title: String, values: [String]) {
        self.title = title
        self.values = values
    }

    init(_ title: String, value: String) {
        self.init(title, values: [value])
    }

    var body: some View {
        LabeledContent(title) {
            if values.isEmpty {
                Text("Not recorded")
                    .foregroundStyle(.secondary)
            } else {
                Text(values.joined(separator: "\n"))
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

struct WorkbenchTraceMode: View {
    let details: InventoryObjectDetails?
    let trace: TraceInspectionModel
    let inventory: InventoryExploreModel

    var body: some View {
        if let details, details.result.kind == .port {
            TraceInspectionScreen(model: trace, startPortID: details.result.id) { objectID in
                Task { await inventory.select(objectID) }
            }
            .id(details.result.id)
            .accessibilityIdentifier("workbench.trace")
        } else if details != nil {
            ContentUnavailableView(
                "Select a port to trace",
                systemImage: "arrow.triangle.branch",
                description: Text("Trace inspection starts from a selected inventory port.")
            )
            .accessibilityIdentifier("workbench.trace-guidance")
        } else {
            WorkbenchSelectionGuidance(state: inventory.state, title: "Select a port to trace")
        }
    }
}

struct WorkbenchHistory: View {
    let details: InventoryObjectDetails?
    let state: InventoryPresentationState

    var body: some View {
        if let details {
            List {
                Section("Recent audit") {
                    if details.recentAuditSummary.isEmpty {
                        Text("No recent audit activity for this object.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(details.recentAuditSummary, id: \.self) { entry in
                            Text(entry)
                        }
                    }
                }
            }
            .accessibilityIdentifier("workbench.history")
        } else {
            WorkbenchSelectionGuidance(state: state, title: "Select an object for history")
        }
    }
}
