import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

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

enum ArchiveExportHandoffError: LocalizedError {
    case noStagedExport

    var errorDescription: String? { "Export the current workspace again before saving an archive." }
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
