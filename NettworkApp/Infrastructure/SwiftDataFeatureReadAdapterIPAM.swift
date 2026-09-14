import CloudSync
import ContentSafety
import CryptoKit
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataFeatureReadAdapter {
    func vrfs(in namespace: PersistenceNamespace) async throws -> [VRFSnapshot] {
        let projection = try await readProjection(in: namespace)
        return projection.vrfs.filter(\.isActive).map { vrf in
            let flags = projection.workflowFlags(for: .object(vrf.id))
            return VRFSnapshot(
                value: vrf, id: vrf.id, name: vrf.name, revision: vrf.revision, state: vrf.state, isPlanned: flags.isPlanned,
                isPending: flags.isPending, isConflicted: flags.isConflicted
            )
        }.sorted { lexicalLess([$0.name, $0.id.description], [$1.name, $1.id.description]) }
    }

    func prefixes(in namespace: PersistenceNamespace) async throws -> [IPAMPrefixSnapshot] {
        let projection = try await readProjection(in: namespace)
        return projection.prefixes.filter(\.isActive).map { prefix in
            let utilization = prefix.utilization(addresses: projection.addresses).consumedFraction
            let flags = projection.workflowFlags(for: .object(prefix.id))
            return IPAMPrefixSnapshot(
                value: prefix,
                id: prefix.id,
                vrfID: prefix.vrfID,
                cidr: prefix.cidr,
                name: prefix.name,
                utilization: utilization,
                state: prefix.state,
                reservedSummary: "\(prefix.reservedRanges.count) reserved range(s)",
                isPlanned: flags.isPlanned,
                isPending: flags.isPending,
                isConflicted: flags.isConflicted
            )
        }.sorted { lexicalLess([$0.cidr, $0.id.description], [$1.cidr, $1.id.description]) }
    }

    func addresses(prefixID: ObjectID, in namespace: PersistenceNamespace) async throws -> [IPAMAddressSnapshot] {
        let projection = try await readProjection(in: namespace)
        guard let prefix = projection.prefixes.first(where: { $0.id == prefixID && $0.isActive }) else { return [] }
        let interfaces = Dictionary(projection.interfaces.filter(\.isActive).map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let vlans = Dictionary(projection.vlans.filter(\.isActive).map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let assignmentsByAddress = Dictionary(grouping: projection.assignments.filter(\.isActive), by: \.addressID)
        return projection.addresses.filter { $0.isActive && $0.vrfID == prefix.vrfID && prefix.contains($0.address) }.map { address in
            let interface = address.assignedInterfaceID.flatMap { interfaces[$0] }
            let flags = projection.workflowFlags(for: .string(address.id))
            return IPAMAddressSnapshot(
                id: Self.stableObjectID(address.id),
                resourceKey: .string(address.id),
                address: address.address.description,
                interfaceName: interface?.name,
                vlanName: interface?.vlanID.flatMap { vlans[$0]?.name },
                assignments: (assignmentsByAddress[address.id] ?? []).sorted { $0.id < $1.id },
                state: address.state,
                isPlanned: flags.isPlanned,
                isPending: flags.isPending,
                isConflicted: flags.isConflicted
            )
        }.sorted { lexicalLess([$0.address, $0.id.description], [$1.address, $1.id.description]) }
    }

    func vlans(in namespace: PersistenceNamespace) async throws -> [VLANSnapshot] {
        let projection = try await readProjection(in: namespace)
        let groups = Dictionary(projection.vlanGroups.filter(\.isActive).map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        return projection.vlans.filter(\.isActive).compactMap { vlan in
            guard let group = groups[vlan.groupID] else { return nil }
            let flags = projection.workflowFlags(for: .object(vlan.id))
            return VLANSnapshot(
                id: vlan.id, groupName: group.name, number: vlan.number, name: vlan.name, state: vlan.state, isPlanned: flags.isPlanned,
                isPending: flags.isPending, isConflicted: flags.isConflicted
            )
        }.sorted { lhs, rhs in
            if lhs.groupName != rhs.groupName { return lhs.groupName < rhs.groupName }
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            return lhs.id < rhs.id
        }
    }

    func interfaces(in namespace: PersistenceNamespace) async throws -> [LogicalInterfaceSnapshot] {
        let projection = try await readProjection(in: namespace)
        let devices = Dictionary(projection.topology.devices.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let ports = Dictionary(projection.topology.ports.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let vlans = Dictionary(projection.vlans.filter(\.isActive).map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let assignmentsByInterface = Dictionary(grouping: projection.assignments.filter(\.isActive), by: \.interfaceID)
        let membershipsByInterface = Dictionary(grouping: projection.memberships.filter(\.isActive), by: \.interfaceID)
        return projection.interfaces.filter(\.isActive).map { interface in
            let vlanSummary = interface.vlanID.flatMap { vlans[$0].map { "VLAN \($0.number) \($0.name)" } } ?? "No VLAN"
            let flags = projection.workflowFlags(for: .object(interface.id))
            return LogicalInterfaceSnapshot(
                id: interface.id,
                deviceName: devices[interface.deviceID]?.name ?? "Unknown device",
                name: interface.name,
                mode: interface.mode,
                physicalPortLabel: interface.physicalPortID.flatMap { ports[$0]?.label },
                vlanSummary: vlanSummary,
                addressAssignments: (assignmentsByInterface[interface.id] ?? []).sorted { $0.id < $1.id },
                vlanMemberships: (membershipsByInterface[interface.id] ?? []).sorted { $0.id < $1.id },
                isPlanned: flags.isPlanned,
                isPending: flags.isPending,
                isConflicted: flags.isConflicted
            )
        }.sorted { lexicalLess([$0.deviceName, $0.name, $0.id.description], [$1.deviceName, $1.name, $1.id.description]) }
    }

    func resolve(_ id: ObjectID, in namespace: PersistenceNamespace) async throws -> Bool {
        let projection = try await readProjection(in: namespace)
        return projection.inventoryResults.contains { $0.id == id && !$0.isTombstoned }
    }
}
