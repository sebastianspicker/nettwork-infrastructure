import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    public func dryRun(_ records: [ImportRecord], in namespace: PersistenceNamespace) async throws -> ImportDryRunReport {
        let trusted = try await trustedSession(in: namespace)
        let transfer = try ValidatedWorkspaceTransfer.reconstructAndValidate(imports: records)
        try await sessionAuthorizer.revalidate(trusted)
        return ImportDryRunReport(
            canonicalSHA256: CanonicalImportDigest.digest(records: records),
            validatorVersion: WorkspaceTransferRecord.currentSchemaVersion, validatedRecordCount: transfer.candidate.records.count)
    }
    public func activateStagedCSV(
        records: [ImportRecord], plan: ImportPlan, requiringEmptyWorkspace: Bool,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        let canonicalReceipt = try CSVImportActivationReceipt.expected(for: plan)
        guard requiringEmptyWorkspace, plan.namespace == account.namespace,
            expectedReceipt == canonicalReceipt,
            plan.canonicalSHA256 == CanonicalImportDigest.digest(records: records)
        else { throw ProductionWorkspaceTransferAuthorityError.receiptMismatch }
        let trusted = try await trustedSession(in: plan.namespace)
        let sentinel = try await emptyBootstrapSentinel(in: plan.namespace)
        let transfer = try ValidatedWorkspaceTransfer.reconstructAndValidate(imports: records)
        guard transfer.candidate.records.count == plan.totalRecordCount,
            transfer.candidate.records.count == plan.dryRunReport.validatedRecordCount
        else {
            throw ProductionWorkspaceTransferAuthorityError.nonCanonicalTransfer
        }
        let complete = try await stage(
            envelopes: try stagedEnvelopes(
                transfer: transfer, audits: [], assets: [], namespace: plan.namespace,
                transferID: plan.transferID), transferID: plan.transferID, operationID: plan.operationID, epoch: sentinel.emptyEpoch,
            namespace: plan.namespace, trusted: trusted)
        return try await activate(
            sentinel: sentinel, completeSession: complete, namespace: plan.namespace, operationID: plan.operationID,
            expectedReceipt: expectedReceipt, trusted: trusted)
    }
}
