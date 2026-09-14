import Foundation
import NetworkModel

public struct EvidenceHash: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public let digest: IntentDigest
    public let contentType: String
    public init(id: ObjectID, digest: IntentDigest, contentType: String) {
        self.id = id
        self.digest = digest
        self.contentType = contentType
    }
}

public enum PlannedIPAMOperation: Codable, Hashable, Sendable {
    case prefixLayout(vrf: VRF, expectedRevision: Int, currentPrefixes: [Prefix], desiredPrefixes: [Prefix])
    case addressAssignment(InterfaceAddressAssignmentSet)
    case vlanMembership(InterfaceVLANMembershipSet)
    /// Decode-only v1 shapes. They retain the acknowledged digest for archive
    /// and reconciliation, but the production planner refuses to execute them
    /// because they do not bind a complete relationship set.
    case legacyAddressAssignment(addressKey: ResourceKey, interfaceID: ObjectID)
    case legacyVLANMembership(interfaceID: ObjectID, vlanID: ObjectID, isNative: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind, vrf, expectedRevision, currentPrefixes, desiredPrefixes, assignments, memberships, addressKey, interfaceID, vlanID, isNative
    }
    private enum Kind: String, Codable { case prefixLayout, addressAssignment, vlanMembership }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .prefixLayout:
            let desired = try container.decode([Prefix].self, forKey: .desiredPrefixes)
            self = .prefixLayout(
                vrf: try container.decode(VRF.self, forKey: .vrf),
                expectedRevision: try container.decode(Int.self, forKey: .expectedRevision),
                currentPrefixes: try container.decodeIfPresent([Prefix].self, forKey: .currentPrefixes) ?? desired,
                desiredPrefixes: desired)
        case .addressAssignment:
            if let assignments = try container.decodeIfPresent(InterfaceAddressAssignmentSet.self, forKey: .assignments) {
                self = .addressAssignment(assignments)
            } else {
                self = .legacyAddressAssignment(
                    addressKey: try container.decode(ResourceKey.self, forKey: .addressKey),
                    interfaceID: try container.decode(ObjectID.self, forKey: .interfaceID))
            }
        case .vlanMembership:
            if let memberships = try container.decodeIfPresent(InterfaceVLANMembershipSet.self, forKey: .memberships) {
                self = .vlanMembership(memberships)
            } else {
                self = .legacyVLANMembership(
                    interfaceID: try container.decode(ObjectID.self, forKey: .interfaceID),
                    vlanID: try container.decode(ObjectID.self, forKey: .vlanID),
                    isNative: try container.decode(Bool.self, forKey: .isNative)
                )
            }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .prefixLayout(vrf, expectedRevision, currentPrefixes, desiredPrefixes):
            try container.encode(Kind.prefixLayout, forKey: .kind)
            try container.encode(vrf, forKey: .vrf)
            try container.encode(expectedRevision, forKey: .expectedRevision)
            try container.encode(currentPrefixes, forKey: .currentPrefixes)
            try container.encode(desiredPrefixes, forKey: .desiredPrefixes)
        case let .addressAssignment(assignments):
            try container.encode(Kind.addressAssignment, forKey: .kind)
            try container.encode(assignments, forKey: .assignments)
        case let .vlanMembership(memberships):
            try container.encode(Kind.vlanMembership, forKey: .kind)
            try container.encode(memberships, forKey: .memberships)
        case let .legacyAddressAssignment(addressKey, interfaceID):
            try container.encode(Kind.addressAssignment, forKey: .kind)
            try container.encode(addressKey, forKey: .addressKey)
            try container.encode(interfaceID, forKey: .interfaceID)
        case let .legacyVLANMembership(interfaceID, vlanID, isNative):
            try container.encode(Kind.vlanMembership, forKey: .kind)
            try container.encode(interfaceID, forKey: .interfaceID)
            try container.encode(vlanID, forKey: .vlanID)
            try container.encode(isNative, forKey: .isNative)
        }
    }
}

/// The full active address relationship set for one interface. `primaryAddressID`
/// is explicit so a primary demotion or removal cannot be inferred at execution.
public struct InterfaceAddressAssignmentSet: Codable, Hashable, Sendable {
    public let revisionVRF: VRF
    public let interfaceID: ObjectID
    public let currentAssignments: [IPAddressAssignment]
    public let desiredAssignments: [IPAddressAssignment]
    public let primaryAddressID: String?

    public init(
        revisionVRF: VRF,
        interfaceID: ObjectID,
        currentAssignments: [IPAddressAssignment],
        desiredAssignments: [IPAddressAssignment],
        primaryAddressID: String?
    ) {
        self.revisionVRF = revisionVRF
        self.interfaceID = interfaceID
        self.currentAssignments = currentAssignments.sorted(by: IPAMRelationshipSetOrdering.assignments)
        self.desiredAssignments = desiredAssignments.sorted(by: IPAMRelationshipSetOrdering.assignments)
        self.primaryAddressID = primaryAddressID
    }
}

/// The full active VLAN relationship set for one interface. The complete set
/// makes access replacement, trunk removal, and native-VLAN switching atomic.
public struct InterfaceVLANMembershipSet: Codable, Hashable, Sendable {
    /// VLANs are workspace-wide in v1; the selected exact VRF is the explicit
    /// IPAM revision serialization scope for the relationship mutation.
    public let revisionVRF: VRF
    public let interfaceID: ObjectID
    public let currentMemberships: [InterfaceVLANMembership]
    public let desiredMemberships: [InterfaceVLANMembership]

    public init(
        revisionVRF: VRF,
        interfaceID: ObjectID,
        currentMemberships: [InterfaceVLANMembership],
        desiredMemberships: [InterfaceVLANMembership]
    ) {
        self.revisionVRF = revisionVRF
        self.interfaceID = interfaceID
        self.currentMemberships = currentMemberships.sorted(by: IPAMRelationshipSetOrdering.memberships)
        self.desiredMemberships = desiredMemberships.sorted(by: IPAMRelationshipSetOrdering.memberships)
    }
}

enum IPAMRelationshipSetOrdering {
    static func assignments(_ lhs: IPAddressAssignment, _ rhs: IPAddressAssignment) -> Bool {
        lhs.id == rhs.id ? lhs.addressID < rhs.addressID : lhs.id < rhs.id
    }

    static func memberships(_ lhs: InterfaceVLANMembership, _ rhs: InterfaceVLANMembership) -> Bool {
        lhs.id == rhs.id ? lhs.vlanID < rhs.vlanID : lhs.id < rhs.id
    }
}

public enum PlannedTemplateChangeKind: String, Codable, Hashable, Sendable {
    case create, clone, newVersion, migration
}

/// A device removal captures every physical and logical dependent record that
/// must be detached with the device. The planner compares this snapshot
/// exactly before applying the topology removal, so placement, floor-plan, or
/// IPAM relationship changes cannot be silently overwritten by an old work
/// order.
public struct PlannedDeviceDecommission: Codable, Hashable, Sendable {
    public let removal: RemoveTopologyCommand
    public let device: Device
    public let modules: [Module]
    public let ports: [NetworkModel.Port]
    public let rackPlacements: [RackPlacement]
    public let floorPlanAnchors: [FloorPlanAnchor]
    public let interfaces: [Interface]
    public let addressAssignments: [IPAddressAssignment]
    public let vlanMemberships: [InterfaceVLANMembership]
    public let addresses: [IPAddressRecord]

    private enum CodingKeys: String, CodingKey {
        case removal, device, modules, ports, rackPlacements, floorPlanAnchors
        case interfaces, addressAssignments, vlanMemberships, addresses
    }

    public init(
        removal: RemoveTopologyCommand,
        device: Device,
        modules: [Module],
        ports: [NetworkModel.Port],
        rackPlacements: [RackPlacement],
        floorPlanAnchors: [FloorPlanAnchor],
        interfaces: [Interface],
        addressAssignments: [IPAddressAssignment],
        vlanMemberships: [InterfaceVLANMembership],
        addresses: [IPAddressRecord]
    ) {
        self.removal = removal
        self.device = device
        self.modules = modules.sorted { $0.id < $1.id }
        self.ports = ports.sorted { $0.id < $1.id }
        self.rackPlacements = rackPlacements.sorted {
            if $0.deviceID != $1.deviceID { return $0.deviceID < $1.deviceID }
            if $0.rackID != $1.rackID { return $0.rackID < $1.rackID }
            if $0.face.rawValue != $1.face.rawValue { return $0.face.rawValue < $1.face.rawValue }
            if $0.startRU != $1.startRU { return $0.startRU < $1.startRU }
            return $0.heightRU < $1.heightRU
        }
        self.floorPlanAnchors = floorPlanAnchors.sorted { $0.id < $1.id }
        self.interfaces = interfaces.sorted { $0.id < $1.id }
        self.addressAssignments = addressAssignments.sorted { $0.id < $1.id }
        self.vlanMemberships = vlanMemberships.sorted { $0.id < $1.id }
        self.addresses = addresses.sorted { $0.id < $1.id }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            removal: try container.decode(RemoveTopologyCommand.self, forKey: .removal),
            device: try container.decode(Device.self, forKey: .device),
            modules: try container.decode([Module].self, forKey: .modules),
            ports: try container.decode([NetworkModel.Port].self, forKey: .ports),
            rackPlacements: try container.decode([RackPlacement].self, forKey: .rackPlacements),
            floorPlanAnchors: try container.decode([FloorPlanAnchor].self, forKey: .floorPlanAnchors),
            interfaces: try container.decodeIfPresent([Interface].self, forKey: .interfaces) ?? [],
            addressAssignments: try container.decodeIfPresent([IPAddressAssignment].self, forKey: .addressAssignments) ?? [],
            vlanMemberships: try container.decodeIfPresent([InterfaceVLANMembership].self, forKey: .vlanMemberships) ?? [],
            addresses: try container.decodeIfPresent([IPAddressRecord].self, forKey: .addresses) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(removal, forKey: .removal)
        try container.encode(device, forKey: .device)
        try container.encode(modules, forKey: .modules)
        try container.encode(ports, forKey: .ports)
        try container.encode(rackPlacements, forKey: .rackPlacements)
        try container.encode(floorPlanAnchors, forKey: .floorPlanAnchors)
        try container.encode(interfaces, forKey: .interfaces)
        try container.encode(addressAssignments, forKey: .addressAssignments)
        try container.encode(vlanMemberships, forKey: .vlanMemberships)
        try container.encode(addresses, forKey: .addresses)
    }

    /// Reservations protect every record removed by this compound operation,
    /// including the separate rack-placement identity and each anchor's floor
    /// ownership relationship.
    public var resourceKeys: Set<ResourceKey> {
        var keys: Set<ResourceKey> = [.object(device.id), .rackPlacement(deviceID: device.id)]
        keys.formUnion(modules.map { .object($0.id) })
        keys.formUnion(ports.map { .object($0.id) })
        for placement in rackPlacements {
            keys.formUnion([.rackPlacement(deviceID: placement.deviceID), .object(placement.rackID)])
        }
        if let rackID = device.rackID { keys.insert(.object(rackID)) }
        for anchor in floorPlanAnchors {
            keys.formUnion([.object(anchor.id), .object(anchor.objectID), .object(anchor.floorID)])
        }
        for interface in interfaces {
            keys.insert(.object(interface.id))
            if let physicalPortID = interface.physicalPortID { keys.insert(.object(physicalPortID)) }
            if let vlanID = interface.vlanID { keys.insert(.object(vlanID)) }
        }
        for assignment in addressAssignments {
            keys.formUnion([.object(assignment.id), .string(assignment.addressID), .object(assignment.interfaceID)])
        }
        for membership in vlanMemberships {
            keys.formUnion([.object(membership.id), .object(membership.interfaceID), .object(membership.vlanID)])
        }
        for address in addresses {
            keys.insert(.string(address.id))
            if let interfaceID = address.assignedInterfaceID { keys.insert(.object(interfaceID)) }
        }
        return keys
    }
}

/// A floor-plan change is intentionally an anchor-level operation. It never
/// carries untrusted attachment content and can therefore be validated against
/// the hierarchy, placement, and topology aggregates before materialization.
public enum PlannedFloorPlanOperation: Codable, Hashable, Sendable {
    case upsert(FloorPlanAnchor)
    case remove(FloorPlanAnchor)
    case bindAsset(PlannedFloorPlanAsset)

    private enum CodingKeys: String, CodingKey { case kind, anchor, asset }
    private enum Kind: String, Codable { case upsert, remove, bindAsset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .upsert: self = .upsert(try container.decode(FloorPlanAnchor.self, forKey: .anchor))
        case .remove: self = .remove(try container.decode(FloorPlanAnchor.self, forKey: .anchor))
        case .bindAsset: self = .bindAsset(try container.decode(PlannedFloorPlanAsset.self, forKey: .asset))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsert(let anchor):
            try container.encode(Kind.upsert, forKey: .kind)
            try container.encode(anchor, forKey: .anchor)
        case .remove(let anchor):
            try container.encode(Kind.remove, forKey: .kind)
            try container.encode(anchor, forKey: .anchor)
        case .bindAsset(let asset):
            try container.encode(Kind.bindAsset, forKey: .kind)
            try container.encode(asset, forKey: .asset)
        }
    }

    /// Every anchor mutation protects its record plus the anchored object and
    /// floor that establish its placement ownership.
    public var resourceKeys: Set<ResourceKey> {
        switch self {
        case .upsert(let anchor), .remove(let anchor):
            return [.object(anchor.id), .object(anchor.objectID), .object(anchor.floorID)]
        case .bindAsset(let asset):
            return [.object(asset.floorID), .floorPlanAssetBinding(for: asset.floorID)]
        }
    }
}

/// A hierarchy change carries the complete target or the exact live object to
/// remove. Parent keys are part of the reservation set, so a concurrent move
/// or deletion cannot silently invalidate the containment relationship.
public enum PlannedHierarchyOperation: Codable, Hashable, Sendable {
    case upsertLocation(Location)
    case removeLocation(Location)
    case upsertRack(Rack)
    case removeRack(Rack)

    private enum CodingKeys: String, CodingKey { case kind, location, rack }
    private enum Kind: String, Codable { case upsertLocation, removeLocation, upsertRack, removeRack }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .upsertLocation: self = .upsertLocation(try container.decode(Location.self, forKey: .location))
        case .removeLocation: self = .removeLocation(try container.decode(Location.self, forKey: .location))
        case .upsertRack: self = .upsertRack(try container.decode(Rack.self, forKey: .rack))
        case .removeRack: self = .removeRack(try container.decode(Rack.self, forKey: .rack))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsertLocation(let location):
            try container.encode(Kind.upsertLocation, forKey: .kind)
            try container.encode(location, forKey: .location)
        case .removeLocation(let location):
            try container.encode(Kind.removeLocation, forKey: .kind)
            try container.encode(location, forKey: .location)
        case .upsertRack(let rack):
            try container.encode(Kind.upsertRack, forKey: .kind)
            try container.encode(rack, forKey: .rack)
        case .removeRack(let rack):
            try container.encode(Kind.removeRack, forKey: .kind)
            try container.encode(rack, forKey: .rack)
        }
    }

    public var resourceKeys: Set<ResourceKey> {
        switch self {
        case let .upsertLocation(location), let .removeLocation(location):
            var keys: Set<ResourceKey> = [.object(location.id)]
            if let parentID = location.parentID { keys.insert(.object(parentID)) }
            return keys
        case let .upsertRack(rack), let .removeRack(rack):
            return [.object(rack.id), .object(rack.locationID)]
        }
    }
}
