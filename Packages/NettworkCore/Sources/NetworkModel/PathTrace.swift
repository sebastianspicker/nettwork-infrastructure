import Foundation

public enum TraceSegmentKind: String, Codable, Hashable, Sendable { case cable, internalLink }

public struct TraceSegment: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public let kind: TraceSegmentKind
    public let fromPortID: ObjectID
    public let toPortID: ObjectID

    public init(id: ObjectID, kind: TraceSegmentKind, fromPortID: ObjectID, toPortID: ObjectID) {
        self.id = id
        self.kind = kind
        self.fromPortID = fromPortID
        self.toPortID = toPortID
    }
}

/// The source port is always `ports.first`. A terminal path ends at the final
/// port unless a cycle or broken record names a different termination target.
public struct PhysicalPath: Codable, Hashable, Sendable {
    public let ports: [ObjectID]
    public let segments: [TraceSegment]
    public let stoppedByCycle: Bool

    public init(ports: [ObjectID], segments: [TraceSegment], stoppedByCycle: Bool = false) {
        self.ports = ports
        self.segments = segments
        self.stoppedByCycle = stoppedByCycle
    }
}

public enum PathTraceError: Error, Hashable, Sendable { case unknownStartPort(ObjectID) }

/// Limits are enforced per request, rather than trusting imported topology to
/// remain tree-shaped. Values less than one are normalized to one.
public struct TraceTraversalLimits: Codable, Hashable, Sendable {
    public var maximumSegmentsPerPath: Int
    public var maximumPaths: Int

    public init(maximumSegmentsPerPath: Int = 512, maximumPaths: Int = 128) {
        self.maximumSegmentsPerPath = max(1, maximumSegmentsPerPath)
        self.maximumPaths = max(1, maximumPaths)
    }
}

public enum TraceResource: Codable, Hashable, Sendable {
    case port(ObjectID)
    case device(ObjectID)
    case cable(ObjectID)
    case internalLink(ObjectID)
    case rack(ObjectID)
    case location(ObjectID)
    case interface(ObjectID)
    case vlan(ObjectID)
    case ipAddress(String)

    var sortKey: String {
        "\(sortPrefix):\(sortIdentifier)"
    }

    private var sortPrefix: String {
        switch self {
        case .port: "port"
        case .device: "device"
        case .cable: "cable"
        case .internalLink: "internal"
        case .rack: "rack"
        case .location: "location"
        case .interface, .vlan, .ipAddress: secondarySortPrefix
        }
    }

    private var secondarySortPrefix: String {
        switch self {
        case .interface: "interface"
        case .vlan: "vlan"
        case .ipAddress: "ip"
        default: preconditionFailure("Unexpected primary trace resource")
        }
    }

    private var sortIdentifier: String {
        switch self {
        case let .ipAddress(value): value
        case let .port(id), let .device(id), let .cable(id), let .internalLink(id), let .rack(id), let .location(id), let .interface(id), let .vlan(id):
            id.description
        }
    }
}

public enum TraceWarning: Codable, Hashable, Sendable {
    case ambiguousContinuation(portID: ObjectID, count: Int)
    case incompletePassiveMapping(portID: ObjectID)
    case cycle(portID: ObjectID, through: TraceResource)
    case missingPort(ObjectID)
    case tombstonedResource(TraceResource)
    case unavailablePort(ObjectID)
    case unavailableCable(ObjectID)
    case tombstonedLogicalInterface(ObjectID)
    case tombstonedIPAddress(String)
    case tombstonedVLAN(ObjectID)
    case segmentLimitReached(Int)
    case pathLimitReached(Int)

    var sortKey: String {
        switch self {
        case .ambiguousContinuation(let id, let count): "ambiguous:\(id):\(count)"
        case .incompletePassiveMapping(let id): "incomplete:\(id)"
        case .cycle(let id, let resource): "cycle:\(id):\(resource.sortKey)"
        case .missingPort(let id), .unavailablePort(let id), .unavailableCable(let id), .tombstonedLogicalInterface(let id), .tombstonedVLAN(let id):
            "\(objectWarningPrefix):\(id)"
        case .tombstonedResource(let resource): "tombstone:\(resource.sortKey)"
        case .tombstonedIPAddress(let id): "tombstone-ip:\(id)"
        case .segmentLimitReached(let limit): "segment-limit:\(limit)"
        case .pathLimitReached(let limit): "path-limit:\(limit)"
        }
    }

    private var objectWarningPrefix: String {
        switch self {
        case .missingPort: "missing"
        case .unavailablePort: "unavailable-port"
        case .unavailableCable: "unavailable-cable"
        case .tombstonedLogicalInterface: "tombstone-interface"
        case .tombstonedVLAN: "tombstone-vlan"
        default: ""
        }
    }
}

public enum TraceTermination: Codable, Hashable, Sendable {
    case endpoint(portID: ObjectID)
    case incompletePassiveMapping(portID: ObjectID)
    case cycle(portID: ObjectID)
    case missingPort(ObjectID)
    case tombstonedResource(TraceResource)
    case segmentLimit
}

public struct TraceDeviceContext: Codable, Hashable, Sendable {
    public let id: ObjectID
    public let assetCode: AssetCode
    public let name: String
    public let rackID: ObjectID?
    public init(device: Device) {
        id = device.id
        assetCode = device.assetCode
        name = device.name
        rackID = device.rackID
    }
}

public struct TraceLocationContext: Codable, Hashable, Sendable {
    public let id: ObjectID
    public let name: String
    public let kind: LocationKind
    public init(location: Location) {
        id = location.id
        name = location.name
        kind = location.kind
    }
}

public struct TraceRackContext: Codable, Hashable, Sendable {
    public let id: ObjectID
    public let assetCode: AssetCode
    public let roomID: ObjectID?
    public let locationPath: [TraceLocationContext]
    public init(rack: Rack, locationPath: [TraceLocationContext]) {
        id = rack.id
        assetCode = rack.assetCode
        roomID = rack.locationID
        self.locationPath = locationPath
    }
}

public struct TraceVLANContext: Codable, Hashable, Sendable {
    public let id: ObjectID
    public let number: Int
    public let name: String
    public let isNative: Bool
    public init(vlan: VLAN, isNative: Bool) {
        id = vlan.id
        number = vlan.number
        name = vlan.name
        self.isNative = isNative
    }
}

public struct TraceLogicalInterfaceContext: Codable, Hashable, Sendable {
    public let id: ObjectID
    public let name: String
    public let mode: InterfaceMode
    public let kind: InterfaceKind
    public let addresses: [String]
    public let vlans: [TraceVLANContext]
    public init(interface: Interface, addresses: [String], vlans: [TraceVLANContext]) {
        id = interface.id
        name = interface.name
        mode = interface.mode
        kind = interface.kind
        self.addresses = addresses
        self.vlans = vlans
    }
}

public struct RichTraceNode: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public let portLabel: String
    public let portFace: PortFace
    public let medium: PortMedium
    public let connector: Connector
    public let fiberMode: FiberMode?
    public let device: TraceDeviceContext?
    public let rack: TraceRackContext?
    public let interfaces: [TraceLogicalInterfaceContext]
    public let warnings: [TraceWarning]
}

public struct TraceCableContext: Codable, Hashable, Sendable {
    public let assetCode: AssetCode
    public let medium: PortMedium
    public let connectorA: Connector
    public let connectorB: Connector
    public let kind: CableKind
    public let status: CableStatus
    public let color: String?
    public let lengthMeters: Double?
    public init(cable: Cable) {
        assetCode = cable.assetCode
        medium = cable.medium
        connectorA = cable.connectorA
        connectorB = cable.connectorB
        kind = cable.kind
        status = cable.status
        color = cable.color
        lengthMeters = cable.lengthMeters
    }
}

public struct RichTraceSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(segment.kind.rawValue):\(segment.id):\(segment.fromPortID):\(segment.toPortID)" }
    public let segment: TraceSegment
    public let cable: TraceCableContext?
    public init(segment: TraceSegment, cable: TraceCableContext? = nil) {
        self.segment = segment
        self.cable = cable
    }
}

public struct RichPhysicalPath: Codable, Hashable, Sendable {
    public let nodes: [RichTraceNode]
    public let segments: [RichTraceSegment]
    public let termination: TraceTermination
    public let warnings: [TraceWarning]
    public var ports: [ObjectID] { nodes.map(\.id) }
    public var stoppedByCycle: Bool {
        if case .cycle = termination { return true }
        return false
    }
}

/// Optional, versioned enrichment for the physical graph. A caller increments
/// `revision` whenever any supplied hierarchy or IPAM record changes.
public struct TraceEnrichment: Codable, Hashable, Sendable {
    public var revision: Int
    public var hierarchy: WorkspaceHierarchy?
    public var interfaces: [Interface]
    public var addresses: [IPAddressRecord]
    public var addressAssignments: [IPAddressAssignment]
    public var vlans: [VLAN]
    public var vlanMemberships: [InterfaceVLANMembership]
    public init(
        revision: Int = 0, hierarchy: WorkspaceHierarchy? = nil, interfaces: [Interface] = [], addresses: [IPAddressRecord] = [],
        addressAssignments: [IPAddressAssignment] = [], vlans: [VLAN] = [],
        vlanMemberships: [InterfaceVLANMembership] = []
    ) {
        self.revision = revision
        self.hierarchy = hierarchy
        self.interfaces = interfaces
        self.addresses = addresses
        self.addressAssignments = addressAssignments
        self.vlans = vlans
        self.vlanMemberships = vlanMemberships
    }
}

public struct RichTraceResult: Codable, Hashable, Sendable {
    public let startPortID: ObjectID
    public let topologyRevision: Int
    public let enrichmentRevision: Int
    public let paths: [RichPhysicalPath]
    public let warnings: [TraceWarning]
    public let dependencies: Set<TraceResource>
}

/// Cache identity intentionally contains no labels or mutable presentation
/// fields. A topology mutation produces a new revision, while fine-grained
/// resource invalidation removes only paths that declared that dependency.
public struct TraceCacheKey: Hashable, Sendable, Comparable {
    public let startPortID: ObjectID
    public let topologyRevision: Int
    public let enrichmentRevision: Int
    public init(startPortID: ObjectID, topologyRevision: Int, enrichmentRevision: Int = 0) {
        self.startPortID = startPortID
        self.topologyRevision = topologyRevision
        self.enrichmentRevision = enrichmentRevision
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.startPortID != rhs.startPortID { return lhs.startPortID < rhs.startPortID }
        if lhs.topologyRevision != rhs.topologyRevision { return lhs.topologyRevision < rhs.topologyRevision }
        return lhs.enrichmentRevision < rhs.enrichmentRevision
    }
}

/// Value-semantic, deterministic cache suitable for an actor-owned UI store.
/// It never returns a result for a different revision and exposes explicit
/// dependency invalidation for changed stable resource identities.
public struct IncrementalTraceCache: Sendable {
    private var entries: [TraceCacheKey: RichTraceResult] = [:]
    public init() {}
    public var count: Int { entries.count }
    public func result(for key: TraceCacheKey) -> RichTraceResult? { entries[key] }
    public mutating func store(_ result: RichTraceResult) {
        entries[TraceCacheKey(startPortID: result.startPortID, topologyRevision: result.topologyRevision, enrichmentRevision: result.enrichmentRevision)] =
            result
    }
    @discardableResult public mutating func invalidate(resources: Set<TraceResource>) -> [TraceCacheKey] {
        let keys = entries.keys.filter { key in !(entries[key]?.dependencies.isDisjoint(with: resources) ?? true) }.sorted()
        for key in keys { entries.removeValue(forKey: key) }
        return keys
    }
    @discardableResult public mutating func invalidate(topologyRevision: Int) -> [TraceCacheKey] {
        let keys = entries.keys.filter { $0.topologyRevision != topologyRevision }.sorted()
        for key in keys { entries.removeValue(forKey: key) }
        return keys
    }
    public mutating func removeAll() { entries.removeAll() }
}
