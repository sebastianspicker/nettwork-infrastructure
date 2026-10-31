import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Creations add records the mirror does not contain, so the accumulator binds
/// each one with `mustNotExist`. Prefix containment, reserved ranges and
/// per-group VLAN numbers are enforced by the complete IPAM validation that
/// runs over the planned snapshot, the same rules a CSV import is held to.
extension SwiftDataProductionMutationPlanner {
    func applyCreation(_ creation: PlannedIPAMCreation, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        guard creation.isWellFormed else {
            throw ProductionMutationPlannerError.invalidIPAMCreation(creation.revisionKey)
        }
        switch creation {
        case .vrf(let vrf):
            try createVRF(vrf, snapshot: &snapshot, changes: &changes)
        case .addressRecord(let address):
            try createAddressRecord(address, snapshot: &snapshot, changes: &changes)
        case let .vlan(vlan, newGroup):
            try createVLAN(vlan, newGroup: newGroup, snapshot: &snapshot, changes: &changes)
        }
    }

    private func createVRF(_ vrf: VRF, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        guard snapshot.vrfs[vrf.id] == nil,
            !snapshot.vrfs.values.contains(where: { $0.isActive && Self.sameName($0.name, vrf.name) })
        else {
            throw ProductionMutationPlannerError.ipamRecordAlreadyExists(.object(vrf.id))
        }
        snapshot.vrfs[vrf.id] = vrf
        try changes.save(vrf, recordType: WorkspaceRecordType.Legacy.vrf)
    }

    private func createAddressRecord(_ address: IPAddressRecord, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        guard snapshot.vrfs[address.vrfID]?.isActive == true else {
            throw ProductionMutationPlannerError.invalidIPAMCreation(.object(address.vrfID))
        }
        guard snapshot.addresses[address.id] == nil else {
            throw ProductionMutationPlannerError.ipamRecordAlreadyExists(.string(address.id))
        }
        snapshot.addresses[address.id] = address
        try changes.saveStringKeyed(address, resourceKey: .string(address.id), recordType: WorkspaceRecordType.Legacy.ipAddressRecord)
    }

    private func createVLAN(_ vlan: VLAN, newGroup: VLANGroup?, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        guard snapshot.vlans[vlan.id] == nil else {
            throw ProductionMutationPlannerError.ipamRecordAlreadyExists(.object(vlan.id))
        }
        if let newGroup {
            guard snapshot.vlanGroups[newGroup.id] == nil,
                !snapshot.vlanGroups.values.contains(where: { $0.isActive && Self.sameName($0.name, newGroup.name) })
            else {
                throw ProductionMutationPlannerError.ipamRecordAlreadyExists(.object(newGroup.id))
            }
            snapshot.vlanGroups[newGroup.id] = newGroup
            try changes.save(newGroup, recordType: WorkspaceRecordType.vlanGroup)
        } else if snapshot.vlanGroups[vlan.groupID]?.isActive != true {
            throw ProductionMutationPlannerError.invalidIPAMCreation(.object(vlan.groupID))
        }
        snapshot.vlans[vlan.id] = vlan
        try changes.save(vlan, recordType: WorkspaceRecordType.Legacy.vlan)
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
