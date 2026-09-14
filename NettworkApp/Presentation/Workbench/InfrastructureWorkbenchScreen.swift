import NetworkModel
import SwiftUI

/// The production operator workspace for inventory-centric infrastructure work.
///
/// The screen owns only presentation state. Feature models and section
/// destinations are supplied by the application composition layer.
struct InfrastructureWorkbenchScreen: View {
    @Bindable private var router: AppRouter
    @Bindable private var inventory: InventoryExploreModel
    private let topology: TopologyWorkspaceModel
    private let ipam: IPAMWorkspaceModel
    private let trace: TraceInspectionModel
    private let sectionDestination: (AppSection) -> AnyView
    @State private var objectMode: WorkbenchObjectMode = .overview

    @SceneStorage("workbench.inspector.is-presented") private var isInspectorPresented = false

    init(
        router: AppRouter,
        inventory: InventoryExploreModel,
        topology: TopologyWorkspaceModel,
        ipam: IPAMWorkspaceModel,
        trace: TraceInspectionModel,
        sectionDestination: @escaping (AppSection) -> AnyView
    ) {
        self.router = router
        self.inventory = inventory
        self.topology = topology
        self.ipam = ipam
        self.trace = trace
        self.sectionDestination = sectionDestination
    }

    var body: some View {
        NavigationSplitView {
            InfrastructureWorkbenchSidebar(inventory: inventory, router: router, onSelect: openObject)
        } detail: {
            workbenchCenter
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $isInspectorPresented) {
            InfrastructureWorkbenchInspector(inventory: inventory)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .help("Show or hide the object inspector (⇧⌘I)")
                .accessibilityIdentifier("workbench.inspector-toggle")
                .accessibilityHint("Show or hide details for the selected inventory object.")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    router.selectedSection = .scan
                } label: {
                    Label("Scan", systemImage: AppSection.scan.symbolName)
                }
                .accessibilityIdentifier("workbench.scan")

                workbenchTools
            }
        }
        .task {
            await inventory.loadHistory()
            await inventory.loadSiteOptions()
        }
        .onChange(of: router.deepLinkRequest) { _, request in
            guard let request else { return }
            switch request.route {
            case .object(let identifier):
                router.selectedSection = .explore
                isInspectorPresented = true
                Task { await inventory.select(ObjectID(identifier)) }
            case .section(let section):
                router.selectedSection = section
            }
        }
        .onChange(of: router.selectedSection) { _, section in
            guard let section, let mode = WorkbenchObjectMode(section: section) else { return }
            objectMode = mode
        }
        .accessibilityIdentifier("workbench")
    }

    @ViewBuilder
    private var workbenchCenter: some View {
        if let section = router.selectedSection, WorkbenchObjectMode(section: section) != nil {
            WorkbenchObjectCenter(
                mode: $objectMode,
                router: router,
                inventory: inventory,
                topology: topology,
                ipam: ipam,
                trace: trace
            )
        } else if let section = router.selectedSection {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        router.selectedSection = .explore
                    } label: {
                        Label("Back to inventory", systemImage: "chevron.backward")
                    }
                    .nettworkMinimumControlTarget()
                    .accessibilityIdentifier("workbench.back-to-object")
                    Spacer()
                }
                .padding(.horizontal, NettworkSpacing.medium)
                Divider()
                sectionDestination(section)
            }
        } else {
            NettworkEmptyState(
                "Choose a workspace",
                systemImage: "rectangle.3.group",
                message: "Choose an inventory object or a tool to begin."
            )
        }
    }

    private var workbenchTools: some View {
        Menu {
            Section("Plan") {
                toolButton("Work Orders", section: .workOrders)
                toolButton("Floor Plans", section: .floorPlans)
                toolButton("Reports", section: .reports)
                toolButton("Audit", section: .audit)
            }
            Section("Manage") {
                toolButton("Transfer", section: .importExport)
                toolButton("Templates", section: .templates)
                toolButton("Labels", section: .labels)
            }
            Section("Control") {
                toolButton("Reconciliation", section: .reconciliation)
                toolButton("Administration", section: .administration)
            }
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .accessibilityIdentifier("workbench.tools")
    }

    private func toolButton(_ title: String, section: AppSection) -> some View {
        Button {
            router.selectedSection = section
        } label: {
            Label(title, systemImage: section.symbolName)
        }
        .accessibilityIdentifier("workbench.tools.\(section.rawValue)")
    }

    private func openObject(_: ObjectID) {
        router.selectedSection = .explore
    }
}

enum WorkbenchObjectMode: CaseIterable, Identifiable {
    case overview
    case physical
    case logical
    case trace
    case history

    init?(section: AppSection) {
        switch section {
        case .explore: self = .overview
        case .racks: self = .physical
        case .ipam: self = .logical
        case .trace: self = .trace
        default: return nil
        }
    }

    var id: String { title }

    var section: AppSection? {
        switch self {
        case .overview: .explore
        case .physical: .racks
        case .logical: .ipam
        case .trace: .trace
        case .history: nil
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .physical: "Physical"
        case .logical: "Logical"
        case .trace: "Trace"
        case .history: "History"
        }
    }
}

private struct WorkbenchObjectCenter: View {
    @Binding var mode: WorkbenchObjectMode
    let router: AppRouter
    @Bindable var inventory: InventoryExploreModel
    let topology: TopologyWorkspaceModel
    let ipam: IPAMWorkspaceModel
    let trace: TraceInspectionModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            modePicker
                .padding(NettworkSpacing.medium)
                .accessibilityIdentifier("workbench.object-mode")

            Divider()
            modeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(navigationTitle)
        .accessibilityIdentifier("workbench.center")
    }

    @ViewBuilder
    private var modePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Object mode", selection: selectedMode) {
                ForEach(WorkbenchObjectMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: NettworkSpacing.minimumControlSize)
        } else {
            Picker("Object mode", selection: selectedMode) {
                ForEach(WorkbenchObjectMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: NettworkSpacing.minimumControlSize)
        }
    }

    private var selectedMode: Binding<WorkbenchObjectMode> {
        Binding(
            get: { mode },
            set: { inventoryMode in
                guard inventoryMode != mode else { return }
                mode = inventoryMode
                if let section = inventoryMode.section {
                    router.selectedSection = section
                }
            }
        )
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .overview:
            WorkbenchOverview(details: inventory.selectedDetails, state: inventory.state)
        case .physical:
            WorkbenchPhysicalMode(
                details: inventory.selectedDetails,
                model: topology
            )
        case .logical:
            WorkbenchLogicalMode(
                details: inventory.selectedDetails,
                model: ipam
            )
        case .trace:
            WorkbenchTraceMode(details: inventory.selectedDetails, trace: trace, inventory: inventory)
        case .history:
            WorkbenchHistory(details: inventory.selectedDetails, state: inventory.state)
        }
    }

    private var navigationTitle: String {
        inventory.selectedDetails?.result.title ?? "Inventory"
    }
}

private struct WorkbenchOverview: View {
    let details: InventoryObjectDetails?
    let state: InventoryPresentationState

    var body: some View {
        Group {
            if let details {
                InventoryObjectSummary(details: details)
                    .accessibilityIdentifier("workbench.overview")
            } else {
                WorkbenchSelectionGuidance(state: state, title: "Select an object")
            }
        }
    }
}

struct WorkbenchSelectionGuidance: View {
    let state: InventoryPresentationState
    let title: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "point.3.connected.trianglepath.dotted",
            description: Text(workbenchStateMessage(state))
        )
        .accessibilityIdentifier("workbench.selection-guidance")
    }
}

private func workbenchStateMessage(_ state: InventoryPresentationState) -> String {
    switch state {
    case .loading: "Loading inventory…"
    case .ready, .empty: "Choose a result, favorite, or recent object from the inventory sidebar."
    case .offline(let message), .pending(let message), .conflict(let message),
        .quarantined(let message), .permissionDenied(let message), .unavailable(let message):
        message
    }
}
