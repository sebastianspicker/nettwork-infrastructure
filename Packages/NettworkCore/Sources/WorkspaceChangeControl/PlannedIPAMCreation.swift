import Foundation
import NetworkModel

/// A new IPAM record staged through a work order. Each case carries the
/// complete record to create, so the planner binds it with a `mustNotExist`
/// precondition and validates it against the complete mirrored IPAM state.
public enum PlannedIPAMCreation: Codable, Hashable, Sendable {
    case vrf(VRF)
    case addressRecord(IPAddressRecord)
    /// `newGroup` is created with the VLAN when the VLAN scope does not exist
    /// yet; otherwise `vlan.groupID` must name an active mirrored group.
    case vlan(VLAN, newGroup: VLANGroup?)

    private enum CodingKeys: String, CodingKey { case kind, vrf, address, vlan, newGroup }
    private enum Kind: String, Codable { case vrf, addressRecord, vlan }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .vrf: self = .vrf(try container.decode(VRF.self, forKey: .vrf))
        case .addressRecord: self = .addressRecord(try container.decode(IPAddressRecord.self, forKey: .address))
        case .vlan:
            self = .vlan(try container.decode(VLAN.self, forKey: .vlan), newGroup: try container.decodeIfPresent(VLANGroup.self, forKey: .newGroup))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .vrf(let vrf):
            try container.encode(Kind.vrf, forKey: .kind)
            try container.encode(vrf, forKey: .vrf)
        case .addressRecord(let address):
            try container.encode(Kind.addressRecord, forKey: .kind)
            try container.encode(address, forKey: .address)
        case let .vlan(vlan, newGroup):
            try container.encode(Kind.vlan, forKey: .kind)
            try container.encode(vlan, forKey: .vlan)
            try container.encodeIfPresent(newGroup, forKey: .newGroup)
        }
    }

    /// The serialization scope of the creation: the VRF for VRFs and
    /// addresses, and the VLAN group for VLANs, because VLAN numbers are
    /// unique per group.
    public var revisionKey: ResourceKey {
        switch self {
        case .vrf(let vrf): .object(vrf.id)
        case .addressRecord(let address): .object(address.vrfID)
        case .vlan(let vlan, _): .object(vlan.groupID)
        }
    }

    /// The created records plus the scope that a concurrent prefix layout or
    /// VLAN creation reserves, so reservations serialize conflicting work.
    public var resourceKeys: Set<ResourceKey> {
        switch self {
        case .vrf(let vrf): [.object(vrf.id)]
        case .addressRecord(let address): [.string(address.id), .object(address.vrfID)]
        case .vlan(let vlan, _): [.object(vlan.id), .object(vlan.groupID)]
        }
    }

    /// Context-free shape checks shared by staging and planning. Containment,
    /// duplicate and reference rules need the mirror and run in the planner.
    public var isWellFormed: Bool {
        switch self {
        case .vrf(let vrf): Self.isWellFormed(vrf)
        case .addressRecord(let address): Self.isWellFormed(address)
        case let .vlan(vlan, newGroup): Self.isWellFormed(vlan, newGroup: newGroup)
        }
    }

    private static func isWellFormed(_ vrf: VRF) -> Bool {
        guard vrf.isActive, vrf.tombstonedAt == nil, vrf.revision == 0 else { return false }
        return isCanonicalName(vrf.name)
    }

    private static func isWellFormed(_ address: IPAddressRecord) -> Bool {
        guard address.isActive, address.tombstonedAt == nil, address.assignedInterfaceID == nil,
            IPAddress(parsing: address.address.description) == address.address
        else { return false }
        return address.id == IPAddressRecord.deterministicRecordName(vrfID: address.vrfID, address: address.address)
    }

    private static func isWellFormed(_ vlan: VLAN, newGroup: VLANGroup?) -> Bool {
        guard vlan.isActive, vlan.tombstonedAt == nil, (1...4094).contains(vlan.number), isCanonicalName(vlan.name) else { return false }
        guard let newGroup else { return true }
        guard newGroup.id == vlan.groupID, newGroup.isActive, newGroup.tombstonedAt == nil else { return false }
        return isCanonicalName(newGroup.name)
    }

    private static func isCanonicalName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == name
    }
}
