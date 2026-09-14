import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

public actor SwiftDataCloudMirrorStore: CloudMirrorStore {
    let persistence: SwiftDataPersistenceStore
    let semanticValidator: any CloudRemoteSemanticValidator
    let snapshotProvider: any CloudRemoteSnapshotProvider
    let referenceValidator: any CloudRemoteReferenceValidator
    let stagedAssetQuota: CloudStagedAssetQuotaPolicy
    var activeLease: PersistenceNamespaceLease?

    public init(
        persistence: SwiftDataPersistenceStore, semanticValidator: any CloudRemoteSemanticValidator, snapshotProvider: any CloudRemoteSnapshotProvider,
        referenceValidator: any CloudRemoteReferenceValidator,
        stagedAssetQuota: CloudStagedAssetQuotaPolicy
    ) {
        self.persistence = persistence
        self.semanticValidator = semanticValidator
        self.snapshotProvider = snapshotProvider
        self.referenceValidator = referenceValidator
        self.stagedAssetQuota = stagedAssetQuota
    }

    /// Fail-closed production composition with structural decoding, a complete
    /// persisted reference index, and candidate-state invariant validation.
    public init(
        productionPersistence persistence: SwiftDataPersistenceStore,
        stagedAssetQuota: CloudStagedAssetQuotaPolicy
    ) {
        self.persistence = persistence
        self.stagedAssetQuota = stagedAssetQuota
        semanticValidator = CodableCloudRemoteSemanticValidator()
        snapshotProvider = SwiftDataCloudRemoteSnapshotProvider(persistence: persistence)
        referenceValidator = CompositeCloudRemoteReferenceValidator()
    }

    public func open(namespace: PersistenceNamespace) async throws {
        if let activeLease { await persistence.invalidate(activeLease) }
        activeLease = await persistence.activateLease(for: namespace)
        // V9 repair is explicit and fail-closed. Ordinary opens do not scan
        // mirror rows, attachments, or evidence caches.
        if try await persistence.mirrorMaintenanceNeedsRepair(in: namespace) {
            try await repairMirrorMaintenanceIndexes(in: namespace)
        }
        var evidenceRepairCursor: String?
        repeat {
            let page = try await persistence.mirrorEvidenceProjectionRepairPage(
                in: namespace,
                afterStorageKey: evidenceRepairCursor)
            try await persistence.reconcileAttachmentEvidenceFromMirror(
                candidates: page.candidates,
                namespace: namespace)
            evidenceRepairCursor = page.nextStorageKey
        } while evidenceRepairCursor != nil
        try await persistence.reconcileVerifiedMirrorAttachments(namespace: namespace)
        try await persistence.materializeInventorySearchProjection(in: namespace)
        try await persistence.rebuildConflictResourceIndex(in: namespace)
    }

    public func close(namespace: PersistenceNamespace) async {
        guard let lease = activeLease, lease.namespace == namespace else { return }
        activeLease = nil
        await persistence.invalidate(lease)
    }

    public func purgeEphemeralState() async {
        guard let lease = activeLease else { return }
        activeLease = nil
        await persistence.invalidate(lease)
    }

    public func validateRemoteReferences(_ records: [VerifiedCloudRecord], namespace: PersistenceNamespace) async throws {
        _ = try requireOpen(namespace)
        try await semanticValidator.validate(records, namespace: namespace)
        let snapshot: CloudRemoteMirrorSnapshot
        if let indexedProvider = snapshotProvider as? SwiftDataCloudRemoteSnapshotProvider {
            snapshot = try await indexedProvider.snapshot(candidate: records, in: namespace)
        } else {
            snapshot = try await snapshotProvider.snapshot(in: namespace)
        }
        try await referenceValidator.validate(candidate: records, against: snapshot, namespace: namespace)
    }
}
