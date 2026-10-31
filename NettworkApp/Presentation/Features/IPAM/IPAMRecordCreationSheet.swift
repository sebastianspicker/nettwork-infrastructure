import FeatureContracts
import Foundation
import NetworkModel
import SwiftUI
import WorkspaceChangeControl

enum IPAMRecordCreationKind: String, Identifiable {
    case vrf, address, vlan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vrf: "New VRF"
        case .address: "New address"
        case .vlan: "New VLAN"
        }
    }
}

struct IPAMRecordCreationSection: View {
    let model: IPAMWorkspaceModel
    @Binding var presented: IPAMRecordCreationKind?

    var body: some View {
        Section {
            Button(IPAMRecordCreationKind.vrf.title, systemImage: "plus") { presented = .vrf }
                .accessibilityIdentifier("ipam.create.vrf")
            Button(IPAMRecordCreationKind.address.title, systemImage: "plus") { presented = .address }
                .disabled(model.selectedVRF == nil)
                .accessibilityIdentifier("ipam.create.address")
                .accessibilityHint("Creates an address inside a prefix of the selected VRF.")
            Button(IPAMRecordCreationKind.vlan.title, systemImage: "plus") { presented = .vlan }
                .accessibilityIdentifier("ipam.create.vlan")
        } header: {
            Label("Create records", systemImage: "plus.rectangle.on.rectangle")
        } footer: {
            Text("Each new record is staged as a work order and is created only when that work order completes.")
        }
    }
}

struct IPAMRecordCreationSheet: View {
    @Bindable var model: IPAMWorkspaceModel
    let kind: IPAMRecordCreationKind
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var vlanNumber = ""
    @State private var groupID: ObjectID?
    @State private var newGroupName = ""
    @State private var isStaging = false
    @State private var hasAttempted = false

    var body: some View {
        NavigationStack {
            Form {
                recordFields
                Section("Work-order request") {
                    TextField("Work-order title", text: $model.draftTitle)
                    TextField("Ticket", text: $model.ticketID)
                        .accessibilityIdentifier("ipam.create.ticket")
                    TextField("Notes", text: $model.draftNotes, axis: .vertical)
                        .lineLimit(2...4)
                }
                if hasAttempted {
                    IPAMPresentationStateMessage(state: model.state)
                }
            }
            .navigationTitle(kind.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("ipam.create.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Stage") { Task { await submit() } }
                        .disabled(isStaging)
                        .accessibilityIdentifier("ipam.create.stage")
                        .accessibilityHint("Stages a work-order draft only; no authoritative IPAM record is created yet.")
                }
            }
        }
    }

    @ViewBuilder private var recordFields: some View {
        switch kind {
        case .vrf:
            Section("VRF") {
                TextField("VRF name", text: $name)
                    .accessibilityIdentifier("ipam.create.vrf-name")
            }
        case .address:
            Section {
                LabeledContent("VRF", value: model.selectedVRF?.name ?? "None selected")
                TextField("Canonical IP address", text: $address)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ipam.create.address-value")
            } header: {
                Text("Address")
            } footer: {
                Text("The address must fall inside an existing prefix of the selected VRF and outside its reserved ranges.")
            }
        case .vlan:
            vlanFields
        }
    }

    private var vlanFields: some View {
        Section {
            TextField("VLAN ID (1–4094)", text: $vlanNumber)
                .accessibilityIdentifier("ipam.create.vlan-number")
            TextField("VLAN name", text: $name)
                .accessibilityIdentifier("ipam.create.vlan-name")
            Picker("VLAN group", selection: $groupID) {
                Text("New group").tag(ObjectID?.none)
                ForEach(model.vlanGroupChoices) { group in
                    Text(group.name).tag(group.id as ObjectID?)
                }
            }
            .accessibilityIdentifier("ipam.create.vlan-group")
            if groupID == nil {
                TextField("New group name", text: $newGroupName)
                    .accessibilityIdentifier("ipam.create.vlan-group-name")
            }
        } header: {
            Text("VLAN")
        } footer: {
            Text("VLAN IDs are unique within their group.")
        }
    }

    private func submit() async {
        isStaging = true
        defer { isStaging = false }
        hasAttempted = true
        let staged: Bool
        switch kind {
        case .vrf: staged = await model.stageNewVRF(name: name)
        case .address: staged = await model.stageNewAddress(address)
        case .vlan: staged = await model.stageNewVLAN(number: vlanNumber, name: name, groupID: groupID, newGroupName: newGroupName)
        }
        if staged { dismiss() }
    }
}
