import FeatureContracts
import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct TopologyWorkspaceScreen: View {
    @Bindable var model: TopologyWorkspaceModel
    let focusedObject: InventorySearchResult?
    let showsPageHeader: Bool

    init(
        model: TopologyWorkspaceModel,
        focusedObject: InventorySearchResult? = nil,
        showsPageHeader: Bool = true
    ) {
        self.model = model
        self.focusedObject = focusedObject
        self.showsPageHeader = showsPageHeader
    }

    var body: some View {
        List {
            topologyListContent
        }
        .navigationTitle("Racks and Ports")
        .searchable(text: $model.portFilter, prompt: "Filter ports, devices, modules")
        .task(id: focusedObject?.id) {
            guard await model.load(), !Task.isCancelled else { return }
            model.focus(on: focusedObject)
        }
    }

    @ViewBuilder
    private var topologyListContent: some View {
        topologyPageHeader
        hierarchySection
        rackFilterSection
        changePlanningSection
        rackResults
    }

    @ViewBuilder
    private var topologyPageHeader: some View {
        if showsPageHeader {
            Section {
                NettworkPageHeader(
                    "Physical topology",
                    subtitle: "Review the mirrored hierarchy, rack elevation, and port availability before creating a work order.",
                    systemImage: "server.rack"
                )
            }
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var hierarchySection: some View {
        if !model.hierarchyIndex.isEmpty {
            Section {
                TopologyHierarchyOutline(index: model.hierarchyIndex)
            } header: {
                Label("Location hierarchy", systemImage: "square.3.layers.3d")
            } footer: {
                Text("Expand a location to review its contained racks, devices, modules, and ports.")
            }
        }
    }

    private var rackFilterSection: some View {
        Section {
            TopologyRackFilters(model: model)
        } header: {
            Label("Rack elevation filters", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var changePlanningSection: some View {
        Section {
            NavigationLink {
                TopologyWorkOrderDraftScreen(model: model)
            } label: {
                Label("Stage physical change", systemImage: "wrench.and.screwdriver")
            }
            .accessibilityIdentifier("topology.openWorkOrder")
            NavigationLink {
                TopologyHierarchyWorkOrderDraftScreen(model: model)
            } label: {
                Label("Stage hierarchy change", systemImage: "square.3.layers.3d.down.right")
            }
            .accessibilityIdentifier("topology.openHierarchyWorkOrder")
        } header: {
            Text("Change planning")
        } footer: {
            Text("Review these changes in a work order before applying them.")
        }
    }

    @ViewBuilder
    private var rackResults: some View {
        if displayedRacks.isEmpty {
            Section("Rack elevation") {
                rackStateView
            }
        } else {
            ForEach(displayedRacks) { rack in
                TopologyRackElevationSection(model: model, rack: rack)
            }
        }
    }

    @ViewBuilder
    private var rackStateView: some View {
        switch model.state {
        case .loading:
            NettworkLoadingState("Loading rack elevations")
        case .offline(let message), .permissionDenied(let message), .unavailable(let message), .quarantined(let message):
            NettworkNotice("Rack elevations unavailable", message: message, style: .warning)
        case .empty, .ready, .pending(_), .conflict(_):
            NettworkEmptyState(
                focusedObject == nil ? "No racks available" : "No physical view for this object",
                systemImage: "server.rack",
                message: rackEmptyMessage
            )
        }
    }

    private var displayedRacks: [RackElevationSnapshot] {
        model.visibleRacks.filter { $0.faceName == model.selectedFace }
    }

    private var rackEmptyMessage: String {
        if model.visibleRacks.isEmpty {
            return "The current local mirror has no matching rack elevation. You can still review the hierarchy or plan a change."
        }
        return "No rack elevation is available for the selected face. Choose another face to continue."
    }
}

private struct TopologyRackFilters: View {
    @Bindable var model: TopologyWorkspaceModel

    var body: some View {
        Picker("Rack face", selection: $model.selectedFace) {
            Text("Front").tag("front")
            Text("Rear").tag("rear")
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("topology.rack.face")
        Picker("Availability", selection: $model.availabilityFilter) {
            ForEach(TopologyPortAvailabilityFilter.allCases) { Text($0.title).tag($0) }
        }
        Picker("Medium", selection: $model.mediumFilter) {
            Text("All media").tag(PortMedium?.none)
            ForEach(PortMedium.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
        }
        Picker("Connector", selection: $model.connectorFilter) {
            Text("All connectors").tag(Connector?.none)
            ForEach(Connector.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag(Optional($0)) }
        }
        Picker("State", selection: $model.stateFilter) {
            ForEach(TopologyPortStateFilter.allCases) { Text($0.title).tag($0) }
        }
    }
}

private struct TopologyRackElevationSection: View {
    @Bindable var model: TopologyWorkspaceModel
    let rack: RackElevationSnapshot

    var body: some View {
        Section("\(rack.assetCode.value) · \(rack.heightRU) RU · \(rack.faceName.capitalized)") {
            ForEach(rack.entries) { entry in
                TopologyRackEntryRow(entry: entry)
            }
            ForEach(model.ports(in: rack)) { port in
                TopologyPortRow(model: model, port: port)
            }
        }
    }
}

private struct TopologyRackEntryRow: View {
    let entry: RackElevationEntrySnapshot

    var body: some View {
        HStack {
            Label(entry.name, systemImage: entry.isReservation ? "lock.fill" : "server.rack")
            Spacer()
            Text("RU \(entry.startRU)-\(entry.endRU)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(entry.isReservation ? "Reserved" : "Device") \(entry.name), rack units \(entry.startRU) through \(entry.endRU)")
    }
}

private struct TopologyHierarchyOutline: View {
    let index: TopologyHierarchyIndex
    var parentID: ObjectID?

    private var children: [TopologyHierarchyNode] {
        parentID.map(index.children) ?? index.roots
    }

    var body: some View {
        ForEach(children) { node in
            TopologyHierarchyRow(node: node, index: index)
        }
    }
}

private struct TopologyHierarchyRow: View {
    let node: TopologyHierarchyNode
    let index: TopologyHierarchyIndex
    @State private var isExpanded = false

    private var hasChildren: Bool { !index.children(of: node.id).isEmpty }

    var body: some View {
        if hasChildren {
            DisclosureGroup(isExpanded: $isExpanded) {
                TopologyHierarchyOutline(index: index, parentID: node.id)
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                Text(node.name)
                Text(node.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: node.kind.symbolName)
        }
        .accessibilityLabel("\(node.kind.title) \(node.name), \(node.childCount) contained items")
    }
}

private struct TopologyPortRow: View {
    @Bindable var model: TopologyWorkspaceModel
    let port: TopologyPortSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.toggleSelection(for: port)
            } label: {
                HStack(alignment: .top, spacing: NettworkSpacing.standard) {
                    VStack(alignment: .leading) {
                        Text(port.label).font(.body.weight(.medium))
                        Text(portDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Label(port.state.rawValue.capitalized, systemImage: statusRole.symbolName)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(statusRole.color)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Port \(port.label), \(port.state.rawValue), \(port.medium.rawValue), \(port.connector.rawValue)")
            .accessibilityValue(port.cableSummary ?? "No cable")
            if let cable = port.cable {
                Button("Cable \(cable.assetCode.value): \(cable.summary)") { model.selectCable(cable.id) }
                    .font(.caption)
                    .foregroundStyle(
                        model.selectedCableID == cable.id ? NettworkStatusRole.information.color : Color.secondary
                    )
            }
            if let reservationOwner = port.reservationOwner {
                Label(reservationOwner, systemImage: NettworkStatusRole.reserved.symbolName)
                    .font(.caption)
                    .foregroundStyle(NettworkStatusRole.reserved.color)
            }
            ForEach(port.warnings, id: \.self) { warning in
                Label(warning, systemImage: statusRole.symbolName)
                    .font(.caption)
                    .foregroundStyle(statusRole.color)
            }
        }
        .listRowBackground(
            model.selectedPortIDs.contains(port.id)
                ? NettworkStatusRole.information.color.opacity(0.14)
                : Color.clear
        )
    }

    private var statusRole: NettworkStatusRole {
        if port.hasConflict { return .conflict }
        switch port.state {
        case .free: return .ready
        case .occupied: return .information
        case .reserved: return .reserved
        case .planned: return .pending
        case .unavailable: return .offline
        }
    }

    private var portDetail: String {
        "\(port.deviceName)\(port.moduleSlot.map { " · \($0)" } ?? "") · \(port.medium.rawValue) · \(port.connector.rawValue)"
    }
}
