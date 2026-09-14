import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

private struct MirrorMaintenanceSummary {
    var assets = Set<ObjectID>()
    var byteCount = 0
    var referenceEdgeCount = 0
    var membersByTransfer = [ObjectID: [LocalMirrorTransferMember]]()
    var ownersByTransfer = [ObjectID: [(ObjectID, Int, ResourceKey)]]()
}

extension SwiftDataPersistenceStore {
    func transaction<T>(_ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func activeLease(for namespace: PersistenceNamespace) throws -> PersistenceNamespaceLease {
        let key = PersistenceNamespaceKey.value(for: namespace)
        guard let id = activeLeaseIDs[key] else { throw PersistenceStoreError.invalidNamespaceLease }
        return PersistenceNamespaceLease(id: id, namespace: namespace)
    }

    /// Repository, outbox, quarantine, sync-state, and attachment calls all
    /// re-check the active account/session lease at their actor boundary. This
    /// keeps stale feature handles from observing or mutating a new session.
    func validateActiveLease(for namespace: PersistenceNamespace) throws {
        let lease = try activeLease(for: namespace)
        try validate(lease, for: namespace)
    }

    func validate(_ lease: PersistenceNamespaceLease, for namespace: PersistenceNamespace) throws {
        let key = PersistenceNamespaceKey.value(for: namespace)
        guard lease.namespace == namespace, activeLeaseIDs[key] == lease.id else {
            throw PersistenceStoreError.invalidNamespaceLease
        }
    }

    func mirrorModel(matching storageKey: String) throws -> LocalRecordMirror? {
        let descriptor = FetchDescriptor<LocalRecordMirror>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func cloudRecordNameIdentityModel(
        matching storageKey: String
    ) throws -> LocalCloudRecordNameIdentityModel? {
        let descriptor = FetchDescriptor<LocalCloudRecordNameIdentityModel>(
            predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func cloudRecordNameIdentityModels(namespaceKey: String) throws -> [LocalCloudRecordNameIdentityModel] {
        let descriptor = FetchDescriptor<LocalCloudRecordNameIdentityModel>(
            predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func mirrorModels(namespaceKey: String) throws -> [LocalRecordMirror] {
        let descriptor = FetchDescriptor<LocalRecordMirror>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    func mirrorModels(
        namespaceKey: String, recordType: String, fetchLimit: Int
    ) throws -> [LocalRecordMirror] {
        var descriptor = FetchDescriptor<LocalRecordMirror>(
            predicate: #Predicate {
                $0.namespaceKey == namespaceKey && $0.recordType == recordType
            })
        descriptor.fetchLimit = fetchLimit
        return try modelContext.fetch(descriptor)
    }

    // MARK: V9 indexed mirror reads

    /// Exact-key transport rows for ordinary CloudSync validation. This is not
    /// a namespace enumeration; callers must supply their candidate closure.
    public func storedLocalMirrors(
        for resourceKeys: Set<ResourceKey>, in namespace: PersistenceNamespace
    ) throws -> [LocalMirrorRecord] {
        try validateActiveLease(for: namespace)
        return try resourceKeys.compactMap { try storedLocalMirror(for: $0, in: namespace) }
    }

    /// Explicit repair-only escape hatch. Normal apply/validation paths must
    /// use `storedLocalMirrors(for:in:)` and V9 indexes instead.
    public func mirrorRecordsForExplicitMaintenanceRepair(in namespace: PersistenceNamespace) throws -> [LocalMirrorRecord] {
        try validateActiveLease(for: namespace)
        return try mirrorModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .map { try decodeMirror($0, namespace: namespace) }.sorted { $0.resourceKey < $1.resourceKey }
    }

    public func mirrorMaintenanceNeedsRepair(in namespace: PersistenceNamespace) throws -> Bool {
        try validateActiveLease(for: namespace)
        guard let state = try mirrorMaintenanceStateModel(matching: PersistenceNamespaceKey.value(for: namespace)) else { return true }
        return state.schemaVersion != LocalMirrorMaintenanceLimits.schemaVersion || !state.isComplete
    }

    /// Explicit recovery only. Callers must first observe an incomplete V9
    /// marker, then provide a fully decoded mirror fact set. This is the sole
    /// permitted namespace-wide maintenance rebuild after migration/corruption.
    public func repairMirrorMaintenanceIndexes(
        records: [LocalMirrorRecord],
        maintenance: LocalMirrorMaintenanceBatch, in namespace: PersistenceNamespace
    ) throws {
        try transaction {
            try rebuildMirrorMaintenanceIndexes(records: records, maintenance: maintenance, namespace: namespace)
        }
    }

    private func rebuildMirrorMaintenanceIndexes(
        records: [LocalMirrorRecord],
        maintenance: LocalMirrorMaintenanceBatch, namespace: PersistenceNamespace
    ) throws {
        try validateActiveLease(for: namespace)
        try validateMirrorRepairFacts(records: records, maintenance: maintenance)
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        try removeMirrorMaintenanceIndexes(namespaceKey: namespaceKey)
        let summary = try rebuildMirrorMaintenanceRecords(records, maintenance: maintenance, namespace: namespace)
        try storeMirrorMaintenanceSummary(summary, namespace: namespace, namespaceKey: namespaceKey)
    }

    private func validateMirrorRepairFacts(
        records: [LocalMirrorRecord],
        maintenance: LocalMirrorMaintenanceBatch
    ) throws {
        guard maintenance.isComplete,
            Set(records.map(\.resourceKey)) == Set(maintenance.records.map(\.resourceKey)),
            records.count == maintenance.records.count
        else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("repair facts do not cover mirror")
        }
    }

    private func removeMirrorMaintenanceIndexes(namespaceKey: String) throws {
        try mirrorReferenceEdgeModels(namespaceKey: namespaceKey).forEach(modelContext.delete)
        try mirrorAssetOwnerModels(namespaceKey: namespaceKey).forEach(modelContext.delete)
        try mirrorTransferMemberModels(namespaceKey: namespaceKey).forEach(modelContext.delete)
        try mirrorTransferAssetUsageModels(namespaceKey: namespaceKey).forEach(modelContext.delete)
    }

    private func rebuildMirrorMaintenanceRecords(
        _ records: [LocalMirrorRecord],
        maintenance: LocalMirrorMaintenanceBatch, namespace: PersistenceNamespace
    ) throws -> MirrorMaintenanceSummary {
        let facts = Dictionary(uniqueKeysWithValues: maintenance.records.map { ($0.resourceKey, $0) })
        var summary = MirrorMaintenanceSummary()
        for record in records {
            guard let fact = facts[record.resourceKey] else {
                throw PersistenceStoreError.mirrorMaintenanceIncomplete
            }
            try rebuildMirrorMaintenanceRecord(
                record, fact: fact,
                namespace: namespace, summary: &summary)
        }
        try storeTransferMaintenanceIndexes(summary, namespace: namespace)
        return summary
    }

    private func rebuildMirrorMaintenanceRecord(
        _ record: LocalMirrorRecord,
        fact: LocalMirrorMaintenanceRecord, namespace: PersistenceNamespace,
        summary: inout MirrorMaintenanceSummary
    ) throws {
        try validateTransferMember(fact.transferMember, for: record)
        try rebuildRecordReferenceAndAssetIndexes(record, fact: fact, namespace: namespace, summary: &summary)
        try collectTransferMember(fact.transferMember, for: record, summary: &summary)
    }

    private func validateTransferMember(
        _ member: LocalMirrorTransferMember?, for record: LocalMirrorRecord
    ) throws {
        guard (stagedTransferID(record.visibility) == nil) == (member == nil) else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("staged transfer member identity")
        }
    }

    private func rebuildRecordReferenceAndAssetIndexes(
        _ record: LocalMirrorRecord,
        fact: LocalMirrorMaintenanceRecord, namespace: PersistenceNamespace,
        summary: inout MirrorMaintenanceSummary
    ) throws {
        guard !record.isTombstone else { return }
        for edge in fact.references where edge.source == record.resourceKey {
            modelContext.insert(try LocalMirrorReferenceEdgeModel(namespace: namespace, edge: edge))
            summary.referenceEdgeCount += 1
        }
        try rebuildRecordAssetIndex(record, namespace: namespace, summary: &summary)
    }

    private func rebuildRecordAssetIndex(
        _ record: LocalMirrorRecord, namespace: PersistenceNamespace,
        summary: inout MirrorMaintenanceSummary
    ) throws {
        guard let asset = record.recordAssetMetadata else { return }
        guard summary.assets.insert(asset.id).inserted else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("duplicate asset identity")
        }
        summary.byteCount += asset.byteCount
        let transferID = stagedTransferID(record.visibility)
        modelContext.insert(
            try LocalMirrorAssetOwnerModel(
                namespace: namespace, assetID: asset.id,
                ownerKey: record.resourceKey, transferID: transferID, byteCount: asset.byteCount))
        if let transferID {
            summary.ownersByTransfer[transferID, default: []].append((asset.id, asset.byteCount, record.resourceKey))
        }
    }

    private func collectTransferMember(
        _ member: LocalMirrorTransferMember?, for record: LocalMirrorRecord,
        summary: inout MirrorMaintenanceSummary
    ) throws {
        guard let member else { return }
        guard stagedTransferID(record.visibility) == member.transferID else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("transfer member visibility")
        }
        summary.membersByTransfer[member.transferID, default: []].append(member)
    }

    private func storeTransferMaintenanceIndexes(
        _ summary: MirrorMaintenanceSummary,
        namespace: PersistenceNamespace
    ) throws {
        for (transferID, members) in summary.membersByTransfer {
            guard members.count <= LocalMirrorMaintenanceLimits.maximumTransferMembers else {
                throw PersistenceStoreError.mirrorMaintenanceCapacityExceeded(LocalMirrorMaintenanceLimits.maximumTransferMembers)
            }
            try insertTransferMembers(members, namespace: namespace)
            let owners = summary.ownersByTransfer[transferID] ?? []
            modelContext.insert(
                LocalMirrorTransferAssetUsageModel(
                    namespace: namespace,
                    transferID: transferID, assetCount: owners.count, byteCount: owners.reduce(0) { $0 + $1.1 }))
        }
    }

    private func insertTransferMembers(
        _ members: [LocalMirrorTransferMember],
        namespace: PersistenceNamespace
    ) throws {
        for member in members {
            modelContext.insert(try LocalMirrorTransferMemberModel(namespace: namespace, member: member))
        }
    }

    private func storeMirrorMaintenanceSummary(
        _ summary: MirrorMaintenanceSummary,
        namespace: PersistenceNamespace, namespaceKey: String
    ) throws {
        let existingUsage = try mirrorAssetUsageModel(matching: namespaceKey)
        let usage = existingUsage ?? LocalMirrorAssetUsageModel(namespace: namespace)
        if existingUsage == nil { modelContext.insert(usage) }
        usage.assetCount = summary.assets.count
        usage.byteCount = summary.byteCount
        usage.updatedAt = .now
        try storeMirrorMaintenanceState(summary, namespace: namespace, namespaceKey: namespaceKey)
    }

    private func storeMirrorMaintenanceState(
        _ summary: MirrorMaintenanceSummary,
        namespace: PersistenceNamespace, namespaceKey: String
    ) throws {
        let existingState = try mirrorMaintenanceStateModel(matching: namespaceKey)
        let state = existingState ?? LocalMirrorMaintenanceStateModel(namespace: namespace)
        if existingState == nil { modelContext.insert(state) }
        state.schemaVersion = LocalMirrorMaintenanceLimits.schemaVersion
        state.isComplete = true
        state.referenceEdgeCount = summary.referenceEdgeCount
        state.assetOwnerCount = summary.assets.count
        state.transferMemberCount = summary.membersByTransfer.values.reduce(0) { $0 + $1.count }
        state.updatedAt = .now
    }

    public func mirrorReferenceSources(
        targeting resourceKeys: Set<ResourceKey>, remainingBudget: Int,
        in namespace: PersistenceNamespace
    ) throws -> Set<ResourceKey> {
        guard remainingBudget > 0 else { throw PersistenceStoreError.mirrorMaintenanceCapacityExceeded(remainingBudget) }
        try validateActiveLease(for: namespace)
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        var remaining = remainingBudget
        return try resourceKeys.reduce(into: Set<ResourceKey>()) { sources, target in
            let models = try mirrorReferenceEdgeModels(
                namespaceKey: namespaceKey,
                targetKey: target.description, fetchLimit: remaining + 1)
            guard models.count <= remaining else {
                throw PersistenceStoreError.mirrorMaintenanceCapacityExceeded(remainingBudget)
            }
            remaining -= models.count
            for model in models {
                guard let source = try? PersistenceCoding.decode(ResourceKey.self, from: model.sourceKeyData) else { continue }
                sources.insert(source)
            }
        }
    }

    public func mirrorTransferMembers(
        transferID: ObjectID, in namespace: PersistenceNamespace
    ) throws -> [LocalMirrorTransferMember] {
        try validateActiveLease(for: namespace)
        let models = try mirrorTransferMemberModels(
            namespaceKey: PersistenceNamespaceKey.value(for: namespace), transferID: transferID,
            fetchLimit: LocalMirrorMaintenanceLimits.maximumTransferMembers + 1)
        guard models.count <= LocalMirrorMaintenanceLimits.maximumTransferMembers else {
            throw PersistenceStoreError.mirrorMaintenanceCapacityExceeded(LocalMirrorMaintenanceLimits.maximumTransferMembers)
        }
        return try models.map { model in
            LocalMirrorTransferMember(
                transferID: transferID,
                resourceKey: try PersistenceCoding.decode(ResourceKey.self, from: model.resourceKeyData),
                digest: model.digest)
        }.sorted { $0.resourceKey < $1.resourceKey }
    }

    public func mirrorAssetUsage(in namespace: PersistenceNamespace) throws -> (assetCount: Int, byteCount: Int)? {
        try validateActiveLease(for: namespace)
        guard let usage = try mirrorAssetUsageModel(matching: PersistenceNamespaceKey.value(for: namespace)) else { return nil }
        return (usage.assetCount, usage.byteCount)
    }

    /// Open-time cache repair is bounded by V9 asset-owner rows, then narrows
    /// to actual evidence-binding mirror keys. It never enumerates the raw
    /// mirror or guesses ownership from attachment files.
    public func mirrorEvidenceProjectionRepairPage(
        in namespace: PersistenceNamespace,
        afterStorageKey: String?, maximumOwners: Int = 4_096
    ) throws -> (candidates: Set<ResourceKey>, nextStorageKey: String?) {
        guard (1...4_096).contains(maximumOwners) else { throw PersistenceStoreError.invalidReadLimit }
        try validateActiveLease(for: namespace)
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let owners = try mirrorAssetOwnerRepairPage(
            namespaceKey: namespaceKey,
            afterStorageKey: afterStorageKey, fetchLimit: maximumOwners + 1)
        let page = Array(owners.prefix(maximumOwners))
        let nextStorageKey = owners.count > maximumOwners ? page.last?.storageKey : nil
        var candidates = Set<ResourceKey>()
        for owner in page {
            if let key = try evidenceRepairCandidate(for: owner, in: namespace) {
                candidates.insert(key)
            }
        }
        return (candidates, nextStorageKey)
    }

    private func evidenceRepairCandidate(for owner: LocalMirrorAssetOwnerModel, in namespace: PersistenceNamespace) throws -> ResourceKey? {
        let key = try PersistenceCoding.decode(ResourceKey.self, from: owner.ownerKeyData)
        guard let record = try storedLocalMirror(for: key, in: namespace) else { return nil }
        guard !record.isTombstone, record.recordType == "NettworkAttachmentEvidenceBinding" else { return nil }
        guard let assetID = UUID(uuidString: owner.assetID).map(ObjectID.init) else { return nil }
        let storageKey = attachmentEvidenceStorageKey(attachmentID: assetID, namespace: namespace)
        return try attachmentEvidenceModel(matching: storageKey) == nil ? key : nil
    }
}
