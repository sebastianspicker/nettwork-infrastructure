import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
protocol TransferFeatureService {
    func dryRunCSV(_ source: any CSVImportSource, authorization: AuthorizedOperationContext) async throws -> ImportPlan
    func activateCSV(_ plan: ImportPlan, source: any CSVImportSource, authorization: AuthorizedOperationContext) async throws
    func exportArchive(authorization: AuthorizedOperationContext) async throws -> ArchiveExportDocument
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
protocol CSVWorkspaceExportDestination {
    func handoff(_ document: CSVWorkspaceExportDocument) throws
}

protocol CSVWorkspaceExporting: Sendable {
    func exportCSV(authorization: AuthorizedOperationContext) async throws -> CSVWorkspaceExportDocument
    func validateCSVExportAuthorization(_ authorization: AuthorizedOperationContext) async throws
}

enum CSVTransferState {
    case idle
    case dryRunning
    case awaitingActivation(ImportPlan)
    case activating
    case activated
    case failed(String)
}

enum CSVWorkspaceExportState {
    case idle
    case exporting
    case exported(CSVWorkspaceExportDocument)
    case failed(String)
}

enum CSVWorkspaceExportHandoffError: LocalizedError {
    case noStagedExport

    var errorDescription: String? { "Export the current workspace again before handing CSV files to a destination." }
}

enum ArchiveTransferState {
    case idle
    case exporting
    case exported(ArchiveExportDocument)
    case verifyingRestore
    case readyToRestore(FileBackedArchiveRestorePreview)
    case restoring
    case restored
    case failed(String)
}

struct PendingCSVActivation: Identifiable {
    let plan: ImportPlan

    var id: String { plan.canonicalSHA256 }
}

struct ArchiveRestoreApprovalPresentation: Equatable, Sendable {
    let sourceWorkspaceID: ObjectID
    let sourceZone: String
    let sourceZoneOwner: String
    let targetWorkspaceID: ObjectID
    let targetZone: String
    let targetZoneOwner: String
    let operationID: ObjectID
    let createdAt: Date
    let recordCount: Int
    let assetCount: Int
    let assetByteCount: Int
    let auditRecordCount: Int
    let auditHeadSHA256: String
    let rootSHA256: String
    let compatibility: String
}

struct PendingArchiveRestore: Identifiable {
    let approval: ArchiveRestoreApproval
    let presentation: ArchiveRestoreApprovalPresentation

    var id: String { presentation.operationID.description }
}
