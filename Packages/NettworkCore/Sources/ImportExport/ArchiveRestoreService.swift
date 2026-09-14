import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public protocol ArchiveRestoreStore: Sendable {
    func currentAccount() async throws -> AccountContext
    func isFreshAuthenticatedTarget(in namespace: PersistenceNamespace) async throws -> Bool
    /// Validate cross-record, trace, IPAM, and audit invariants before staging.
    func dryRun(_ archive: VerifiedArchive, for target: PersistenceNamespace) async throws
    func dryRun(_ archive: FileBackedVerifiedArchive, for target: PersistenceNamespace) async throws
    func createRestoreStaging(source: ArchiveSourceProvenance, target: PersistenceNamespace, operationID: ObjectID) async throws -> ImportStagingHandle
    func stage(_ archive: VerifiedArchive, in staging: ImportStagingHandle) async throws
    func stage(_ archive: FileBackedVerifiedArchive, in staging: ImportStagingHandle) async throws
    /// On success, returns exactly `expectedReceipt` from the atomic visibility transition.
    func activateRestore(
        _ staging: ImportStagingHandle, expectedFreshTarget: PersistenceNamespace,
        operationID: ObjectID, expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt
    /// Explicit terminal cleanup only: confirmed cancellation or unrecoverable
    /// input. Retryable failures retain the sidecar for a later reopen.
    func discardRestore(_ staging: ImportStagingHandle) async
}

public extension ArchiveRestoreStore {
    func dryRun(
        _ archive: FileBackedVerifiedArchive, for target: PersistenceNamespace
    ) async throws {
        throw ArchiveValidationError.archiveDecodeFailed("file-backed restore unsupported")
    }

    func stage(
        _ archive: FileBackedVerifiedArchive, in staging: ImportStagingHandle
    ) async throws {
        throw ArchiveValidationError.archiveDecodeFailed("file-backed restore unsupported")
    }
}

public struct AuthorizedArchiveRestoreService: Sendable {
    let store: any ArchiveRestoreStore
    private let verifier: ArchiveVerifier
    private let currentContext: any CurrentAuthorizationContextProviding

    public init(
        store: any ArchiveRestoreStore, currentContext: any CurrentAuthorizationContextProviding,
        verifier: ArchiveVerifier = .init()
    ) {
        self.store = store
        self.currentContext = currentContext
        self.verifier = verifier
    }
    public func restore(
        source: any ArchiveEntrySource, approval: ArchiveRestoreApproval,
        context: AuthorizedOperationContext
    ) async throws -> OperationReceipt {
        try await authorize(context)
        let archive = try verifier.verify(source: source)
        guard try approval.matches(archive: archive, authorization: context) else {
            throw ArchiveValidationError.approvalMismatch
        }
        try await authorize(context)
        let expectedReceipt = try ArchiveRestoreActivationReceipt.expected(
            for: archive,
            target: context.account.namespace, operationID: context.operationID)
        guard try await store.isFreshAuthenticatedTarget(in: context.account.namespace) else { throw ImportPlanError.workspaceNotEmpty }
        try await authorize(context)
        guard archive.manifest.provenance.workspaceID != context.account.namespace.workspaceID else { throw ArchiveValidationError.manifestMismatch }
        try await store.dryRun(archive, for: context.account.namespace)
        try await authorize(context)
        let staging = try await store.createRestoreStaging(
            source: archive.manifest.provenance, target: context.account.namespace, operationID: context.operationID)
        return try await completeRestore(
            staging, context: context, expectedReceipt: expectedReceipt
        ) {
            try await store.stage(archive, in: staging)
        }
    }

    func completeRestore(
        _ staging: ImportStagingHandle, context: AuthorizedOperationContext,
        expectedReceipt: OperationReceipt,
        stage: () async throws -> Void
    ) async throws -> OperationReceipt {
        do {
            try await authorize(context)
            guard staging.namespace == context.account.namespace, staging.generation > 0 else {
                throw ImportPlanError.invalidStagingHandle
            }
            try await authorize(context)
            try await stage()
            try await authorize(context)
            let receipt = try await store.activateRestore(
                staging,
                expectedFreshTarget: context.account.namespace, operationID: context.operationID,
                expectedReceipt: expectedReceipt)
            guard receipt == expectedReceipt else {
                throw ImportPlanError.activationReceiptMismatch
            }
            return receipt
        } catch {
            await discardRestoreIfTerminal(staging, error: error)
            throw error
        }
    }

    private func discardRestoreIfTerminal(
        _ staging: ImportStagingHandle, error: Error
    ) async {
        guard StagedTransferCleanupClassifier.disposition(for: error).discardsStaging else {
            return
        }
        await store.discardRestore(staging)
    }

    func authorize(_ context: AuthorizedOperationContext) async throws {
        try await ImportOperationAuthorization.validate(
            context, expectedAction: .restoreArchive, currentContext: currentContext,
            currentAccount: { try await self.store.currentAccount() })
    }
}

/// Deterministically binds a restore receipt to the verified archive root and
/// manifest commitment, source provenance, exact target namespace, and operation.
public enum ArchiveRestoreActivationReceipt {
    public static func expected(
        for archive: VerifiedArchive, target: PersistenceNamespace,
        operationID: ObjectID
    ) throws -> OperationReceipt {
        try expected(
            manifest: archive.manifest, rootSHA256: archive.rootSHA256,
            target: target, operationID: operationID)
    }

    public static func expected(
        for archive: FileBackedVerifiedArchive, target: PersistenceNamespace,
        operationID: ObjectID
    ) throws -> OperationReceipt {
        try expected(
            manifest: archive.manifest, rootSHA256: archive.rootSHA256,
            target: target, operationID: operationID)
    }

    static func expected(
        manifest: ArchiveManifest, rootSHA256: String,
        target: PersistenceNamespace, operationID: ObjectID
    ) throws -> OperationReceipt {
        let manifestCommitment = try ArchiveManifestCommitment.digest(for: manifest)
        let provenance = manifest.provenance
        let intent = try CanonicalActivationReceipt.intent(
            domain: "nettwork.archive-restore-activation-intent.v1", namespace: target,
            operationID: operationID,
            fields: [
                rootSHA256, manifestCommitment,
                String(manifest.schemaVersion), provenance.workspaceID.description,
                provenance.containerIdentifier, provenance.zoneName, provenance.zoneOwnerRecordName,
            ])
        return OperationReceipt(
            workspaceZone: target.workspaceZone, operationID: operationID,
            intentDigest: intent, auditEventID: AuditEvent.deterministicID(for: operationID))
    }
}

/// Checksums detect corruption but do not prove authenticity against a malicious writable participant; signing or WORM storage needs an independent authority.
public enum ArchiveIntegrityDisclosure {
    public static let checksumsAreNotAuthenticityProof = "Checksums detect corruption but do not prove authenticity against a malicious writable participant."
}
