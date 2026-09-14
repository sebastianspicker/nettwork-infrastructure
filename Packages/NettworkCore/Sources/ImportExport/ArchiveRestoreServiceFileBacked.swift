import Foundation
import NetworkModel
import WorkspaceChangeControl

extension AuthorizedArchiveRestoreService {
    public func restore(
        archive: FileBackedVerifiedArchive, approval: ArchiveRestoreApproval,
        context: AuthorizedOperationContext
    ) async throws -> OperationReceipt {
        defer { archive.discardIfUnadopted() }
        try await authorize(context)
        guard try approval.matches(archive: archive, authorization: context) else {
            throw ArchiveValidationError.approvalMismatch
        }
        try await authorize(context)
        let expectedReceipt = try ArchiveRestoreActivationReceipt.expected(
            for: archive, target: context.account.namespace,
            operationID: context.operationID)
        guard try await store.isFreshAuthenticatedTarget(in: context.account.namespace) else {
            throw ImportPlanError.workspaceNotEmpty
        }
        try await authorize(context)
        guard archive.manifest.provenance.workspaceID != context.account.namespace.workspaceID else {
            throw ArchiveValidationError.manifestMismatch
        }
        try await store.dryRun(archive, for: context.account.namespace)
        try await authorize(context)
        let staging = try await store.createRestoreStaging(
            source: archive.manifest.provenance, target: context.account.namespace,
            operationID: context.operationID)
        return try await completeRestore(
            staging, context: context, expectedReceipt: expectedReceipt
        ) {
            try await store.stage(archive, in: staging)
        }
    }
}
