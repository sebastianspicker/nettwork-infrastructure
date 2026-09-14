import NetworkModel
import SwiftUI
import WorkspaceChangeControl

struct AppShell: View {
    let router: AppRouter

    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(iOS)
            if horizontalSizeClass == .compact {
                CompactAppShell(router: router)
            } else {
                WorkbenchAppShell(router: router)
            }
        #else
            WorkbenchAppShell(router: router)
        #endif
    }
}

private struct WorkbenchAppShell: View {
    let router: AppRouter
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        dependencies.features.workbench(router: router)
            .appDestinations()
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    WorkspaceSyncButton()
                }
            }
    }
}

private struct CompactAppShell: View {
    let router: AppRouter
    @State private var selectedTab: CompactTab = .explore
    @State private var explorePath: [AppRoute] = []
    @State private var workOrdersPath: [AppRoute] = []
    @State private var tracePath: [AppRoute] = []
    @State private var ipamPath: [AppRoute] = []
    @State private var morePath: [AppRoute] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(CompactTab.allCases) { tab in
                NavigationStack(path: binding(for: tab)) {
                    CompactTabHome(tab: tab)
                        .appDestinations()
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.symbolName)
                        .accessibilityIdentifier("shell.tab.\(tab.rawValue)")
                }
                .tag(tab)
            }
        }
        .onChange(of: router.deepLinkRequest) { _, request in
            guard let request else { return }
            selectedTab = .explore
            explorePath = [request.route]
        }
    }

    private func binding(for tab: CompactTab) -> Binding<[AppRoute]> {
        switch tab {
        case .explore: $explorePath
        case .workOrders: $workOrdersPath
        case .trace: $tracePath
        case .ipam: $ipamPath
        case .more: $morePath
        }
    }
}

private struct CompactTabHome: View {
    let tab: CompactTab

    var body: some View {
        Group {
            if tab.sections.count == 1, let section = tab.sections.first {
                FeatureDestinationScreen(section: section)
            } else {
                List {
                    ForEach(CompactMoreGroup.allCases) { group in
                        Section(group.title) {
                            ForEach(group.sections) { section in
                                NavigationLink(value: AppRoute.section(section)) {
                                    Label(section.title, systemImage: section.symbolName)
                                }
                                .accessibilityIdentifier("shell.more.\(section.rawValue)")
                            }
                        }
                    }
                }
                .navigationTitle(tab.title)
            }
        }
    }
}

enum CompactMoreGroup: String, CaseIterable, Identifiable {
    case infrastructure
    case operations
    case workspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .infrastructure: "Infrastructure"
        case .operations: "Operations"
        case .workspace: "Workspace"
        }
    }

    var sections: [AppSection] {
        switch self {
        case .infrastructure: [.floorPlans, .racks, .scan]
        case .operations: [.reports, .audit, .reconciliation]
        case .workspace: [.importExport, .templates, .labels, .administration]
        }
    }
}

private struct AppRouteView: View {
    let route: AppRoute
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        switch route {
        case .section(let section):
            dependencies.features.destination(for: section)
        case .object(let identifier):
            dependencies.features.destination(for: ObjectID(identifier))
        }
    }
}

private struct FeatureDestinationScreen: View {
    let section: AppSection
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        dependencies.features.destination(for: section)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    WorkspaceSyncButton()
                }
            }
    }
}

private struct WorkspaceSyncButton: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        Menu {
            Text(dependencies.syncStatus.title)
            Text(dependencies.syncStatus.detail)
            Divider()
            Button {
                Task { await dependencies.synchronizeForeground() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(dependencies.syncStatus == .loading || dependencies.syncStatus == .syncing)
        } label: {
            #if os(macOS)
                StatusIndicator(status: dependencies.syncStatus, style: .inline)
            #else
                StatusIndicator(status: dependencies.syncStatus)
            #endif
        }
        .help(dependencies.syncStatus.detail)
        .accessibilityIdentifier("workspace.sync-status")
        .accessibilityHint("View synchronization status or sync the workspace now.")
    }
}

private extension View {
    func appDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            AppRouteView(route: route)
        }
    }
}
