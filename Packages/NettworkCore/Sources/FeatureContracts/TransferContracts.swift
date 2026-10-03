import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl

@MainActor
public protocol TransferFeatureService {
    func dryRunCSV(_ source: any CSVImportSource, authorization: AuthorizedOperationContext) async throws -> ImportPlan
    func activateCSV(_ plan: ImportPlan, source: any CSVImportSource, authorization: AuthorizedOperationContext) async throws
    func exportArchive(authorization: AuthorizedOperationContext) async throws -> ArchiveExportDocument
    func validateArchiveExportAuthorization(_ authorization: AuthorizedOperationContext) async throws
    func verifyArchive(
        _ source: any ArchiveEntrySource, authorization: AuthorizedOperationContext
    ) async throws -> FileBackedArchiveRestorePreview
    func restoreArchive(
        _ archive: FileBackedVerifiedArchive, approval: ArchiveRestoreApproval,
        authorization: AuthorizedOperationContext
    ) async throws
}

/// Platform composition owns the actual save/share presentation. The feature
/// hands it only the bounded, schema-owned files after an authorized export.
@MainActor
public protocol CSVWorkspaceExportDestination {
    func handoff(_ document: CSVWorkspaceExportDocument) throws
}

public protocol CSVWorkspaceExporting: Sendable {
    func exportCSV(authorization: AuthorizedOperationContext) async throws -> CSVWorkspaceExportDocument
    func validateCSVExportAuthorization(_ authorization: AuthorizedOperationContext) async throws
}
