import Foundation
import NetworkModel
import WorkspaceChangeControl

struct MirrorIndexMaintenanceDelta {
    var edgeCount = 0
    var ownerCount = 0
    var memberCount = 0
    var assetCount = 0
    var byteCount = 0
    var affectedTransfers = Set<ObjectID>()
}

extension SwiftDataPersistenceStore {
    func markMirrorMaintenanceIncomplete(in namespace: PersistenceNamespace) throws {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let existing = try mirrorMaintenanceStateModel(matching: namespaceKey)
        let state = existing ?? LocalMirrorMaintenanceStateModel(namespace: namespace)
        if existing == nil { modelContext.insert(state) }
        state.isComplete = false
        state.updatedAt = .now
    }

    func validatedMirrorMaintenanceState(
        _ maintenance: LocalMirrorMaintenanceBatch,
        records: [LocalMirrorRecord], namespace: PersistenceNamespace
    ) throws -> LocalMirrorMaintenanceStateModel {
        guard maintenance.isComplete,
            Set(maintenance.records.map(\.resourceKey)) == Set(records.map(\.resourceKey)),
            maintenance.records.count == records.count
        else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("incomplete V9 maintenance batch")
        }
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        guard let state = try mirrorMaintenanceStateModel(matching: namespaceKey),
            state.schemaVersion == LocalMirrorMaintenanceLimits.schemaVersion, state.isComplete
        else {
            throw PersistenceStoreError.mirrorMaintenanceIncomplete
        }
        return state
    }

    func maintainMirrorRecord(
        _ record: LocalMirrorRecord, previous: LocalMirrorRecord?,
        fact: LocalMirrorMaintenanceRecord, namespace: PersistenceNamespace,
        delta: inout MirrorIndexMaintenanceDelta
    ) throws {
        guard (stagedTransferID(record.visibility) == nil) == (fact.transferMember == nil) else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("staged transfer member identity")
        }
        try replaceMirrorReferenceEdges(record, references: fact.references, namespace: namespace, delta: &delta)
        try replaceMirrorAssetOwner(record, previous: previous, namespace: namespace, delta: &delta)
        try replaceMirrorTransferMember(record, previous: previous, supplied: fact.transferMember, namespace: namespace, delta: &delta)
    }

    private func replaceMirrorReferenceEdges(
        _ record: LocalMirrorRecord,
        references: Set<LocalMirrorReferenceEdge>, namespace: PersistenceNamespace,
        delta: inout MirrorIndexMaintenanceDelta
    ) throws {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let oldEdges = try mirrorReferenceEdgeModels(namespaceKey: namespaceKey, sourceKey: record.resourceKey.description)
        oldEdges.forEach(modelContext.delete)
        delta.edgeCount -= oldEdges.count
        guard !record.isTombstone else { return }
        for edge in references where edge.source == record.resourceKey {
            modelContext.insert(try LocalMirrorReferenceEdgeModel(namespace: namespace, edge: edge))
            delta.edgeCount += 1
        }
    }

    private func replaceMirrorAssetOwner(
        _ record: LocalMirrorRecord, previous: LocalMirrorRecord?,
        namespace: PersistenceNamespace, delta: inout MirrorIndexMaintenanceDelta
    ) throws {
        try removePreviousMirrorAssetOwner(previous, ownerKey: record.resourceKey.description, namespace: namespace, delta: &delta)
        guard !record.isTombstone, let asset = record.recordAssetMetadata else { return }
        guard try mirrorAssetOwnerModel(assetID: asset.id, namespace: namespace) == nil else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("duplicate asset identity")
        }
        let transfer = stagedTransferID(record.visibility)
        modelContext.insert(
            try LocalMirrorAssetOwnerModel(
                namespace: namespace, assetID: asset.id, ownerKey: record.resourceKey, transferID: transfer, byteCount: asset.byteCount))
        delta.ownerCount += 1
        delta.assetCount += 1
        delta.byteCount += asset.byteCount
        if let transfer { delta.affectedTransfers.insert(transfer) }
    }

    private func removePreviousMirrorAssetOwner(
        _ previous: LocalMirrorRecord?, ownerKey: String,
        namespace: PersistenceNamespace, delta: inout MirrorIndexMaintenanceDelta
    ) throws {
        guard let assetID = previous?.recordAssetMetadata?.id,
            let owner = try mirrorAssetOwnerModel(assetID: assetID, namespace: namespace)
        else { return }
        guard owner.ownerKey == ownerKey else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("asset owner identity")
        }
        modelContext.delete(owner)
        delta.ownerCount -= 1
        delta.assetCount -= 1
        delta.byteCount -= owner.byteCount
        if let transfer = owner.transferID.flatMap(UUID.init(uuidString:)).map(ObjectID.init) {
            delta.affectedTransfers.insert(transfer)
        }
    }

    private func replaceMirrorTransferMember(
        _ record: LocalMirrorRecord, previous: LocalMirrorRecord?,
        supplied: LocalMirrorTransferMember?, namespace: PersistenceNamespace,
        delta: inout MirrorIndexMaintenanceDelta
    ) throws {
        try removePreviousTransferMember(previous, resourceKey: record.resourceKey, namespace: namespace, delta: &delta)
        guard let supplied else { return }
        guard stagedTransferID(record.visibility) == supplied.transferID else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("transfer member visibility")
        }
        modelContext.insert(try LocalMirrorTransferMemberModel(namespace: namespace, member: supplied))
        delta.memberCount += 1
        delta.affectedTransfers.insert(supplied.transferID)
    }

    private func removePreviousTransferMember(
        _ previous: LocalMirrorRecord?, resourceKey: ResourceKey,
        namespace: PersistenceNamespace, delta: inout MirrorIndexMaintenanceDelta
    ) throws {
        guard let transfer = previous.flatMap({ stagedTransferID($0.visibility) }) else { return }
        let key = mirrorTransferMemberStorageKey(transferID: transfer, resourceKey: resourceKey, namespace: namespace)
        if let member = try mirrorTransferMemberModel(matching: key) {
            modelContext.delete(member)
            delta.memberCount -= 1
        }
        delta.affectedTransfers.insert(transfer)
    }

    func applyMirrorAssetUsage(
        _ delta: MirrorIndexMaintenanceDelta, namespace: PersistenceNamespace
    ) throws {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let existing = try mirrorAssetUsageModel(matching: namespaceKey)
        let usage = existing ?? LocalMirrorAssetUsageModel(namespace: namespace)
        if existing == nil { modelContext.insert(usage) }
        let assetCount = usage.assetCount + delta.assetCount
        let byteCount = usage.byteCount + delta.byteCount
        guard assetCount >= 0, byteCount >= 0 else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("asset usage underflow")
        }
        usage.assetCount = assetCount
        usage.byteCount = byteCount
        usage.updatedAt = .now
    }

    func updateMirrorTransferUsage(_ transferIDs: Set<ObjectID>, namespace: PersistenceNamespace) throws {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        for transferID in transferIDs {
            try updateMirrorTransferUsage(transferID, namespace: namespace, namespaceKey: namespaceKey)
        }
    }

    private func updateMirrorTransferUsage(
        _ transferID: ObjectID, namespace: PersistenceNamespace,
        namespaceKey: String
    ) throws {
        let members = try mirrorTransferMemberModels(
            namespaceKey: namespaceKey, transferID: transferID, fetchLimit: LocalMirrorMaintenanceLimits.maximumTransferMembers + 1)
        guard members.count <= LocalMirrorMaintenanceLimits.maximumTransferMembers else {
            throw PersistenceStoreError.mirrorMaintenanceCapacityExceeded(LocalMirrorMaintenanceLimits.maximumTransferMembers)
        }
        let owners = try mirrorAssetOwnerModels(namespaceKey: namespaceKey, transferID: transferID)
        let bytes = try owners.reduce(0, Self.addingAssetBytes)
        let existing = try mirrorTransferAssetUsageModel(transferID: transferID, namespace: namespace)
        let aggregate = existing ?? LocalMirrorTransferAssetUsageModel(namespace: namespace, transferID: transferID)
        if existing == nil { modelContext.insert(aggregate) }
        aggregate.assetCount = owners.count
        aggregate.byteCount = bytes
        aggregate.updatedAt = .now
    }

    private static func addingAssetBytes(_ partial: Int, _ owner: LocalMirrorAssetOwnerModel) throws -> Int {
        let (next, overflow) = partial.addingReportingOverflow(owner.byteCount)
        guard !overflow else { throw PersistenceStoreError.mirrorMaintenanceInvalid("asset byte overflow") }
        return next
    }

    func applyMirrorMaintenanceState(
        _ delta: MirrorIndexMaintenanceDelta,
        to state: LocalMirrorMaintenanceStateModel
    ) throws {
        state.referenceEdgeCount += delta.edgeCount
        state.assetOwnerCount += delta.ownerCount
        state.transferMemberCount += delta.memberCount
        guard state.referenceEdgeCount >= 0, state.assetOwnerCount >= 0, state.transferMemberCount >= 0 else {
            throw PersistenceStoreError.mirrorMaintenanceInvalid("V9 aggregate underflow")
        }
        state.updatedAt = .now
    }
}
