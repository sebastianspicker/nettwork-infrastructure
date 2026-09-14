import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

private enum TopologyEditorMode: String, CaseIterable, Identifiable {
    case connect, disconnect, move, removeDevice, markUnavailable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connect: "Connect"
        case .disconnect: "Disconnect"
        case .move: "Move"
        case .removeDevice: "Remove device"
        case .markUnavailable: "Mark unavailable"
        }
    }
}

struct TopologyWorkOrderDraftScreen: View {
    @Bindable var model: TopologyWorkspaceModel
    @State private var title = ""
    @State private var ticket = ""
    @State private var notes = ""
    @State private var editorMode: TopologyEditorMode = .connect
    @State private var cableAssetCode = ""
    @State private var cableKind: CableKind = .patchCord
    @State private var cableColor = ""
    @State private var cableLength = ""
    @State private var selectedCableID: ObjectID?
    @State private var selectedDeviceID: ObjectID?
    @State private var selectedAvailabilityPortID: ObjectID?
    @State private var isUnavailable = true

    var body: some View {
        Form {
            TopologySelectedSection(model: model, selectedCableID: $selectedCableID)
            TopologyPhysicalChangeSection(
                model: model, editorMode: $editorMode, cableAssetCode: $cableAssetCode,
                cableKind: $cableKind, cableColor: $cableColor, cableLength: $cableLength,
                selectedDeviceID: $selectedDeviceID, selectedAvailabilityPortID: $selectedAvailabilityPortID,
                isUnavailable: $isUnavailable, actionSummary: actionSummary, prepareDraft: prepareDraft
            )
            TopologyWorkOrderFields(title: $title, ticket: $ticket, notes: $notes)
            TopologyStageDraftButton(model: model, title: title, ticket: ticket, stage: stageDraft)
        }
        .navigationTitle("Stage topology work")
        .onAppear { selectedCableID = model.selectedCableID }
    }

    private func stageDraft() { Task { await model.stage(title: title, ticket: ticket, notes: notes) } }

    private func prepareDraft() {
        switch editorMode {
        case .connect:
            let length = cableLength.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Double(cableLength)
            model.prepareConnect(assetCode: cableAssetCode, kind: cableKind, color: cableColor, lengthMeters: length)
        case .disconnect: model.prepareDisconnect()
        case .move: model.prepareMove()
        case .removeDevice:
            Task { await model.prepareRemoveDevice(deviceID: selectedDeviceID) }
        case .markUnavailable: model.prepareMarkPortUnavailable(portID: selectedAvailabilityPortID, isUnavailable: isUnavailable)
        }
    }

    private var actionSummary: String {
        guard let action = model.proposedAction else { return "Prepare a command from selected ports or a mirrored cable before staging." }
        switch action {
        case let .connect(command):
            return "Connect \(command.cable.assetCode.value) using \(command.cable.medium.rawValue) "
                + "\(command.cable.connectorA.rawValue)/\(command.cable.connectorB.rawValue)."
        case let .disconnect(command): return "Disconnect mirrored cable \(command.cableID.description)."
        case let .move(command): return "Move cable \(command.cableID.description) to two selected typed endpoints."
        case let .remove(command): return "Remove mirrored device \(command.deviceID.description) after cable validation."
        case let .deviceDecommission(decommission): return "Decommission \(decommission.device.name) with its exact placement and floor-plan dependencies."
        case let .markUnavailable(command): return "Mark port \(command.portID.description) \(availabilityDescription(command.isUnavailable))."
        case .hierarchy: return "Apply the selected hierarchy change after work-order reservation and approval."
        }
    }

    private func availabilityDescription(_ isUnavailable: Bool) -> String {
        isUnavailable ? "unavailable" : "available"
    }
}

private struct TopologySelectedSection: View {
    @Bindable var model: TopologyWorkspaceModel
    @Binding var selectedCableID: ObjectID?

    var body: some View {
        Section("Selected topology") {
            Text("\(model.selectedPorts.count) port(s) selected")
            ForEach(model.selectedPorts) { Text("\($0.deviceName) · \($0.label) · \($0.medium.rawValue) · \($0.connector.rawValue)") }
            if model.cables.isEmpty {
                Text("No mirrored cables are available for disconnect or move.").foregroundStyle(.secondary)
            } else {
                Picker("Cable", selection: $selectedCableID) {
                    Text("Select a cable").tag(ObjectID?.none)
                    ForEach(model.cables) { Text("\($0.assetCode.value) · \($0.summary)").tag(Optional($0.id)) }
                }
                .onChange(of: selectedCableID) { _, value in model.selectCable(value) }
            }
        }
    }
}

private struct TopologyPhysicalChangeSection: View {
    @Bindable var model: TopologyWorkspaceModel
    @Binding var editorMode: TopologyEditorMode
    @Binding var cableAssetCode: String
    @Binding var cableKind: CableKind
    @Binding var cableColor: String
    @Binding var cableLength: String
    @Binding var selectedDeviceID: ObjectID?
    @Binding var selectedAvailabilityPortID: ObjectID?
    @Binding var isUnavailable: Bool
    let actionSummary: String
    let prepareDraft: () -> Void

    var body: some View {
        Section("Proposed physical change") {
            TopologyActionPicker(editorMode: $editorMode)
            if editorMode == .connect {
                TopologyCableFields(
                    assetCode: $cableAssetCode,
                    kind: $cableKind,
                    color: $cableColor,
                    length: $cableLength
                )
            }
            if editorMode == .removeDevice { TopologyDevicePicker(model: model, selectedDeviceID: $selectedDeviceID) }
            if editorMode == .markUnavailable {
                TopologyAvailabilityPicker(
                    model: model,
                    selectedPortID: $selectedAvailabilityPortID,
                    isUnavailable: $isUnavailable
                )
            }
            Button("Prepare typed \(editorMode.title.lowercased()) command", action: prepareDraft).accessibilityIdentifier("topology.prepareWorkOrder")
            if let message = model.draftValidationMessage { Text(message).font(.footnote).foregroundStyle(.orange) }
            Text(actionSummary)
            Text("This action remains a draft until the work-order workflow reserves and accepts it.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct TopologyActionPicker: View {
    @Binding var editorMode: TopologyEditorMode
    var body: some View {
        Picker("Action", selection: $editorMode) { ForEach(TopologyEditorMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
    }
}

private struct TopologyCableFields: View {
    @Binding var assetCode: String
    @Binding var kind: CableKind
    @Binding var color: String
    @Binding var length: String
    var body: some View {
        TextField("Cable asset code", text: $assetCode)
        Picker("Cable kind", selection: $kind) { ForEach(CableKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        TextField("Color (optional)", text: $color)
        TextField("Length in meters (optional)", text: $length)
    }
}

private struct TopologyDevicePicker: View {
    @Bindable var model: TopologyWorkspaceModel
    @Binding var selectedDeviceID: ObjectID?
    var body: some View {
        Picker("Device to remove", selection: $selectedDeviceID) {
            Text("Select a device").tag(ObjectID?.none)
            ForEach(model.hierarchyDevices) { Text("\($0.name) · \($0.detail)").tag(Optional($0.id)) }
        }
        .accessibilityIdentifier("topology.deviceForRemoval")
        Text(
            "The removal draft includes mirrored physical placement, floor-plan anchors, and logical interface dependencies. "
                + "Disconnect its cables first."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct TopologyAvailabilityPicker: View {
    @Bindable var model: TopologyWorkspaceModel
    @Binding var selectedPortID: ObjectID?
    @Binding var isUnavailable: Bool
    var body: some View {
        Picker("Port", selection: $selectedPortID) {
            Text("Select a port").tag(ObjectID?.none)
            ForEach(model.ports) { Text("\($0.deviceName) · \($0.label)").tag(Optional($0.id)) }
        }
        .accessibilityIdentifier("topology.portAvailabilityTarget")
        Toggle("Mark port unavailable", isOn: $isUnavailable).accessibilityIdentifier("topology.markPortUnavailable")
    }
}

private struct TopologyWorkOrderFields: View {
    @Binding var title: String
    @Binding var ticket: String
    @Binding var notes: String

    var body: some View {
        Section("Work order") {
            TextField("Title", text: $title)
            TextField("Ticket", text: $ticket)
            TextField("Notes", text: $notes, axis: .vertical)
        }
    }
}

private struct TopologyStageDraftButton: View {
    @Bindable var model: TopologyWorkspaceModel
    let title: String
    let ticket: String
    let stage: () -> Void
    var body: some View {
        Button("Stage work-order draft", action: stage)
            .disabled(
                model.proposedAction == nil
                    || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityIdentifier("topology.stageWorkOrder")
    }
}
