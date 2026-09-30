import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct VRFSnapshot: Identifiable, Equatable, Sendable {
    public let value: VRF
    public let id: ObjectID
    public let name: String
    public let revision: Int
    public let state: IPAMRecordState
    public let isPlanned: Bool
    public let isPending: Bool
    public let isConflicted: Bool

    public init(
        value: VRF, id: ObjectID, name: String, revision: Int, state: IPAMRecordState,
        isPlanned: Bool, isPending: Bool, isConflicted: Bool
    ) {
        self.value = value
        self.id = id
        self.name = name
        self.revision = revision
        self.state = state
        self.isPlanned = isPlanned
        self.isPending = isPending
        self.isConflicted = isConflicted
    }
}

public struct IPAMPrefixSnapshot: Identifiable, Equatable, Sendable {
    public let value: Prefix
    public let id: ObjectID
    public let vrfID: ObjectID
    public let cidr: String
    public let name: String
    public let utilization: Double
    public let state: IPAMRecordState
    public let reservedSummary: String
    public let isPlanned: Bool
    public let isPending: Bool
    public let isConflicted: Bool

    public init(
        value: Prefix, id: ObjectID, vrfID: ObjectID, cidr: String, name: String, utilization: Double,
        state: IPAMRecordState, reservedSummary: String, isPlanned: Bool, isPending: Bool, isConflicted: Bool
    ) {
        self.value = value
        self.id = id
        self.vrfID = vrfID
        self.cidr = cidr
        self.name = name
        self.utilization = utilization
        self.state = state
        self.reservedSummary = reservedSummary
        self.isPlanned = isPlanned
        self.isPending = isPending
        self.isConflicted = isConflicted
    }

    public var hasReservedRanges: Bool {
        !reservedSummary.localizedCaseInsensitiveContains("0 reserved range")
    }
}

public struct IPAMAddressSnapshot: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    /// Authoritative IP addresses are string-keyed by their deterministic
    /// record name. The display-only ObjectID must never cross the mutation
    /// boundary in its place.
    public let resourceKey: ResourceKey
    public let address: String
    public let interfaceName: String?
    public let vlanName: String?
    public let assignments: [IPAddressAssignment]
    public let state: IPAMRecordState
    public let isPlanned: Bool
    public let isPending: Bool
    public let isConflicted: Bool

    public init(
        id: ObjectID, resourceKey: ResourceKey, address: String, interfaceName: String?, vlanName: String?,
        assignments: [IPAddressAssignment], state: IPAMRecordState, isPlanned: Bool, isPending: Bool, isConflicted: Bool
    ) {
        self.id = id
        self.resourceKey = resourceKey
        self.address = address
        self.interfaceName = interfaceName
        self.vlanName = vlanName
        self.assignments = assignments
        self.state = state
        self.isPlanned = isPlanned
        self.isPending = isPending
        self.isConflicted = isConflicted
    }
}

public struct VLANSnapshot: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public let groupName: String
    public let number: Int
    public let name: String
    public let state: IPAMRecordState
    public let isPlanned: Bool
    public let isPending: Bool
    public let isConflicted: Bool

    public init(
        id: ObjectID, groupName: String, number: Int, name: String, state: IPAMRecordState,
        isPlanned: Bool, isPending: Bool, isConflicted: Bool
    ) {
        self.id = id
        self.groupName = groupName
        self.number = number
        self.name = name
        self.state = state
        self.isPlanned = isPlanned
        self.isPending = isPending
        self.isConflicted = isConflicted
    }
}

public struct LogicalInterfaceSnapshot: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public let deviceName: String
    public let name: String
    public let mode: InterfaceMode
    public let physicalPortLabel: String?
    public let vlanSummary: String
    public let addressAssignments: [IPAddressAssignment]
    public let vlanMemberships: [InterfaceVLANMembership]
    public let isPlanned: Bool
    public let isPending: Bool
    public let isConflicted: Bool

    public init(
        id: ObjectID, deviceName: String, name: String, mode: InterfaceMode, physicalPortLabel: String?, vlanSummary: String,
        addressAssignments: [IPAddressAssignment], vlanMemberships: [InterfaceVLANMembership],
        isPlanned: Bool, isPending: Bool, isConflicted: Bool
    ) {
        self.id = id
        self.deviceName = deviceName
        self.name = name
        self.mode = mode
        self.physicalPortLabel = physicalPortLabel
        self.vlanSummary = vlanSummary
        self.addressAssignments = addressAssignments
        self.vlanMemberships = vlanMemberships
        self.isPlanned = isPlanned
        self.isPending = isPending
        self.isConflicted = isConflicted
    }
}

public struct PrefixLayoutWorkOrderRequest: Equatable, Sendable {
    /// The scoped VRF snapshot and compare-and-swap revision define the layout
    /// that this request was reviewed against.
    public let vrf: VRF
    public var expectedRevision: Int { vrf.revision }
    /// Exact source members bind removals as well as creates/updates into the
    /// work-order resource set. The planner still rereads and conditionally
    /// commits the authoritative mirror versions.
    public let currentPrefixes: [Prefix]
    /// This is the complete desired layout, not a set of references to records
    /// that might change before the work order is accepted.
    public let desiredPrefixes: [Prefix]

    public init(vrf: VRF, currentPrefixes: [Prefix], desiredPrefixes: [Prefix]) {
        self.vrf = vrf
        self.currentPrefixes = currentPrefixes
        self.desiredPrefixes = desiredPrefixes
    }
}

public enum IPAMWorkOrderOperation: Equatable, Sendable {
    case prefixLayout(PrefixLayoutWorkOrderRequest)
    case addressAssignment(InterfaceAddressAssignmentSet)
    case vlanMembership(InterfaceVLANMembershipSet)
}

public struct IPAMWorkOrderRequest: Equatable, Sendable {
    public let title: String
    public let ticketID: String
    public let notes: String
    public let perVRFRevisionKey: ResourceKey
    public let operation: IPAMWorkOrderOperation

    public init(title: String, ticketID: String, notes: String, perVRFRevisionKey: ResourceKey, operation: IPAMWorkOrderOperation) {
        self.title = title
        self.ticketID = ticketID
        self.notes = notes
        self.perVRFRevisionKey = perVRFRevisionKey
        self.operation = operation
    }
}

public protocol IPAMBrowsing: Sendable {
    func vrfs(in namespace: PersistenceNamespace) async throws -> [VRFSnapshot]
    func prefixes(in namespace: PersistenceNamespace) async throws -> [IPAMPrefixSnapshot]
    func addresses(prefixID: ObjectID, in namespace: PersistenceNamespace) async throws -> [IPAMAddressSnapshot]
    func vlans(in namespace: PersistenceNamespace) async throws -> [VLANSnapshot]
    func interfaces(in namespace: PersistenceNamespace) async throws -> [LogicalInterfaceSnapshot]
}

public protocol IPAMWorkOrderDrafting: Sendable {
    func stage(_ request: IPAMWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
}
