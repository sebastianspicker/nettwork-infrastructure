import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

/// A cheap, persisted change signal for the visible mirror of one namespace,
/// read from the shared store so writes by other stores on the same
/// `ModelContainer` count too. Each write that can change visible mirror rows
/// changes at least one field in its saved transaction:
/// - `applyVerifiedMirrorBatch` (sync apply, outbox echo, imports, visibility
///   and sync-state batches) always stamps the maintenance marker's
///   `updatedAt` via `maintainMirrorIndexes`, and inserts change the count;
/// - `repairMirrorMaintenanceIndexes` stamps the same marker;
/// - `rebuildMirror` deletes the rows (count) and the visibility state.
/// No other code path writes `LocalRecordMirror` or the visibility state.
public struct LocalMirrorRevision: Hashable, Sendable {
    public let mirrorRowCount: Int
    public let maintenanceUpdatedAt: Date?
    public let visibilityUpdatedAt: Date?
}

extension SwiftDataPersistenceStore {
    public func mirrorRevision(in namespace: PersistenceNamespace) throws -> LocalMirrorRevision {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        let rows = try modelContext.fetchCount(FetchDescriptor<LocalRecordMirror>(predicate: #Predicate { $0.namespaceKey == key }))
        return LocalMirrorRevision(
            mirrorRowCount: rows, maintenanceUpdatedAt: try mirrorMaintenanceStateModel(matching: key)?.updatedAt,
            visibilityUpdatedAt: try workspaceVisibilityStateModel(matching: key)?.updatedAt)
    }

    /// The newest visible, non-tombstone records of the given types, newest
    /// first by `serverModifiedAt`. Unlike the complete typed read this never
    /// fails on volume: it is meant for append-only history such as audits.
    public func newestMirroredRecords(
        in namespace: PersistenceNamespace, recordTypes: Set<String>, limit: Int
    ) throws -> [LocalMirrorRecord] {
        guard (1...100_000).contains(limit), !recordTypes.isEmpty else { throw PersistenceStoreError.invalidReadLimit }
        try validateActiveLease(for: namespace)
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        var result: [LocalMirrorRecord] = []
        for recordType in recordTypes.sorted() {
            result += try newestVisibleRecords(namespaceKey: namespaceKey, recordType: recordType, limit: limit, namespace: namespace)
        }
        return Array(result.sorted { $0.serverModifiedAt > $1.serverModifiedAt }.prefix(limit))
    }

    /// Pages newest-first so hidden staged rows cannot consume the budget.
    private func newestVisibleRecords(
        namespaceKey: String, recordType: String, limit: Int, namespace: PersistenceNamespace
    ) throws -> [LocalMirrorRecord] {
        var descriptor = FetchDescriptor<LocalRecordMirror>(
            predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.recordType == recordType && !$0.isTombstone },
            sortBy: [SortDescriptor(\.serverModifiedAt, order: .reverse), SortDescriptor(\.storageKey)])
        descriptor.fetchLimit = limit
        var visible: [LocalMirrorRecord] = []
        while visible.count < limit {
            let page = try modelContext.fetch(descriptor)
            visible += try page.map { try decodeMirror($0, namespace: namespace) }.filter { try isVisibleToFeatureProjection($0, in: namespace) }
            guard page.count == limit else { break }
            descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + limit
        }
        return Array(visible.prefix(limit))
    }
}
