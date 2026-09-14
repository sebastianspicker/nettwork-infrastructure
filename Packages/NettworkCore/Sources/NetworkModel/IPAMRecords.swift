import Foundation

public struct IPAddressRecord: Identifiable, Codable, Hashable, Sendable {
    /// CloudKit-compatible deterministic record name, not a mutable display label.
    public let id: String
    public var vrfID: ObjectID
    public var address: IPAddress
    /// Compatibility mirror of the one active `IPAddressAssignment` relationship.
    public var assignedInterfaceID: ObjectID?
    public var state: IPAMRecordState
    public var tombstonedAt: Date?
    public init(vrfID: ObjectID, address: IPAddress, assignedInterfaceID: ObjectID? = nil, state: IPAMRecordState = .active, tombstonedAt: Date? = nil) {
        self.id = Self.deterministicRecordName(vrfID: vrfID, address: address)
        self.vrfID = vrfID
        self.address = address
        self.assignedInterfaceID = assignedInterfaceID
        self.state = state
        self.tombstonedAt = tombstonedAt
    }
    public var recordName: String { id }
    public var isActive: Bool { state == .active }
    public static func deterministicID(vrfID: ObjectID, address: IPAddress) -> String { deterministicRecordName(vrfID: vrfID, address: address) }
    public static func deterministicRecordName(vrfID: ObjectID, address: IPAddress) -> String { "ip:\(vrfID.description):\(address.description)" }
    public mutating func tombstone(at date: Date = .now) {
        state = .tombstoned
        tombstonedAt = date
        assignedInterfaceID = nil
    }
    public mutating func reactivate() throws {
        guard state == .tombstoned else { throw IPAMLifecycleError.recordAlreadyActive(id) }
        state = .active
        tombstonedAt = nil
    }
}
public struct VLANGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var name: String
    public var state: IPAMRecordState
    public var tombstonedAt: Date?
    public init(id: ObjectID = .init(), name: String, state: IPAMRecordState = .active, tombstonedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.tombstonedAt = tombstonedAt
    }
    public var isActive: Bool { state == .active }
    public mutating func tombstone(at date: Date = .now) {
        state = .tombstoned
        tombstonedAt = date
    }
    public mutating func reactivate() throws {
        guard state == .tombstoned else { throw IPAMLifecycleError.recordAlreadyActive(id.description) }
        state = .active
        tombstonedAt = nil
    }
}

public struct VLAN: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var groupID: ObjectID
    public var number: Int
    public var name: String
    public var state: IPAMRecordState
    public var tombstonedAt: Date?
    public init(id: ObjectID = .init(), groupID: ObjectID, number: Int, name: String, state: IPAMRecordState = .active, tombstonedAt: Date? = nil) {
        self.id = id
        self.groupID = groupID
        self.number = number
        self.name = name
        self.state = state
        self.tombstonedAt = tombstonedAt
    }
    public var isActive: Bool { state == .active }
    public mutating func tombstone(at date: Date = .now) {
        state = .tombstoned
        tombstonedAt = date
    }
    public mutating func reactivate() throws {
        guard state == .tombstoned else { throw IPAMLifecycleError.recordAlreadyActive(id.description) }
        state = .active
        tombstonedAt = nil
    }
}

public enum InterfaceMode: String, Codable, Hashable, Sendable { case access, trunk, routed }
public enum InterfaceKind: String, Codable, Hashable, Sendable { case physical, loopback, vlan }

public struct Interface: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var deviceID: ObjectID
    public var physicalPortID: ObjectID?
    public var name: String
    public var mode: InterfaceMode
    public var kind: InterfaceKind
    public var vlanID: ObjectID?
    public var state: IPAMRecordState
    public var tombstonedAt: Date?
    public init(
        id: ObjectID = .init(), deviceID: ObjectID, physicalPortID: ObjectID? = nil, name: String, mode: InterfaceMode, kind: InterfaceKind = .physical,
        vlanID: ObjectID? = nil, state: IPAMRecordState = .active,
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.physicalPortID = physicalPortID
        self.name = name
        self.mode = mode
        self.kind = kind
        self.vlanID = vlanID
        self.state = state
        self.tombstonedAt = tombstonedAt
    }
    public var isActive: Bool { state == .active }
    public mutating func tombstone(at date: Date = .now) {
        state = .tombstoned
        tombstonedAt = date
    }
    public mutating func reactivate() throws {
        guard state == .tombstoned else { throw IPAMLifecycleError.recordAlreadyActive(id.description) }
        state = .active
        tombstonedAt = nil
    }
}

public struct IPAddressAssignment: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var addressID: String
    public var interfaceID: ObjectID
    public var isPrimary: Bool
    public var state: IPAMRecordState
    public var tombstonedAt: Date?
    public init(
        id: ObjectID = .init(), addressID: String, interfaceID: ObjectID, isPrimary: Bool = false, state: IPAMRecordState = .active, tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.addressID = addressID
        self.interfaceID = interfaceID
        self.isPrimary = isPrimary
        self.state = state
        self.tombstonedAt = tombstonedAt
    }
    public var isActive: Bool { state == .active }
    public mutating func tombstone(at date: Date = .now) {
        state = .tombstoned
        tombstonedAt = date
    }
    public mutating func reactivate() throws {
        guard state == .tombstoned else { throw IPAMLifecycleError.recordAlreadyActive(id.description) }
        state = .active
        tombstonedAt = nil
    }
}

public struct InterfaceVLANMembership: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var interfaceID: ObjectID
    public var vlanID: ObjectID
    public var isNative: Bool
    public var state: IPAMRecordState
    public var tombstonedAt: Date?
    public init(
        id: ObjectID = .init(), interfaceID: ObjectID, vlanID: ObjectID, isNative: Bool = false, state: IPAMRecordState = .active, tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.interfaceID = interfaceID
        self.vlanID = vlanID
        self.isNative = isNative
        self.state = state
        self.tombstonedAt = tombstonedAt
    }
    public var isActive: Bool { state == .active }
    public mutating func tombstone(at date: Date = .now) {
        state = .tombstoned
        tombstonedAt = date
    }
    public mutating func reactivate() throws {
        guard state == .tombstoned else { throw IPAMLifecycleError.recordAlreadyActive(id.description) }
        state = .active
        tombstonedAt = nil
    }
}

public enum IPAMLifecycleError: Error, Hashable, Sendable {
    case tombstonedRecord(String)
    case recordAlreadyActive(String)
}

public struct AddressReassignmentResult: Codable, Hashable, Sendable {
    public var address: IPAddressRecord
    public var assignments: [IPAddressAssignment]
    public init(address: IPAddressRecord, assignments: [IPAddressAssignment]) {
        self.address = address
        self.assignments = assignments
    }
}

/// Reassignment tombstones the prior active relationship and creates the next one atomically in the returned value.
public enum IPAMAddressLifecycle {
    public static func reassign(address: IPAddressRecord, assignments: [IPAddressAssignment], to interface: Interface?, at date: Date = .now) throws
        -> AddressReassignmentResult
    {
        guard address.isActive else { throw IPAMLifecycleError.tombstonedRecord(address.id) }
        if let interface, !interface.isActive { throw IPAMLifecycleError.tombstonedRecord(interface.id.description) }
        var updatedAssignments = assignments
        for index in updatedAssignments.indices where updatedAssignments[index].isActive && updatedAssignments[index].addressID == address.id {
            updatedAssignments[index].tombstone(at: date)
        }
        var updatedAddress = address
        updatedAddress.assignedInterfaceID = interface?.id
        if let interface { updatedAssignments.append(IPAddressAssignment(addressID: address.id, interfaceID: interface.id, isPrimary: true)) }
        return AddressReassignmentResult(address: updatedAddress, assignments: updatedAssignments)
    }
}

public enum IPAMValidationError: Error, Hashable, Sendable {
    case invalidPrefix(ObjectID)
    case duplicatePrefix(Prefix, Prefix)
    case partialPrefixOverlap(Prefix, Prefix)
    case invalidReservedRange(prefixID: ObjectID)
    case overlappingReservedRange(prefixID: ObjectID)
    case invalidVLAN(ObjectID)
    case duplicateVLAN(groupID: ObjectID, number: Int)
    case duplicateAddress(String)
    case addressOutsidePrefixes(String)
    case addressReserved(String)
    case revisionConflict(vrfID: ObjectID, expected: Int, actual: Int)
    case revisionOverflow(ObjectID)
    case crossVRFPrefixMutation(ObjectID)
    case missingAddressAssignment(String)
    case missingInterfaceAssignment(ObjectID)
    case inconsistentAddressAssignment(String)
    case duplicateAddressAssignment(String)
    case invalidPrimaryAddress(ObjectID)
    case duplicateInterface(ObjectID)
    case invalidInterface(ObjectID)
    case missingVLANMembership(ObjectID)
    case duplicateVLANMembership(interfaceID: ObjectID, vlanID: ObjectID)
    case invalidNativeVLAN(ObjectID)
    case invalidInterfaceVLANMode(ObjectID)
}
