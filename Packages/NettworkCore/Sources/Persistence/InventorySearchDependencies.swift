import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension InventorySearchIndexBuilder {
    static func directDependencySeeds(_ records: [LocalMirrorRecord]) throws -> DirectDependencySeeds {
        var dirty: Set<ResourceKey> = []
        var context: Set<ResourceKey> = []
        for record in records where !record.isTombstone {
            try addDirectDependencySeed(record, dirty: &dirty, context: &context)
        }
        return DirectDependencySeeds(dirty: dirty, context: context)
    }

    /// A port's reservation/planned fact is a derived node with no mirrored
    /// ResourceKey of its own. Include it whenever the port row changes or is
    /// tombstoned so state counts and later component rendering stay exact.
    static func derivedNodeKeys(for records: [LocalMirrorRecord]) throws -> Set<ResourceKey> {
        var keys = Set(records.map(\.resourceKey))
        for record in records where [WorkspaceRecordType.port, WorkspaceRecordType.Legacy.port].contains(record.recordType) {
            if case let .object(portID) = record.resourceKey {
                keys.insert(.string(portStateFactKey(portID)))
            }
        }
        for record in records
        where !record.isTombstone && [WorkspaceRecordType.topologyTombstone, WorkspaceRecordType.Legacy.topologyTombstone].contains(record.recordType) {
            let tombstone = try Projection.decode(TopologyTombstone.self, record: record)
            if tombstone.kind == .port {
                keys.insert(.string(portStateFactKey(tombstone.id)))
            }
        }
        return keys
    }
}
