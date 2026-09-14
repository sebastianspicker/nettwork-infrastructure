import CloudSync
import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func dryRun(_ archive: VerifiedArchive, for target: PersistenceNamespace) async throws {
        try await dryRunArchive(.memory(archive), for: target)
    }

    func dryRun(_ archive: FileBackedVerifiedArchive, for target: PersistenceNamespace) async throws {
        try await dryRunArchive(.file(archive), for: target)
    }

    func activateStagedArchive(
        archive: VerifiedArchive, source: ArchiveSourceProvenance, target: PersistenceNamespace, expectedRootSHA256: String,
        operationID: ObjectID, expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        try await activateArchive(
            archive: .memory(archive), source: source, target: target, expectedRootSHA256: expectedRootSHA256,
            operationID: operationID, expectedReceipt: expectedReceipt)
    }

    func activateStagedArchive(
        archive: FileBackedVerifiedArchive, source: ArchiveSourceProvenance, target: PersistenceNamespace, expectedRootSHA256: String,
        operationID: ObjectID, expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        try await activateArchive(
            archive: .file(archive), source: source, target: target, expectedRootSHA256: expectedRootSHA256,
            operationID: operationID, expectedReceipt: expectedReceipt)
    }

    private func dryRunArchive(_ archive: ProductionArchiveRestoreInput, for target: PersistenceNamespace) async throws {
        let trusted = try await trustedSession(in: target)
        guard archive.manifest.provenance.workspaceID != target.workspaceID else { throw ProductionWorkspaceTransferAuthorityError.archiveSourceMismatch }
        let transfer = try validatedTransfer(from: archive)
        let audits = try archiveAuditEvents(from: archive.readEntry(at: ArchiveLayout.auditPath))
        try validateArchiveOperationalReferences(transfer, audits: audits, provenance: archive.manifest.provenance)
        let dryRunTransferID = ObjectID()
        let assets = try archiveAssetEnvelopes(from: archive, transfer: transfer, namespace: target, transferID: dryRunTransferID)
        _ = try importedHistoricalReferenceEnvelopes(
            transfer: transfer, audits: audits, assets: assets, provenance: archive.manifest.provenance,
            recordedAt: archive.manifest.createdAt, namespace: target, transferID: dryRunTransferID
        )
        try await sessionAuthorizer.revalidate(trusted)
    }
    private func activateArchive(
        archive: ProductionArchiveRestoreInput, source: ArchiveSourceProvenance, target: PersistenceNamespace, expectedRootSHA256: String,
        operationID: ObjectID, expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        let canonicalReceipt = try archive.expectedReceipt(target: target, operationID: operationID)
        guard source == archive.manifest.provenance, expectedRootSHA256 == archive.rootSHA256, source.workspaceID != target.workspaceID,
            expectedReceipt == canonicalReceipt
        else {
            throw ProductionWorkspaceTransferAuthorityError.archiveRootMismatch
        }
        let trusted = try await trustedSession(in: target)
        let sentinel = try await emptyBootstrapSentinel(in: target)
        let transfer = try validatedTransfer(from: archive)
        let audits = try archiveAuditEvents(from: archive.readEntry(at: ArchiveLayout.auditPath))
        try validateArchiveOperationalReferences(transfer, audits: audits, provenance: archive.manifest.provenance)
        let assets = try archiveAssetEnvelopes(from: archive, transfer: transfer, namespace: target, transferID: operationID)
        let complete = try await stage(
            envelopes: try stagedEnvelopes(
                transfer: transfer, audits: audits, assets: assets,
                provenance: archive.manifest.provenance, recordedAt: archive.manifest.createdAt, namespace: target, transferID: operationID),
            transferID: operationID, operationID: operationID, epoch: sentinel.emptyEpoch, namespace: target, trusted: trusted)
        return try await activate(
            sentinel: sentinel, completeSession: complete, namespace: target, operationID: operationID,
            expectedReceipt: expectedReceipt, trusted: trusted)
    }
}
