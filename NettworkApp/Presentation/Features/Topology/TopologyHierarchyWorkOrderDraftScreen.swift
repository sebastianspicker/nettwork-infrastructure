import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

private enum TopologyHierarchyEditorTarget: String, CaseIterable, Identifiable {
    case location, rack
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum TopologyHierarchyEditorMode: String, CaseIterable, Identifiable {
    case upsert, remove
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TopologyHierarchyWorkOrderDraftScreen: View {
    @Bindable var model: TopologyWorkspaceModel
    @State private var title = ""
    @State private var ticket = ""
    @State private var notes = ""
    @State private var target: TopologyHierarchyEditorTarget = .location
    @State private var mode: TopologyHierarchyEditorMode = .upsert
    @State private var selectedLocationID: ObjectID?
    @State private var selectedRackID: ObjectID?
    @State private var parentLocationID: ObjectID?
    @State private var locationName = ""
    @State private var locationKind: LocationKind = .room
    @State private var rackAssetCode = ""
    @State private var rackHeightRU = "42"

    var body: some View {
        Form {
            Section("Hierarchy change") {
                Picker("Object", selection: $target) {
                    ForEach(TopologyHierarchyEditorTarget.allCases) { Text($0.title).tag($0) }
                }
                Picker("Action", selection: $mode) {
                    ForEach(TopologyHierarchyEditorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if target == .location {
                    locationFields
                } else {
                    rackFields
                }
                Button("Prepare typed hierarchy command") { prepareDraft() }
                    .accessibilityIdentifier("topology.prepareHierarchyWorkOrder")
                if let message = model.draftValidationMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Work order") {
                TextField("Title", text: $title)
                TextField("Ticket", text: $ticket)
                TextField("Notes", text: $notes, axis: .vertical)
            }
            Button("Stage hierarchy work-order draft") {
                Task { await model.stage(title: title, ticket: ticket, notes: notes) }
            }
            .disabled(
                model.proposedAction == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityIdentifier("topology.stageHierarchyWorkOrder")
        }
        .navigationTitle("Stage hierarchy work")
    }

    @ViewBuilder
    private var locationFields: some View {
        Picker("Existing location", selection: $selectedLocationID) {
            Text("Create new location").tag(ObjectID?.none)
            ForEach(model.hierarchyLocations) { node in
                Text("\(node.name) · \(node.detail)").tag(Optional(node.id))
            }
        }
        if mode == .upsert {
            TextField("Location name", text: $locationName)
            Picker("Location kind", selection: $locationKind) {
                ForEach(LocationKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Parent location", selection: $parentLocationID) {
                if locationKind == .workspace {
                    Text("No parent").tag(ObjectID?.none)
                }
                ForEach(permittedParentLocations) { node in
                    Text("\(node.name) · \(node.detail)").tag(Optional(node.id))
                }
            }
        }
    }

    @ViewBuilder
    private var rackFields: some View {
        Picker("Existing rack", selection: $selectedRackID) {
            Text("Create new rack").tag(ObjectID?.none)
            ForEach(model.hierarchyRacks) { node in
                Text("\(node.name) · \(node.detail)").tag(Optional(node.id))
            }
        }
        if mode == .upsert {
            TextField("Rack asset code", text: $rackAssetCode)
            TextField("Rack height (RU)", text: $rackHeightRU)
            Picker("Room", selection: $parentLocationID) {
                Text("Select a room").tag(ObjectID?.none)
                ForEach(model.hierarchyLocations.filter { $0.location?.kind == .room }) { node in
                    Text(node.name).tag(Optional(node.id))
                }
            }
        }
    }

    private func prepareDraft() {
        switch target {
        case .location:
            model.prepareHierarchyLocation(
                existingID: selectedLocationID,
                name: locationName,
                kind: locationKind,
                parentID: parentLocationID,
                remove: mode == .remove
            )
        case .rack:
            model.prepareHierarchyRack(
                existingID: selectedRackID,
                assetCode: rackAssetCode,
                locationID: parentLocationID,
                heightRU: Int(rackHeightRU) ?? 0,
                remove: mode == .remove
            )
        }
    }

    private var summary: String {
        guard case let .hierarchy(operation) = model.proposedAction else {
            return "Prepare a complete location or rack command before staging."
        }
        switch operation {
        case .upsertLocation: return "Upsert location with its exact parent dependency."
        case .removeLocation: return "Soft-delete the selected location after hierarchy validation."
        case .upsertRack: return "Upsert rack with its exact room dependency."
        case .removeRack: return "Soft-delete the selected rack after hierarchy and placement validation."
        }
    }

    private var permittedParentLocations: [TopologyHierarchyNode] {
        let parentKind: LocationKind?
        switch locationKind {
        case .workspace: parentKind = nil
        case .site: parentKind = .workspace
        case .building: parentKind = .site
        case .floor: parentKind = .building
        case .room: parentKind = .floor
        case .unrackedArea: parentKind = .room
        }
        return model.hierarchyLocations.filter { $0.location?.kind == parentKind }
    }
}
