import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    struct MirrorBatchPlan {
        let requiresFullIndexRebuild: Bool
        let indexAffectingBatch: Bool
        let incrementalSnapshot: InventoryProjectionSnapshot?
    }

    func applyVerifiedMirrorBatchLocked(_ batch: LocalMirrorBatch, in namespace: PersistenceNamespace, lease: PersistenceNamespaceLease) throws {
        try validate(lease, for: namespace)
        let plan = try mirrorBatchPlan(batch, in: namespace)
        let previousRecords = try persistVerifiedMirrorRecords(batch.records, in: namespace)
        try maintainMirrorIndexes(batch.records, previous: previousRecords, maintenance: batch.maintenance, in: namespace)
        try projectAttachmentEvidenceFromMirrorBatch(batch.records, in: namespace)
        try persistMirrorBatchState(batch, in: namespace)
        try applyMirrorBatchIndexPlan(plan, batch: batch, in: namespace)
        try validate(lease, for: namespace)
    }

    func mirrorBatchPlan(_ batch: LocalMirrorBatch, in namespace: PersistenceNamespace) throws -> MirrorBatchPlan {
        try validateMirrorBatch(batch, in: namespace)
        let previousVisibility = try workspaceVisibilityState(in: namespace)
        let visibilityTransition = batch.workspaceVisibility.map { $0.lifecycle != previousVisibility.lifecycle } ?? false
        let requiresFullIndexRebuild =
            visibilityTransition || InventorySearchIndexBuilder.requiresFullRebuild(batch.records)
            || InventorySearchIndexBuilder.containsVisibilitySentinel(batch.records)
        let indexAffectingBatch = InventorySearchIndexBuilder.isIndexAffecting(batch.records)
        let snapshot = try incrementalInventorySnapshot(
            records: batch.records, requiresFullRebuild: requiresFullIndexRebuild, isIndexAffecting: indexAffectingBatch, namespace: namespace)
        return MirrorBatchPlan(requiresFullIndexRebuild: requiresFullIndexRebuild, indexAffectingBatch: indexAffectingBatch, incrementalSnapshot: snapshot)
    }

    func validateMirrorBatch(_ batch: LocalMirrorBatch, in namespace: PersistenceNamespace) throws {
        guard batch.records.allSatisfy({ $0.namespace == namespace }), batch.syncState.map({ $0.namespace == namespace }) ?? true,
            batch.workspaceVisibility.map({ $0.namespace == namespace }) ?? true
        else { throw PersistenceStoreError.invalidNamespace }
        for record in batch.records { try validateMirror(record, in: namespace) }
        guard Set(batch.records.map(\.resourceKey)).count == batch.records.count else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("duplicate mirror resource key")
        }
        try batch.syncState.map { try validateSyncState($0, in: namespace) }
    }

    func incrementalInventorySnapshot(records: [LocalMirrorRecord], requiresFullRebuild: Bool, isIndexAffecting: Bool, namespace: PersistenceNamespace) throws
        -> InventoryProjectionSnapshot?
    {
        guard !requiresFullRebuild && isIndexAffecting else { return nil }
        do { return try inventoryProjectionSnapshot(for: records, in: namespace) } catch PersistenceStoreError.inventoryProjectionTraversalExceeded {
            return nil
        }
    }

    func persistVerifiedMirrorRecords(_ records: [LocalMirrorRecord], in namespace: PersistenceNamespace) throws -> [ResourceKey: LocalMirrorRecord?] {
        var previousRecords = [ResourceKey: LocalMirrorRecord?]()
        for record in records { try persistVerifiedMirrorRecord(record, in: namespace, previous: &previousRecords) }
        return previousRecords
    }

    func persistVerifiedMirrorRecord(_ record: LocalMirrorRecord, in namespace: PersistenceNamespace, previous: inout [ResourceKey: LocalMirrorRecord?]) throws
    {
        let storageKey = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: record.resourceKey.description)
        guard let existing = try mirrorModel(matching: storageKey) else {
            previous[record.resourceKey] = nil
            modelContext.insert(try LocalRecordMirror(record: record))
            return
        }
        previous[record.resourceKey] = try decodeMirror(existing, namespace: namespace)
        try validateMirrorReplacement(existing, with: record)
        try overwrite(existing, with: record)
    }

    func validateMirrorReplacement(_ existing: LocalRecordMirror, with record: LocalMirrorRecord) throws {
        guard !(existing.isTombstone && !record.isTombstone) else { throw PersistenceStoreError.tombstoneResurrection(record.resourceKey) }
        guard existing.serverModifiedAt <= record.serverModifiedAt else { throw PersistenceStoreError.staleMirrorUpdate(record.resourceKey) }
    }

    func persistMirrorBatchState(_ batch: LocalMirrorBatch, in namespace: PersistenceNamespace) throws {
        try batch.syncState.map { try persistSyncState($0, in: namespace) }
        try batch.workspaceVisibility.map { try persistWorkspaceVisibility($0, in: namespace) }
    }

    func persistSyncState(_ state: LocalSyncState, in namespace: PersistenceNamespace) throws {
        let key = PersistenceNamespaceKey.value(for: namespace)
        guard let existing = try syncStateModel(matching: key) else {
            modelContext.insert(try LocalSyncStateModel(state: state))
            return
        }
        existing.stateData = try PersistenceCoding.encode(state)
        existing.updatedAt = state.updatedAt
    }

    func persistWorkspaceVisibility(_ state: LocalWorkspaceVisibilityState, in namespace: PersistenceNamespace) throws {
        let key = PersistenceNamespaceKey.value(for: namespace)
        guard let existing = try workspaceVisibilityStateModel(matching: key) else {
            modelContext.insert(try LocalWorkspaceVisibilityStateModel(state: state))
            return
        }
        existing.stateData = try PersistenceCoding.encode(state)
        existing.updatedAt = state.updatedAt
    }

    func applyMirrorBatchIndexPlan(_ plan: MirrorBatchPlan, batch: LocalMirrorBatch, in namespace: PersistenceNamespace) throws {
        if plan.requiresFullIndexRebuild || (plan.indexAffectingBatch && plan.incrementalSnapshot == nil) {
            try rebuildInventorySearchIndexLocked(in: namespace)
            return
        }
        try plan.incrementalSnapshot.map { try applyIncrementalProjection(batch.records, snapshot: $0, namespace: namespace) }
    }

    func applyIncrementalProjection(_ records: [LocalMirrorRecord], snapshot: InventoryProjectionSnapshot, namespace: PersistenceNamespace) throws {
        do { try applyIncrementalInventoryProjection(records, snapshot: snapshot, in: namespace) } catch PersistenceStoreError
            .inventoryProjectionTraversalExceeded
        { try rebuildInventorySearchIndexLocked(in: namespace) }
    }
}
