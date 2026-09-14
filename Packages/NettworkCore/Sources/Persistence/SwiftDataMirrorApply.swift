import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    public func applyVerifiedMirrorBatch(_ batch: LocalMirrorBatch, in namespace: PersistenceNamespace) throws {
        let lease = try activeLease(for: namespace)
        try applyVerifiedMirrorBatch(batch, in: namespace, lease: lease)
    }

    public func applyVerifiedMirrorBatch(_ batch: LocalMirrorBatch, in namespace: PersistenceNamespace, lease: PersistenceNamespaceLease) throws {
        try transaction {
            try applyVerifiedMirrorBatchLocked(batch, in: namespace, lease: lease)
        }
    }

    public func localMirror(for resourceKey: ResourceKey, in namespace: PersistenceNamespace) throws -> LocalMirrorRecord? {
        guard let stored = try storedLocalMirror(for: resourceKey, in: namespace),
            try isVisibleToFeatureProjection(stored, in: namespace)
        else { return nil }
        return stored
    }

    /// Unfiltered transport storage. Cloud validation and exact conditional
    /// state reconstruction must see staging/session infrastructure even while
    /// it is intentionally absent from public feature reads.
    public func storedLocalMirror(for resourceKey: ResourceKey, in namespace: PersistenceNamespace) throws -> LocalMirrorRecord? {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: resourceKey.description)
        guard let model = try mirrorModel(matching: key) else { return nil }
        return try decodeMirror(model, namespace: namespace)
    }

    /// Exact-key feature projection. Hidden staged or infrastructure records
    /// remain absent until the workspace visibility contract admits them.
    public func mirroredRecord(
        for resourceKey: ResourceKey, in namespace: PersistenceNamespace
    ) throws -> LocalMirrorRecord? {
        guard let record = try storedLocalMirror(for: resourceKey, in: namespace),
            try isVisibleToFeatureProjection(record, in: namespace)
        else {
            return nil
        }
        return record
    }

    /// Enumerates one active account/workspace mirror for read-model and
    /// candidate-reference construction. Tombstones are retained in the result;
    /// malformed rows fail the complete read instead of disappearing silently.
    public func mirroredRecords(in namespace: PersistenceNamespace) throws -> [LocalMirrorRecord] {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        return try mirrorModels(namespaceKey: key).map { try decodeMirror($0, namespace: namespace) }
            .filter { try isVisibleToFeatureProjection($0, in: namespace) }
            .sorted { $0.resourceKey < $1.resourceKey }
    }

    /// Returns one transactionally observed planner snapshot: every record
    /// currently visible to features plus the active workspace sentinel that
    /// revisions all ordinary authoritative writes. The sentinel remains
    /// hidden from general feature reads, but a materializer must bind its
    /// complete candidate snapshot to this exact revision instead of emitting
    /// one conditional CloudKit write per consulted record.
    public func authoritativePlanningRecords(
        in namespace: PersistenceNamespace
    ) throws -> [LocalMirrorRecord] {
        try validateActiveLease(for: namespace)
        guard case .active = try workspaceVisibilityState(in: namespace).lifecycle else {
            throw PersistenceStoreError.malformedStoredValue("inactive planning workspace")
        }
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(
            for: namespace.workspaceID)
        let decoded = try mirrorModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .map { try decodeMirror($0, namespace: namespace) }
        let sentinels = decoded.filter {
            $0.resourceKey == sentinelKey && $0.recordType == AuthoritativeActivationMutation.workspaceSentinelRecordType && !$0.isTombstone
        }
        guard sentinels.count == 1, sentinels[0].payload != nil, sentinels[0].exactPrecondition != nil else {
            throw PersistenceStoreError.malformedStoredValue("active workspace sentinel")
        }
        let visible = try decoded.filter {
            try $0.resourceKey != sentinelKey && isVisibleToFeatureProjection($0, in: namespace)
        }
        return (visible + sentinels).sorted { $0.resourceKey < $1.resourceKey }
    }

    /// Full durable mirror used only by CloudSync validation, reconciliation,
    /// and staged-transfer recovery. It deliberately includes infrastructure
    /// records and inactive staged rows.
    public func storedMirroredRecords(in namespace: PersistenceNamespace) throws -> [LocalMirrorRecord] {
        try validateActiveLease(for: namespace)
        return try mirrorModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .map { try decodeMirror($0, namespace: namespace) }.sorted { $0.resourceKey < $1.resourceKey }
    }

    /// Storage-bounded variant for feature search and list projections. Sync
    /// candidate validation uses the complete overload above instead.
    public func mirroredRecords(in namespace: PersistenceNamespace, limit: Int) throws -> [LocalMirrorRecord] {
        guard (1...100_000).contains(limit) else { throw PersistenceStoreError.invalidReadLimit }
        try validateActiveLease(for: namespace)
        // Apply the public visibility filter before the caller's limit. A raw
        // SwiftData fetchLimit would let invisible staged/infrastructure rows
        // consume the entire budget and silently hide eligible records.
        return try mirrorModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .map { try decodeMirror($0, namespace: namespace) }
            .filter { try isVisibleToFeatureProjection($0, in: namespace) }
            .sorted { $0.resourceKey < $1.resourceKey }.prefix(limit).map { $0 }
    }

    /// Storage-bounded typed projection. Unlike the legacy global prefix, a
    /// high-cardinality object type cannot hide a later record type. The fetch
    /// fails closed when the requested type exceeds its explicit budget.
    public func mirroredRecords(
        in namespace: PersistenceNamespace, recordType: String, limit: Int
    ) throws -> [LocalMirrorRecord] {
        guard (1...100_000).contains(limit),
            !recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw PersistenceStoreError.invalidReadLimit
        }
        try validateActiveLease(for: namespace)
        let models = try mirrorModels(
            namespaceKey: PersistenceNamespaceKey.value(for: namespace),
            recordType: recordType, fetchLimit: limit + 1)
        guard models.count <= limit else { throw PersistenceStoreError.invalidReadLimit }
        return try models.map { try decodeMirror($0, namespace: namespace) }
            .filter { try isVisibleToFeatureProjection($0, in: namespace) }
            .sorted { $0.resourceKey < $1.resourceKey }
    }

    /// Captures a complete typed feature/export projection in one actor turn.
    /// Callers therefore cannot combine record types observed before and after
    /// an intervening mirror transaction. Every type is raw-bounded, then its
    /// active projection is checked against the caller's exact table limit.
    public func mirroredRecords(
        in namespace: PersistenceNamespace, recordTypes: Set<String>,
        limitPerType: Int
    ) throws -> [LocalMirrorRecord] {
        guard (1...100_000).contains(limitPerType), !recordTypes.isEmpty,
            recordTypes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw PersistenceStoreError.invalidReadLimit
        }
        try validateActiveLease(for: namespace)
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        // Matches the public transfer/import scale contract without creating
        // a Persistence -> ImportExport dependency.
        let maximumRawRowsPerType = 250_000
        var result: [LocalMirrorRecord] = []
        for recordType in recordTypes.sorted() {
            // Hidden staged rows must not consume the published table budget.
            // Fetch remains globally bounded by the transfer contract, then
            // the active projection is counted against the caller's limit.
            let models = try mirrorModels(
                namespaceKey: namespaceKey, recordType: recordType,
                fetchLimit: maximumRawRowsPerType + 1)
            guard models.count <= maximumRawRowsPerType else {
                throw PersistenceStoreError.invalidReadLimit
            }
            let visible = try models.map { try decodeMirror($0, namespace: namespace) }
                .filter { try isVisibleToFeatureProjection($0, in: namespace) }
            guard visible.count <= limitPerType else {
                throw PersistenceStoreError.invalidReadLimit
            }
            result.append(contentsOf: visible)
        }
        return result.sorted { $0.resourceKey < $1.resourceKey }
    }

    /// Executes bounded structured inventory search against the transactionally
    /// maintained mirror index. Query predicates never decode or enumerate the
    /// full authoritative mirror at search time.
}
