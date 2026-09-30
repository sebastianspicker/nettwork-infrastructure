import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum TopologyHierarchyKind: Sendable {
    case location(LocationKind)
    case rack
    case device
    case module
    case port

    public var title: String {
        switch self {
        case let .location(kind): kind.rawValue.capitalized
        case .rack: "Rack"
        case .device: "Device"
        case .module: "Module"
        case .port: "Port"
        }
    }

    public var symbolName: String {
        switch self {
        case .location: "building.2"
        case .rack: "server.rack"
        case .device: "cpu"
        case .module: "rectangle.3.group"
        case .port: "rectangle.portrait.and.arrow.forward"
        }
    }
}

public struct TopologyCableSnapshot: Identifiable, Sendable {
    public let id: ObjectID
    public let assetCode: AssetCode
    public let kind: CableKind
    public let medium: PortMedium
    public let connectorA: Connector
    public let connectorB: Connector
    public let status: CableStatus
    public let color: String?
    public let lengthMeters: Double?
    public let endpointA: ObjectID
    public let endpointB: ObjectID

    public init(
        id: ObjectID, assetCode: AssetCode, kind: CableKind, medium: PortMedium, connectorA: Connector, connectorB: Connector,
        status: CableStatus, color: String?, lengthMeters: Double?, endpointA: ObjectID, endpointB: ObjectID
    ) {
        self.id = id
        self.assetCode = assetCode
        self.kind = kind
        self.medium = medium
        self.connectorA = connectorA
        self.connectorB = connectorB
        self.status = status
        self.color = color
        self.lengthMeters = lengthMeters
        self.endpointA = endpointA
        self.endpointB = endpointB
    }

    public var summary: String {
        let colorSummary = color.map { " · \($0)" } ?? ""
        let lengthSummary = lengthMeters.map { " · \($0.formatted()) m" } ?? ""
        return "\(kind.rawValue) · \(medium.rawValue) · \(connectorA.rawValue)/\(connectorB.rawValue)\(colorSummary)\(lengthSummary)"
    }
}

public struct TopologyPortSnapshot: Identifiable, Sendable {
    public let id: ObjectID
    public let deviceID: ObjectID
    public let deviceName: String
    public let moduleID: ObjectID?
    public let moduleSlot: String?
    public let label: String
    public let faceName: String
    public let medium: PortMedium
    public let connector: Connector
    public let availability: PortAvailability
    public let state: PortState
    public let cable: TopologyCableSnapshot?
    /// The domain reservation record deliberately has no owner field. This
    /// string is explicitly unavailable rather than inferred.
    public let reservationOwner: String?
    public let warnings: [String]
    public let hasConflict: Bool

    public init(
        id: ObjectID, deviceID: ObjectID, deviceName: String, moduleID: ObjectID?, moduleSlot: String?, label: String,
        faceName: String, medium: PortMedium, connector: Connector, availability: PortAvailability, state: PortState,
        cable: TopologyCableSnapshot?, reservationOwner: String?, warnings: [String], hasConflict: Bool
    ) {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.moduleID = moduleID
        self.moduleSlot = moduleSlot
        self.label = label
        self.faceName = faceName
        self.medium = medium
        self.connector = connector
        self.availability = availability
        self.state = state
        self.cable = cable
        self.reservationOwner = reservationOwner
        self.warnings = warnings
        self.hasConflict = hasConflict
    }

    public var cableSummary: String? { cable.map { "\($0.assetCode.value) · \($0.status.rawValue)" } }
}

public struct TopologyHierarchyNode: Identifiable, Sendable {
    public let id: ObjectID
    public let parentID: ObjectID?
    public let kind: TopologyHierarchyKind
    public let name: String
    public let detail: String
    public let childCount: Int
    public let location: Location?
    public let rack: Rack?

    public init(
        id: ObjectID, parentID: ObjectID?, kind: TopologyHierarchyKind, name: String, detail: String,
        childCount: Int, location: Location?, rack: Rack?
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.name = name
        self.detail = detail
        self.childCount = childCount
        self.location = location
        self.rack = rack
    }
}

/// Immutable hierarchy lookup built once for an accepted topology load.
/// Nodes whose parent is absent remain visible as roots rather than being
/// dropped by the outline.
public struct TopologyHierarchyIndex: Sendable {
    public let nodes: [TopologyHierarchyNode]
    public let roots: [TopologyHierarchyNode]
    private let childrenByParent: [ObjectID: [TopologyHierarchyNode]]

    public init(nodes: [TopologyHierarchyNode] = []) {
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

    public var isEmpty: Bool { nodes.isEmpty }

    public func children(of parentID: ObjectID) -> [TopologyHierarchyNode] {
        childrenByParent[parentID] ?? []
    }

    private static func sorted(_ nodes: [TopologyHierarchyNode]) -> [TopologyHierarchyNode] {
        nodes.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

public struct RackElevationEntrySnapshot: Identifiable, Sendable {
    public let id: ObjectID
    public let name: String
    public let assetCode: AssetCode?
    public let startRU: Int
    public let heightRU: Int
    public let isReservation: Bool

    public init(id: ObjectID, name: String, assetCode: AssetCode?, startRU: Int, heightRU: Int, isReservation: Bool) {
        self.id = id
        self.name = name
        self.assetCode = assetCode
        self.startRU = startRU
        self.heightRU = heightRU
        self.isReservation = isReservation
    }

    public var endRU: Int { startRU + heightRU - 1 }
}

public struct RackElevationSnapshot: Identifiable, Sendable {
    public let id: String
    public let rackID: ObjectID
    public let assetCode: AssetCode
    public let heightRU: Int
    public let faceName: String
    public let entries: [RackElevationEntrySnapshot]
    public let ports: [TopologyPortSnapshot]

    public init(
        id: String, rackID: ObjectID, assetCode: AssetCode, heightRU: Int, faceName: String,
        entries: [RackElevationEntrySnapshot], ports: [TopologyPortSnapshot]
    ) {
        self.id = id
        self.rackID = rackID
        self.assetCode = assetCode
        self.heightRU = heightRU
        self.faceName = faceName
        self.entries = entries
        self.ports = ports
    }
}
