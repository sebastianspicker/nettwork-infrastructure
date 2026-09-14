import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct VRFSnapshot: Identifiable, Equatable, Sendable {
    let value: VRF
    let id: ObjectID
    let name: String
    let revision: Int
    let state: IPAMRecordState
    let isPlanned: Bool
    let isPending: Bool
    let isConflicted: Bool
}

struct IPAMPrefixSnapshot: Identifiable, Equatable, Sendable {
    let value: Prefix
    let id: ObjectID
    let vrfID: ObjectID
    let cidr: String
    let name: String
    let utilization: Double
    let state: IPAMRecordState
    let reservedSummary: String
    let isPlanned: Bool
    let isPending: Bool
    let isConflicted: Bool

    var hasReservedRanges: Bool {
        !reservedSummary.localizedCaseInsensitiveContains("0 reserved range")
    }
}

struct IPAMAddressSnapshot: Identifiable, Equatable, Sendable {
    let id: ObjectID
    /// Authoritative IP addresses are string-keyed by their deterministic
    /// record name. The display-only ObjectID must never cross the mutation
    /// boundary in its place.
    let resourceKey: ResourceKey
    let address: String
    let interfaceName: String?
    let vlanName: String?
    let assignments: [IPAddressAssignment]
    let state: IPAMRecordState
    let isPlanned: Bool
    let isPending: Bool
    let isConflicted: Bool
}

struct VLANSnapshot: Identifiable, Equatable, Sendable {
    let id: ObjectID
    let groupName: String
    let number: Int
    let name: String
    let state: IPAMRecordState
    let isPlanned: Bool
    let isPending: Bool
    let isConflicted: Bool
}

struct LogicalInterfaceSnapshot: Identifiable, Equatable, Sendable {
    let id: ObjectID
    let deviceName: String
    let name: String
    let mode: InterfaceMode
    let physicalPortLabel: String?
    let vlanSummary: String
    let addressAssignments: [IPAddressAssignment]
    let vlanMemberships: [InterfaceVLANMembership]
    let isPlanned: Bool
    let isPending: Bool
    let isConflicted: Bool
}

struct PrefixLayoutWorkOrderRequest: Equatable, Sendable {
    /// The scoped VRF snapshot and compare-and-swap revision define the layout
    /// that this request was reviewed against.
    let vrf: VRF
    var expectedRevision: Int { vrf.revision }
    /// Exact source members bind removals as well as creates/updates into the
    /// work-order resource set. The planner still rereads and conditionally
    /// commits the authoritative mirror versions.
    let currentPrefixes: [Prefix]
    /// This is the complete desired layout, not a set of references to records
    /// that might change before the work order is accepted.
    let desiredPrefixes: [Prefix]
}

enum IPAMWorkOrderOperation: Equatable, Sendable {
    case prefixLayout(PrefixLayoutWorkOrderRequest)
    case addressAssignment(InterfaceAddressAssignmentSet)
    case vlanMembership(InterfaceVLANMembershipSet)
}

enum AddressAssignmentStagingAction: String, CaseIterable, Identifiable {
    case addSecondary = "Add secondary"
    case makePrimary = "Make primary"
    case unassign = "Unassign"

    var id: String { rawValue }
}

enum VLANMembershipStagingAction: String, CaseIterable, Identifiable {
    case add = "Add VLAN"
    case remove = "Remove VLAN"
    case makeNative = "Make native"

    var id: String { rawValue }
}

struct IPAMWorkOrderRequest: Equatable, Sendable {
    let title: String
    let ticketID: String
    let notes: String
    let perVRFRevisionKey: ResourceKey
    let operation: IPAMWorkOrderOperation
}

protocol IPAMBrowsing: Sendable {
    func vrfs(in namespace: PersistenceNamespace) async throws -> [VRFSnapshot]
    func prefixes(in namespace: PersistenceNamespace) async throws -> [IPAMPrefixSnapshot]
    func addresses(prefixID: ObjectID, in namespace: PersistenceNamespace) async throws -> [IPAMAddressSnapshot]
    func vlans(in namespace: PersistenceNamespace) async throws -> [VLANSnapshot]
    func interfaces(in namespace: PersistenceNamespace) async throws -> [LogicalInterfaceSnapshot]
}

protocol IPAMWorkOrderDrafting: Sendable {
    func stage(_ request: IPAMWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
}

enum IPAMWorkflowState: String {
    case authoritative = "Authoritative"
    case reserved = "Reserved"
    case planned = "Planned"
    case pending = "Pending"
    case conflicting = "Conflicting"

    var symbolName: String {
        switch self {
        case .authoritative: "checkmark.seal.fill"
        case .reserved: "lock.fill"
        case .planned: "calendar.badge.clock"
        case .pending: "clock.badge.checkmark"
        case .conflicting: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        statusRole.color
    }

    var statusRole: NettworkStatusRole {
        switch self {
        case .authoritative: .ready
        case .reserved: .reserved
        case .planned: .information
        case .pending: .pending
        case .conflicting: .conflict
        }
    }
}

struct VLANGroupPresentation: Identifiable {
    let name: String
    let vlans: [VLANSnapshot]

    var id: String { name }
}
