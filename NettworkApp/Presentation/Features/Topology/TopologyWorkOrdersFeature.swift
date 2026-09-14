import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

/// Stable presentation labels for aggregate port state and conflict messages.
/// Filters expose direct availability and aggregate state separately.
enum InventoryPortAvailability: String, CaseIterable, Identifiable, Hashable, Sendable {
    case available, occupied, reserved, planned, conflicted, unavailable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TopologyHierarchyKind: Sendable {
    case location(LocationKind)
    case rack
    case device
    case module
    case port

    var title: String {
        switch self {
        case let .location(kind): kind.rawValue.capitalized
        case .rack: "Rack"
        case .device: "Device"
        case .module: "Module"
        case .port: "Port"
        }
    }

    var symbolName: String {
        switch self {
        case .location: "building.2"
        case .rack: "server.rack"
        case .device: "cpu"
        case .module: "rectangle.3.group"
        case .port: "rectangle.portrait.and.arrow.forward"
        }
    }
}

enum TopologyPortAvailabilityFilter: String, CaseIterable, Identifiable, Sendable {
    case all, available, unavailable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TopologyPortStateFilter: String, CaseIterable, Identifiable, Sendable {
    case all, free, occupied, reserved, planned, unavailable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TopologyCableSnapshot: Identifiable, Sendable {
    let id: ObjectID
    let assetCode: AssetCode
    let kind: CableKind
    let medium: PortMedium
    let connectorA: Connector
    let connectorB: Connector
    let status: CableStatus
    let color: String?
    let lengthMeters: Double?
    let endpointA: ObjectID
    let endpointB: ObjectID

    var summary: String {
        let colorSummary = color.map { " · \($0)" } ?? ""
        let lengthSummary = lengthMeters.map { " · \($0.formatted()) m" } ?? ""
        return "\(kind.rawValue) · \(medium.rawValue) · \(connectorA.rawValue)/\(connectorB.rawValue)\(colorSummary)\(lengthSummary)"
    }
}

struct TopologyPortSnapshot: Identifiable, Sendable {
    let id: ObjectID
    let deviceID: ObjectID
    let deviceName: String
    let moduleID: ObjectID?
    let moduleSlot: String?
    let label: String
    let faceName: String
    let medium: PortMedium
    let connector: Connector
    let availability: PortAvailability
    let state: PortState
    let cable: TopologyCableSnapshot?
    /// The domain reservation record deliberately has no owner field. This
    /// string is explicitly unavailable rather than inferred.
    let reservationOwner: String?
    let warnings: [String]
    let hasConflict: Bool

    var cableSummary: String? { cable.map { "\($0.assetCode.value) · \($0.status.rawValue)" } }
}

struct TopologyHierarchyNode: Identifiable, Sendable {
    let id: ObjectID
    let parentID: ObjectID?
    let kind: TopologyHierarchyKind
    let name: String
    let detail: String
    let childCount: Int
    let location: Location?
    let rack: Rack?
}

/// Immutable hierarchy lookup built once for an accepted topology load.
/// Nodes whose parent is absent remain visible as roots rather than being
/// dropped by the outline.
struct TopologyHierarchyIndex: Sendable {
    let nodes: [TopologyHierarchyNode]
    let roots: [TopologyHierarchyNode]
    private let childrenByParent: [ObjectID: [TopologyHierarchyNode]]

    init(nodes: [TopologyHierarchyNode] = []) {
        self.nodes = nodes
        let nodeIDs = Set(nodes.map(\.id))
        roots = Self.sorted(
            nodes.filter { node in
                guard let parentID = node.parentID else { return true }
                return !nodeIDs.contains(parentID)
            })
        childrenByParent = Dictionary(
            grouping: nodes.compactMap { node in
                node.parentID.map { ($0, node) }
            }, by: \.0
        ).mapValues { Self.sorted($0.map(\.1)) }
    }

    var isEmpty: Bool { nodes.isEmpty }

    func children(of parentID: ObjectID) -> [TopologyHierarchyNode] {
        childrenByParent[parentID] ?? []
    }

    private static func sorted(_ nodes: [TopologyHierarchyNode]) -> [TopologyHierarchyNode] {
        nodes.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

struct RackElevationEntrySnapshot: Identifiable, Sendable {
    let id: ObjectID
    let name: String
    let assetCode: AssetCode?
    let startRU: Int
    let heightRU: Int
    let isReservation: Bool

    var endRU: Int { startRU + heightRU - 1 }
}

struct RackElevationSnapshot: Identifiable, Sendable {
    let id: String
    let rackID: ObjectID
    let assetCode: AssetCode
    let heightRU: Int
    let faceName: String
    let entries: [RackElevationEntrySnapshot]
    let ports: [TopologyPortSnapshot]
}

/// The mirror-derived source records bound into one typed device-removal
/// operation. Presentation may select a device, but it cannot synthesize or
/// infer its placement and floor-plan dependencies.
struct DeviceDecommissionSnapshot: Equatable, Sendable {
    let device: Device
    let modules: [Module]
    let ports: [NetworkModel.Port]
    let rackPlacements: [RackPlacement]
    let floorPlanAnchors: [FloorPlanAnchor]
    let interfaces: [Interface]
    let addressAssignments: [IPAddressAssignment]
    let vlanMemberships: [InterfaceVLANMembership]
    let addresses: [IPAddressRecord]
}

enum TopologyDraftAction: Equatable, Sendable {
    /// The complete desired cable, including its stable identity and physical
    /// attributes, is captured when the work order is staged.
    case connect(ConnectTopologyCommand)
    case disconnect(DisconnectTopologyCommand)
    case move(MoveTopologyCommand)
    case remove(RemoveTopologyCommand)
    case deviceDecommission(PlannedDeviceDecommission)
    case markUnavailable(MarkPortUnavailableTopologyCommand)
    case hierarchy(PlannedHierarchyOperation)
}

struct TopologyWorkOrderRequest: Equatable, Sendable {
    let title: String
    let ticket: String
    let notes: String
    let action: TopologyDraftAction
    let resourceKeys: Set<ResourceKey>
}

protocol TopologyBrowsing: Sendable {
    func hierarchy(in namespace: PersistenceNamespace) async throws -> [TopologyHierarchyNode]
    func racks(in namespace: PersistenceNamespace) async throws -> [RackElevationSnapshot]
    func deviceDecommissionSnapshot(for deviceID: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceDecommissionSnapshot
}

protocol TopologyWorkOrderDrafting: Sendable {
    func stage(_ request: TopologyWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
}
