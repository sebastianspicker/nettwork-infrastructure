import FeatureContracts
import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

extension IPAMWorkspaceScreen {
    var workflowLegend: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NettworkSpacing.standard) {
                    workflowLegendBadges
                }
                VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                    workflowLegendBadges
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("IPAM state legend: authoritative, reserved, planned, pending, and conflicting")
        } header: {
            Label("Record state", systemImage: "circle.lefthalf.filled")
        }
    }

    private var workflowLegendBadges: some View {
        ForEach(
            [
                IPAMWorkflowState.authoritative,
                .reserved,
                .planned,
                .pending,
                .conflicting,
            ], id: \.rawValue
        ) { state in
            IPAMWorkflowBadge(state: state)
        }
    }

    var prefixLayoutEditor: some View {
        PrefixLayoutEditorSection(model: model) { prefix in
            pendingPrefixRemoval = prefix
        }
        .accessibilityIdentifier("ipam.prefix-layout-editor")
    }

    @ViewBuilder var stagedWorkOrder: some View {
        if let workOrderID = model.stagedWorkOrderID {
            Section("Staged work order") {
                LabeledContent("WorkOrder ObjectID", value: workOrderID.description)
                    .accessibilityIdentifier("ipam.staged-work-order")
                Label("Pending only. No authoritative IPAM data was changed.", systemImage: IPAMWorkflowState.pending.symbolName)
                    .foregroundStyle(IPAMWorkflowState.pending.tint)
                    .accessibilityStatus(
                        "Work order \(workOrderID.description) is pending; no authoritative IPAM data changed.",
                        identifier: "ipam.staged-work-order-status"
                    )
            }
        }
    }

    var vrfHierarchy: some View {
        Section {
            ForEach(filteredVRFs) { vrf in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.selectVRF(vrf.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vrf.name).font(.headline)
                                Text("Revision \(vrf.revision) · \(prefixes(in: vrf).count) prefix(es)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            IPAMWorkflowBadge(state: workflowState(vrf))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("VRF \(vrf.name), revision \(vrf.revision), authoritative")
                    .accessibilityAddTraits(model.selectedVRFID == vrf.id ? .isSelected : [])
                    ForEach(prefixes(in: vrf)) { prefix in
                        prefixRow(prefix)
                    }
                }
            }
        } header: {
            Label("VRF hierarchy", systemImage: "point.3.connected.trianglepath.dotted")
        } footer: {
            Text("Select a VRF, then choose a prefix to inspect its addresses or prepare a layout change.")
        }
    }

    private func prefixRow(_ prefix: IPAMPrefixSnapshot) -> some View {
        Button {
            Task { await model.selectPrefix(prefix.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(prefix.cidr).font(.subheadline.weight(.semibold))
                    if prefix.hasReservedRanges {
                        IPAMWorkflowBadge(state: .reserved)
                    }
                    if prefix.isPlanned || prefix.isPending || prefix.isConflicted {
                        IPAMWorkflowBadge(state: workflowState(prefix))
                    }
                    Spacer()
                    Text("\(Int(prefix.utilization * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if !prefix.name.isEmpty {
                    Text(prefix.name).font(.footnote).foregroundStyle(.secondary)
                }
                ProgressView(value: min(max(prefix.utilization, 0), 1))
                    .accessibilityLabel("\(prefix.cidr) utilization")
                    .accessibilityValue("\(Int(prefix.utilization * 100)) percent")
                Text(prefix.reservedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ipam.prefix.\(prefix.id.description)")
        .accessibilityLabel(
            "Prefix \(prefix.cidr), \(prefix.name), "
                + "\(Int(prefix.utilization * 100)) percent utilized, \(prefix.reservedSummary)"
        )
    }

    @ViewBuilder var addressAssignment: some View {
        IPAMAddressAssignmentSection(
            model: model,
            addresses: filteredAddresses,
            interfaces: filteredInterfaces,
            selectedInterface: selectedAssignmentInterface,
            selectedAssignmentAddressID: selectedAssignmentAddressID,
            addressID: $assignmentAddressID,
            interfaceID: $assignmentInterfaceID,
            action: $assignmentAction,
            primaryAddressID: $assignmentPrimaryAddressID,
            stageAssignment: stageSelectedAddressAssignment
        )
    }

    var vlanAndInterfacePresentation: some View {
        Section {
            ForEach(groupedVLANs) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.subheadline.weight(.semibold))
                    ForEach(group.vlans) { vlan in
                        HStack {
                            Text("\(vlan.number) \(vlan.name)")
                            Spacer()
                            IPAMWorkflowBadge(state: workflowState(vlan))
                        }
                    }
                }
                .accessibilityLabel("VLAN group \(group.name): \(group.vlans.map { "VLAN \($0.number) \($0.name)" }.joined(separator: ", "))")
            }
            ForEach(filteredInterfaces) { interface in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(interface.deviceName) · \(interface.name)").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(interface.mode.rawValue.capitalized).foregroundStyle(.secondary)
                        IPAMWorkflowBadge(state: workflowState(interface))
                    }
                    Text(interface.vlanSummary).font(.footnote).foregroundStyle(.secondary)
                    Label(interface.physicalPortLabel.map { "Physical port link: \($0)" } ?? "No physical port link", systemImage: "cable.connector")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("ipam.interface.\(interface.id.description)")
            }
        } header: {
            Label("VLAN groups and interfaces", systemImage: "cable.connector")
        }
    }
}

private struct PrefixLayoutEditorSection: View {
    @Bindable var model: IPAMWorkspaceModel
    let requestRemoval: (IPAMPrefixSnapshot) -> Void

    var body: some View {
        Section {
            editorContent
        } header: {
            Label("Prefix layout change", systemImage: "point.3.connected.trianglepath.dotted")
        } footer: {
            Text("A staged request contains the complete desired layout for the selected VRF revision.")
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if let vrf = model.selectedVRF {
            PrefixLayoutContext(vrf: vrf, beginNewPrefix: model.beginNewPrefix)
            if model.prefixEditorID != nil {
                PrefixLayoutFields(model: model, requestRemoval: requestRemoval)
            } else {
                Text("Select an existing prefix to edit it, or start a new prefix. The staged request carries the complete desired VRF layout.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let explanation = model.validationExplanation {
                Text(explanation).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Text("Select a VRF before editing its prefix layout.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PrefixLayoutContext: View {
    let vrf: VRFSnapshot
    let beginNewPrefix: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NettworkSpacing.standard) {
                summary
                Spacer()
                newPrefixButton
            }
            VStack(alignment: .leading, spacing: NettworkSpacing.small) {
                summary
                newPrefixButton
            }
        }
    }

    private var summary: some View {
        Text("Complete layout for \(vrf.name) at revision \(vrf.revision).")
    }

    private var newPrefixButton: some View {
        Button("New prefix", action: beginNewPrefix)
            .buttonStyle(.bordered)
    }
}

private struct PrefixLayoutFields: View {
    @Bindable var model: IPAMWorkspaceModel
    let requestRemoval: (IPAMPrefixSnapshot) -> Void

    var body: some View {
        TextField("Canonical CIDR", text: $model.prefixCIDR)
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
        TextField("Prefix name", text: $model.prefixName)
        TextField("Reserved ranges: start-end, …", text: $model.reservedRanges)
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
        HStack {
            Button("Stage create or update") {
                Task { await model.stagePrefixLayout() }
            }
            .buttonStyle(.borderedProminent)
            Button("Stage removal", role: .destructive) {
                if let prefix = model.selectedPrefix {
                    requestRemoval(prefix)
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedPrefix == nil)
            .accessibilityIdentifier("ipam.prefix-removal.initiate")
        }
        .disabled(model.ticketID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
