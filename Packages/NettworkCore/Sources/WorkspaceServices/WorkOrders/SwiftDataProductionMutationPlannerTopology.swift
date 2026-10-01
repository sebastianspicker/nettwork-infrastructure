import CloudSync
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataProductionMutationPlanner {
    private struct DeviceDecommissionState {
        let modules: [Module]
        let ports: [NetworkModel.Port]
        let placements: [RackPlacement]
        let anchors: [FloorPlanAnchor]
        let interfaces: [Interface]
        let assignments: [IPAddressAssignment]
        let memberships: [InterfaceVLANMembership]
        let addresses: [IPAddressRecord]
    }

    func applyTemplateMigration(_ migration: DeviceTemplateMigrationPlan, device: Device, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        let sourceIDs = Set(migration.sourceSnapshot.portTemplates.map(\.id))
        let targetIDs = Set(migration.targetSnapshot.portTemplates.map(\.id))
        guard Set(migration.portImpacts.map(\.templatePortID)) == sourceIDs.union(targetIDs),
            Set(migration.portImpacts.map(\.templatePortID)).count == migration.portImpacts.count
        else {
            throw ProductionMutationPlannerError.missingTopologyObject(.object(device.id))
        }
        let directPorts = snapshot.topology.ports.filter { $0.deviceID == device.id && $0.moduleID == nil }
        guard directPorts.count == sourceIDs.count,
            Set(directPorts.compactMap(\.templatePortID)) == sourceIDs
        else {
            throw ProductionMutationPlannerError.missingTopologyObject(.object(device.id))
        }
        let currentByTemplate = Dictionary(
            uniqueKeysWithValues: directPorts.compactMap { port in
                port.templatePortID.map { ($0, port) }
            })
        for impact in migration.portImpacts.sorted(by: { $0.templatePortID < $1.templatePortID }) {
            try applyPortImpact(impact, currentByTemplate: currentByTemplate, deviceID: device.id, snapshot: &snapshot, changes: &changes)
        }
    }

    private func applyPortImpact(
        _ impact: TemplatePortMigrationImpact, currentByTemplate: [ObjectID: NetworkModel.Port],
        deviceID: ObjectID, snapshot: inout Snapshot,
        changes: inout ChangeAccumulator
    ) throws {
        guard currentByTemplate[impact.templatePortID] == impact.currentPort else {
            throw ProductionMutationPlannerError.missingTopologyObject(
                .object(impact.currentPort?.id ?? impact.templatePortID)
            )
        }
        switch impact.action {
        case .retain:
            guard impact.currentPort == impact.desiredPort,
                impact.connectedCableIDs.isEmpty
            else {
                throw ProductionMutationPlannerError.missingTopologyObject(.object(impact.templatePortID))
            }
        case .add:
            try addMigratedPort(impact, deviceID: deviceID, snapshot: &snapshot, changes: &changes)
        case .remove, .reconfigure:
            try replaceMigratedPort(impact, deviceID: deviceID, snapshot: &snapshot, changes: &changes)
        }
    }

    private func addMigratedPort(
        _ impact: TemplatePortMigrationImpact, deviceID: ObjectID, snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        guard impact.currentPort == nil,
            let desired = impact.desiredPort,
            desired.deviceID == deviceID,
            desired.moduleID == nil,
            desired.templatePortID == impact.templatePortID,
            snapshot.topology.ports.allSatisfy({ $0.id != desired.id }),
            impact.connectedCableIDs.isEmpty
        else {
            throw ProductionMutationPlannerError.duplicateMutation(
                .object(impact.desiredPort?.id ?? impact.templatePortID)
            )
        }
        snapshot.topology.ports.append(desired)
        try changes.save(desired, recordType: "Port")
    }

    private func replaceMigratedPort(
        _ impact: TemplatePortMigrationImpact, deviceID: ObjectID, snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        guard let current = impact.currentPort else {
            throw ProductionMutationPlannerError.missingTopologyObject(.object(impact.templatePortID))
        }
        let connected = snapshot.topology.cables.filter {
            $0.endpointA == current.id || $0.endpointB == current.id
        }.sorted { $0.id < $1.id }
        guard connected.map(\.id) == impact.connectedCableIDs.sorted() else {
            throw ProductionMutationPlannerError.missingTopologyObject(.object(current.id))
        }
        for cable in connected {
            snapshot.topology.cables.removeAll { $0.id == cable.id }
            try changes.tombstone(cable, recordType: "Cable")
        }
        if impact.action == .remove {
            guard impact.desiredPort == nil else {
                throw ProductionMutationPlannerError.duplicateMutation(.object(current.id))
            }
            snapshot.topology.ports.removeAll { $0.id == current.id }
            try changes.tombstone(current, recordType: "Port")
            return
        }
        try reconfigurePort(impact, current: current, deviceID: deviceID, snapshot: &snapshot, changes: &changes)
    }

    private func reconfigurePort(
        _ impact: TemplatePortMigrationImpact, current: NetworkModel.Port,
        deviceID: ObjectID, snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        guard let desired = impact.desiredPort,
            desired.id == current.id,
            desired.deviceID == deviceID,
            desired.moduleID == nil,
            desired.templatePortID == impact.templatePortID,
            let index = snapshot.topology.ports.firstIndex(where: { $0.id == current.id })
        else {
            throw ProductionMutationPlannerError.missingTopologyObject(.object(current.id))
        }
        snapshot.topology.ports[index] = desired
        try changes.save(desired, recordType: "Port")
    }

    func applyFloorPlan(_ operation: PlannedFloorPlanOperation, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        switch operation {
        case .upsert(let anchor):
            if let index = snapshot.anchors.firstIndex(where: { $0.id == anchor.id }) {
                snapshot.anchors[index] = anchor
            } else {
                snapshot.anchors.append(anchor)
            }
            try changes.save(anchor, recordType: "FloorPlanAnchor")

        case .remove(let anchor):
            guard let index = snapshot.anchors.firstIndex(of: anchor) else {
                throw ProductionMutationPlannerError.missingFloorPlanAnchor(.object(anchor.id))
            }
            snapshot.anchors.remove(at: index)
            try changes.tombstone(anchor, recordType: "FloorPlanAnchor")

        case .bindAsset(let planned):
            guard
                snapshot.hierarchy.locations.contains(where: {
                    $0.id == planned.floorID && $0.kind == .floor && $0.deletedAt == nil
                })
            else {
                throw ProductionMutationPlannerError.missingTopologyObject(.object(planned.floorID))
            }
            // The work order commits only the immutable asset metadata. The
            // bytes and floor-keyed binding are attached later by the
            // specialized activation authority after this order is completed.
            _ = try PlannedFloorPlanAsset(floorID: planned.floorID, assetMetadata: planned.assetMetadata)
        }
    }

    func applyDeviceDecommission(_ decommission: PlannedDeviceDecommission, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        let deviceID = decommission.removal.deviceID
        let state = decommissionState(deviceID: deviceID, snapshot: snapshot)
        try validateDecommission(decommission, deviceID: deviceID, state: state, snapshot: snapshot)
        let before = snapshot.topology
        _ = try snapshot.topology.apply(.remove(decommission.removal))
        try changes.captureTopologyDifference(before: before, after: snapshot.topology)
        try removePlacementState(state, deviceID: deviceID, snapshot: &snapshot, changes: &changes)
        try removeIPAMState(state, snapshot: &snapshot, changes: &changes)
    }

    private func decommissionState(deviceID: ObjectID, snapshot: Snapshot) -> DeviceDecommissionState {
        let interfaces = snapshot.interfaces.values
            .filter { $0.isActive && $0.deviceID == deviceID }
            .sorted { $0.id < $1.id }
        let interfaceIDs = Set(interfaces.map(\.id))
        return DeviceDecommissionState(
            modules: snapshot.topology.modules.filter { $0.deviceID == deviceID }.sorted { $0.id < $1.id },
            ports: snapshot.topology.ports.filter { $0.deviceID == deviceID }.sorted { $0.id < $1.id },
            placements: snapshot.placements.filter { $0.deviceID == deviceID }.sorted(by: rackPlacementOrder),
            anchors: snapshot.anchors.filter { $0.objectID == deviceID }.sorted { $0.id < $1.id },
            interfaces: interfaces,
            assignments: snapshot.assignments.values
                .filter { $0.isActive && interfaceIDs.contains($0.interfaceID) }.sorted { $0.id < $1.id },
            memberships: snapshot.memberships.values
                .filter { $0.isActive && interfaceIDs.contains($0.interfaceID) }.sorted { $0.id < $1.id },
            addresses: snapshot.addresses.values.filter { address in
                address.isActive && address.assignedInterfaceID.map { interfaceIDs.contains($0) } == true
            }.sorted { $0.id < $1.id }
        )
    }

    private func validateDecommission(_ expected: PlannedDeviceDecommission, deviceID: ObjectID, state: DeviceDecommissionState, snapshot: Snapshot) throws {
        guard expected.device.id == deviceID,
            snapshot.topology.devices.first(where: { $0.id == deviceID }) == expected.device,
            state.modules == expected.modules,
            state.ports == expected.ports,
            state.placements == expected.rackPlacements,
            state.anchors == expected.floorPlanAnchors
        else {
            throw ProductionMutationPlannerError.staleDeviceDecommission(.object(deviceID))
        }
        guard state.interfaces == expected.interfaces,
            state.assignments == expected.addressAssignments,
            state.memberships == expected.vlanMemberships,
            state.addresses == expected.addresses
        else {
            throw ProductionMutationPlannerError.staleDeviceDecommission(.object(deviceID))
        }
    }

    private func removePlacementState(
        _ state: DeviceDecommissionState, deviceID: ObjectID, snapshot: inout Snapshot, changes: inout ChangeAccumulator
    ) throws {
        for placement in state.placements {
            try changes.tombstone(
                placement,
                resourceKey: .rackPlacement(deviceID: placement.deviceID),
                recordType: "RackPlacement"
            )
        }
        snapshot.placements.removeAll { $0.deviceID == deviceID }
        for anchor in state.anchors { try changes.tombstone(anchor, recordType: "FloorPlanAnchor") }
        snapshot.anchors.removeAll { $0.objectID == deviceID }
    }

    private func removeIPAMState(_ state: DeviceDecommissionState, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        for assignment in state.assignments {
            snapshot.assignments.removeValue(forKey: assignment.id)
            try changes.tombstone(assignment, recordType: "IPAddressAssignment")
        }
        for membership in state.memberships {
            snapshot.memberships.removeValue(forKey: membership.id)
            try changes.tombstone(membership, recordType: "InterfaceVLANMembership")
        }
        for address in state.addresses {
            var unassigned = address
            unassigned.assignedInterfaceID = nil
            snapshot.addresses[address.id] = unassigned
            try changes.saveStringKeyed(unassigned, resourceKey: .string(unassigned.id), recordType: "IPAddressRecord")
        }
        for interface in state.interfaces {
            var tombstoned = interface
            tombstoned.tombstone(at: changes.deletedAt)
            snapshot.interfaces[interface.id] = tombstoned
            try changes.save(tombstoned, recordType: "Interface")
        }
    }

    func rackPlacementOrder(_ lhs: RackPlacement, _ rhs: RackPlacement) -> Bool {
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
        if lhs.rackID != rhs.rackID { return lhs.rackID < rhs.rackID }
        if lhs.face.rawValue != rhs.face.rawValue { return lhs.face.rawValue < rhs.face.rawValue }
        if lhs.startRU != rhs.startRU { return lhs.startRU < rhs.startRU }
        return lhs.heightRU < rhs.heightRU
    }
}
