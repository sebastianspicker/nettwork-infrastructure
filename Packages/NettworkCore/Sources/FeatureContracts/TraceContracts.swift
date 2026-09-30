import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum TraceDirection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case forward
    case reverse

    public var id: String { rawValue }
}

public enum TraceSegmentKind: String, Sendable {
    case cable
    case internalLink
    case transition
    case unknown
}

public struct TraceNodeSnapshot: Identifiable, Sendable {
    public let id: ObjectID
    public let deviceName: String
    public let portLabel: String
    public let faceName: String
    public let roomRack: String
    public let logicalContext: [String]

    public init(id: ObjectID, deviceName: String, portLabel: String, faceName: String, roomRack: String, logicalContext: [String]) {
        self.id = id
        self.deviceName = deviceName
        self.portLabel = portLabel
        self.faceName = faceName
        self.roomRack = roomRack
        self.logicalContext = logicalContext
    }
}

public struct TraceSegmentSnapshot: Identifiable, Sendable {
    public let id: String
    public let kind: TraceSegmentKind
    public let label: String
    public let detail: String?
    /// Present only when the trace provider has supplied a complete, typed
    /// command and resource set for this exact segment. The operator still
    /// supplies the reviewed title, ticket, and notes before staging.
    public let workOrderRequest: TopologyWorkOrderRequest?

    public init(
        id: String,
        kind: TraceSegmentKind,
        label: String,
        detail: String? = nil,
        workOrderRequest: TopologyWorkOrderRequest? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.detail = detail
        self.workOrderRequest = workOrderRequest
    }
}

public struct TraceBranchSnapshot: Identifiable, Sendable {
    public let id: ObjectID
    public let nodes: [TraceNodeSnapshot]
    public let segments: [TraceSegmentSnapshot]
    public let warnings: [String]
    public let termination: String

    public init(
        id: ObjectID,
        nodes: [TraceNodeSnapshot],
        segments: [TraceSegmentSnapshot],
        warnings: [String],
        termination: String
    ) {
        self.id = id
        self.nodes = nodes
        self.segments = segments
        self.warnings = warnings
        self.termination = termination
    }
}

public struct TraceInspectionSnapshot: Sendable {
    public let startPortID: ObjectID
    public let branches: [TraceBranchSnapshot]
    public let globalWarnings: [String]
    public let isStale: Bool
    public let hasPendingWork: Bool
    public let hasConflict: Bool

    public init(
        startPortID: ObjectID,
        branches: [TraceBranchSnapshot],
        globalWarnings: [String],
        isStale: Bool,
        hasPendingWork: Bool,
        hasConflict: Bool
    ) {
        self.startPortID = startPortID
        self.branches = branches
        self.globalWarnings = globalWarnings
        self.isStale = isStale
        self.hasPendingWork = hasPendingWork
        self.hasConflict = hasConflict
    }
}

public protocol TraceInspecting: Sendable {
    func inspect(startingAt portID: ObjectID, direction: TraceDirection, in namespace: PersistenceNamespace) async throws -> TraceInspectionSnapshot
}

public protocol TraceIdentifierCopying: Sendable {
    func copy(identifier: String) async
}
