import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Materializes the public inventory search surface from already-verified
/// mirror values. It deliberately mirrors the aggregate-plus-direct overlay
/// rules used by the production read adapter so a newer direct row or durable
/// tombstone cannot be hidden by an older aggregate seed.
enum InventorySearchIndexBuilder {
    /// Leaves bounded headroom for the devices, racks, cables, interfaces,
    /// addresses, and locations in a workspace with up to 50,000 ports.
    static let maximumEntries = 250_000

    static let maximumIncrementalMutations = 4_096
    static let maximumDependencyVisits = 65_536
    static let maximumDerivedNodes = 1_000_000
    /// Workspace-wide derived storage is bounded independently from one dirty
    /// closure. A 50k-port workspace has at least two directed edges per port.
    static let maximumDerivedEdges = 2_000_000
    static let maximumContainmentDepth = 16

    struct DependencyEdge: Hashable {
        let source: ResourceKey
        let target: ResourceKey
        let kind: String
    }

    struct Materialization {
        let entries: [LocalInventorySearchRecord]
        /// Canonical verified records are retained only as rebuildable input
        /// for a bounded affected closure; they never become a second source
        /// of authority.
        let nodes: [LocalMirrorRecord]
        let edges: [DependencyEdge]
    }

    struct PortStateFact: Codable, Hashable, Sendable, Identifiable {
        let portID: ObjectID
        let isReserved: Bool
        let isPlanned: Bool

        var id: ObjectID { portID }
    }

    struct DirectDependencySeeds {
        let dirty: Set<ResourceKey>
        let context: Set<ResourceKey>
    }

    static let indexAffectingRecordTypes: Set<String> = [
        "NettworkPhysicalTopology", LocalRecordKind.physicalTopology,
        "NettworkTemplatePlacementState", "TemplatePlacementState",
        "NettworkWorkspaceHierarchy", "WorkspaceHierarchy",
        "NettworkDevice", "Device", "NettworkPort", "Port", "NettworkCable", "Cable",
        "NettworkDeviceType", "DeviceType", "NettworkModule", "Module",
        "NettworkInternalLink", "InternalLink", "NettworkTopologyTombstone", "TopologyTombstone",
        "NettworkLocation", "Location", "NettworkRack", "Rack",
        "NettworkHierarchyTombstone", "HierarchyTombstone", "NettworkRackPlacement", "RackPlacement",
        "NettworkIPAddressRecord", "NettworkInterface", "NettworkWorkOrder", LocalRecordKind.workOrder,
    ]

    static let fullRebuildRecordTypes: Set<String> = [
        "NettworkPhysicalTopology", LocalRecordKind.physicalTopology,
        "NettworkTemplatePlacementState", "TemplatePlacementState",
        "NettworkWorkspaceHierarchy", "WorkspaceHierarchy",
    ]

    struct IndexIdentity: Hashable {
        let kind: String
        let objectID: ObjectID
    }

    static func isIndexAffecting(_ records: [LocalMirrorRecord]) -> Bool {
        records.contains { indexAffectingRecordTypes.contains($0.recordType) }
    }

    static func requiresFullRebuild(_ records: [LocalMirrorRecord]) -> Bool {
        records.contains { fullRebuildRecordTypes.contains($0.recordType) }
    }

    static func containsVisibilitySentinel(_ records: [LocalMirrorRecord]) -> Bool {
        records.contains { $0.recordType.hasPrefix("NettworkWorkspaceTransfer") || $0.recordType == "NettworkWorkspace" }
    }
}
