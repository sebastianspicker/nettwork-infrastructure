import SwiftUI

enum WorkspaceNavigationGroup: String, CaseIterable, Identifiable {
    case infrastructure = "Infrastructure"
    case operations = "Operations"
    case workspace = "Workspace"

    var id: String { rawValue }

    var sections: [AppSection] {
        switch self {
        case .infrastructure: [.explore, .racks, .floorPlans, .ipam, .trace, .scan]
        case .operations: [.workOrders, .reports, .audit, .reconciliation]
        case .workspace: [.importExport, .templates, .labels, .administration]
        }
    }
}

struct WorkspaceNavigationRows: View {
    var body: some View {
        ForEach(WorkspaceNavigationGroup.allCases) { group in
            Section(group.rawValue) {
                ForEach(group.sections) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                        .accessibilityIdentifier("workspace.navigation.\(section.rawValue)")
                }
            }
        }
    }
}

struct WorkspaceUnavailableScreen: View {
    @Bindable var router: AppRouter

    var body: some View {
        NavigationSplitView {
            List(selection: $router.selectedSection) {
                WorkspaceNavigationRows()
            }
            .listStyle(.sidebar)
            .navigationTitle("Nettwork")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            WorkspaceConnectionGuidance(section: router.selectedSection ?? .explore)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct WorkspaceConnectionGuidance: View {
    let section: AppSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NettworkSpacing.xLarge) {
                NettworkPageHeader(section.title, subtitle: section.emptyMessage, systemImage: section.symbolName)
                NettworkDetailSection(title: "Connect your workspace", systemImage: "building.2.crop.circle") {
                    VStack(alignment: .leading, spacing: NettworkSpacing.medium) {
                        Text("Inventory, connections, and planned work.")
                            .font(.title3.weight(.semibold))
                        Text("Nettwork brings inventory, physical connections, address space, and planned work together in your organization's workspace.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Label("Workspace setup required", systemImage: "lock.circle")
                            .font(.headline)
                        Text(
                            "Ask your workspace administrator for a configured Nettwork app and access to your team's workspace. Your inventory will appear here once access is verified."
                        )
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Label("Workspace access is required to view or change inventory.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(NettworkSpacing.large)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(section.title)
        .accessibilityIdentifier("workspace.connection-guidance")
    }
}
