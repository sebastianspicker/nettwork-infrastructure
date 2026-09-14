import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataCloudMirrorStore {
    public func quarantine(_ record: QuarantinedCloudRecord, namespace: PersistenceNamespace) async throws {
        _ = try requireOpen(namespace)
        let failure = SyncFailure(category: .malformedRemoteRecord, message: record.reason, resourceKeys: [record.resourceKey])
        try await persistence.quarantine(
            LocalQuarantineRecord(
                namespace: namespace, resourceKey: record.resourceKey, recordType: record.recordType, payload: record.boundedEnvelope, failure: failure,
                capturedAt: record.observedAt))
    }

    public func syncStatus(namespace: PersistenceNamespace) async throws -> CloudMirrorStatus {
        _ = try requireOpen(namespace)
        let outbox = try await persistence.status(in: namespace)
        let quarantineCount = try await persistence.quarantineCount(in: namespace)
        let conflictCount = try await persistence.unresolvedConflictCount(in: namespace)
        let state = try await persistence.syncState(in: namespace)
        return CloudMirrorStatus(
            queueDepth: outbox.queueDepth, oldestQueuedAt: outbox.oldestQueuedAt,
            quarantineCount: quarantineCount, conflictCount: conflictCount,
            lastSuccessfulServerContact: state?.lastSuccessfulServerContact)
    }

    func requireOpen(_ namespace: PersistenceNamespace) throws -> PersistenceNamespaceLease {
        guard let activeLease, activeLease.namespace == namespace else {
            throw CloudMirrorAdapterError.namespaceNotOpen(namespace)
        }
        return activeLease
    }

    /// Candidate-scoped admission uses aggregate deltas plus exact transfer
    /// members/sessions. It never constructs a raw post-batch namespace.
    func validateAssetAdmission(
        incoming: [VerifiedCloudRecord],
        replacing oldRecords: [LocalMirrorRecord], maintenance: LocalMirrorMaintenanceBatch,
        namespace: PersistenceNamespace
    ) async throws {
        guard let namespaceUsage = try await persistence.mirrorAssetUsage(in: namespace) else {
            throw PersistenceStoreError.mirrorMaintenanceIncomplete
        }
        let phase = try assetAdmissionPhase(incoming: incoming, replacing: oldRecords, usage: namespaceUsage)
        try validateNamespaceQuota(phase, incoming: incoming)
        for transferID in phase.transferIDs {
            try await validateTransferAssetAdmission(
                transferID,
                incomingByKey: phase.incomingByKey,
                replacing: oldRecords,
                namespace: namespace
            )
        }
        _ = maintenance  // ties validation to the exact fact set committed below.
    }

    private struct AssetAdmissionPhase {
        let transferIDs: Set<ObjectID>
        let incomingByKey: [ResourceKey: CloudRecordEnvelope]
        let namespaceCount: Int
        let namespaceBytes: Int
    }

    private func assetAdmissionPhase(incoming: [VerifiedCloudRecord], replacing oldRecords: [LocalMirrorRecord], usage: (assetCount: Int, byteCount: Int))
        throws -> AssetAdmissionPhase
    {
        var seenAssets = Set<ObjectID>()
        var namespaceCount = usage.assetCount
        var namespaceBytes = usage.byteCount
        var transferIDs = Set<ObjectID>()
        var oldByKey = Dictionary(uniqueKeysWithValues: oldRecords.map { ($0.resourceKey, $0) })
        for verified in incoming {
            if case let .staged(transferID) = verified.envelope.visibility { transferIDs.insert(transferID) }
            if let old = oldByKey.removeValue(forKey: verified.envelope.resourceKey), let asset = old.recordAssetMetadata {
                namespaceCount -= 1
                namespaceBytes -= asset.byteCount
                if case let .staged(transferID) = old.visibility { transferIDs.insert(transferID) }
            }
            guard !verified.envelope.isDeleted, let asset = verified.envelope.recordAsset?.metadata else { continue }
            guard seenAssets.insert(asset.id).inserted else {
                throw CloudMirrorAdapterError.malformedPayload(verified.envelope.resourceKey, "duplicate asset identity")
            }
            namespaceCount += 1
            namespaceBytes += asset.byteCount
        }
        return AssetAdmissionPhase(
            transferIDs: transferIDs, incomingByKey: Dictionary(uniqueKeysWithValues: incoming.map { ($0.envelope.resourceKey, $0.envelope) }),
            namespaceCount: namespaceCount, namespaceBytes: namespaceBytes)
    }

    private func validateNamespaceQuota(_ phase: AssetAdmissionPhase, incoming: [VerifiedCloudRecord]) throws {
        guard phase.namespaceCount >= 0, phase.namespaceBytes >= 0,
            phase.namespaceBytes <= stagedAssetQuota.maximumBytesPerNamespace
        else { throw CloudMirrorAdapterError.malformedPayload(incoming.first?.envelope.resourceKey ?? .string("batch"), "namespace asset quota") }
    }

    private func validateTransferAssetAdmission(
        _ transferID: ObjectID, incomingByKey: [ResourceKey: CloudRecordEnvelope], replacing oldRecords: [LocalMirrorRecord], namespace: PersistenceNamespace
    ) async throws {
        let session = try await stagedAssetSession(transferID, incomingByKey: incomingByKey, namespace: namespace)
        let keys = try await transferMemberKeys(transferID, incomingByKey: incomingByKey, replacing: oldRecords, namespace: namespace)
        guard keys.count <= LocalMirrorMaintenanceLimits.maximumTransferMembers, keys.count <= session.cursor else {
            throw CloudMirrorAdapterError.malformedPayload(
                session.resourceKey,
                "staged asset is outside acknowledged session cursor")
        }
        try await validateTransferQuota(transferID, incomingByKey: incomingByKey, replacing: oldRecords, namespace: namespace)
    }

    private func stagedAssetSession(_ transferID: ObjectID, incomingByKey: [ResourceKey: CloudRecordEnvelope], namespace: PersistenceNamespace) async throws
        -> CloudStagedTransferSession
    {
        let key = ResourceKey.string("workspace-transfer-session:\(transferID.description)")
        let indexed = try await persistence.storedLocalMirrors(for: [key], in: namespace).first
        guard let payload = incomingByKey[key]?.payload ?? indexed?.payload,
            let session = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: payload), session.resourceKey == key,
            session.status != .abandoned, session.cursor <= session.expectedMemberCount, session.cursor <= LocalMirrorMaintenanceLimits.maximumTransferMembers,
            session.expectedMemberCount <= LocalMirrorMaintenanceLimits.maximumTransferMembers
        else { throw CloudMirrorAdapterError.malformedPayload(key, "staged asset without transfer session") }
        return session
    }

    private func transferMemberKeys(
        _ transferID: ObjectID, incomingByKey: [ResourceKey: CloudRecordEnvelope], replacing oldRecords: [LocalMirrorRecord], namespace: PersistenceNamespace
    ) async throws -> Set<ResourceKey> {
        var keys = Set(try await persistence.mirrorTransferMembers(transferID: transferID, in: namespace).map(\.resourceKey))
        for old in oldRecords where stagedTransferID(old.visibility) == transferID { keys.remove(old.resourceKey) }
        for envelope in incomingByKey.values where stagedTransferID(envelope.visibility) == transferID { keys.insert(envelope.resourceKey) }
        return keys
    }

    private func validateTransferQuota(
        _ transferID: ObjectID, incomingByKey: [ResourceKey: CloudRecordEnvelope], replacing oldRecords: [LocalMirrorRecord], namespace: PersistenceNamespace
    ) async throws {
        let current = try await persistence.mirrorTransferAssetUsage(transferID: transferID, in: namespace) ?? (0, 0)
        let old = oldRecords.filter { stagedTransferID($0.visibility) == transferID }.compactMap(\.recordAssetMetadata)
        let incoming = incomingByKey.values.filter { !$0.isDeleted && stagedTransferID($0.visibility) == transferID }.compactMap { $0.recordAsset?.metadata }
        let count = current.assetCount - old.count + incoming.count
        let bytes = current.byteCount - old.reduce(0) { $0 + $1.byteCount } + incoming.reduce(0) { $0 + $1.byteCount }
        guard count >= 0, bytes >= 0, count <= stagedAssetQuota.maximumAssetsPerTransfer,
            bytes <= stagedAssetQuota.maximumBytesPerTransfer
        else { throw CloudMirrorAdapterError.malformedPayload(.string("workspace-transfer-session:\(transferID.description)"), "staged transfer asset quota") }
    }
}
