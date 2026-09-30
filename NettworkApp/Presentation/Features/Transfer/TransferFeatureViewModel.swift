import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
@Observable
final class TransferFeatureViewModel {
    enum CSVOperation: Equatable {
        case dryRunning
        case activating
    }
    struct StagedCSVImport {
        let source: any CSVImportSource
        let plan: ImportPlan
        let authorization: AuthorizedOperationContext
        let generation: UUID
    }
    private enum ArchiveOperation: Equatable {
        case exporting
        case verifying
        case restoring
    }
    var csvState: CSVTransferState = .idle
    private(set) var csvWorkspaceExportState: CSVWorkspaceExportState = .idle
    private(set) var archiveState: ArchiveTransferState = .idle
    var stagedCSVImport: StagedCSVImport?
    var csvOperation: CSVOperation?
    var csvOperationToken: UUID?
    private var csvWorkspaceExportToken: UUID?
    private var stagedCSVWorkspaceExportAuthorization: AuthorizedOperationContext?
    var stagedArchiveAuthorization: AuthorizedOperationContext?
    private var restoreSelectionToken: UUID?
    private var archiveOperation: ArchiveOperation?
    private var archiveOperationToken: UUID?
    let service: any TransferFeatureService
    private let csvExporter: any CSVWorkspaceExporting
    init(service: any TransferFeatureService, csvExporter: any CSVWorkspaceExporting) {
        self.service = service
        self.csvExporter = csvExporter
    }
    var isArchiveOperationInFlight: Bool { archiveOperation != nil }
    var canBeginArchiveExport: Bool {
        guard archiveOperation == nil else { return false }
        if case .readyToRestore = archiveState { return false }
        return true
    }
    var canBeginArchiveVerification: Bool { archiveOperation == nil }
    var canBeginCSVWorkspaceExport: Bool { csvWorkspaceExportToken == nil }
    func exportCSV(authorization: AuthorizedOperationContext) async {
        guard authorization.action == .exportCSV else {
            csvWorkspaceExportState = .failed("The current authorization is not a CSV export authorization.")
            return
        }
        guard canBeginCSVWorkspaceExport else { return }
        let token = UUID()
        csvWorkspaceExportToken = token
        stagedCSVWorkspaceExportAuthorization = nil
        csvWorkspaceExportState = .exporting
        do {
            let document = try await csvExporter.exportCSV(authorization: authorization)
            try Task.checkCancellation()
            guard csvWorkspaceExportToken == token else { return }
            csvWorkspaceExportState = .exported(document)
            stagedCSVWorkspaceExportAuthorization = authorization
            csvWorkspaceExportToken = nil
        } catch is CancellationError {
            guard csvWorkspaceExportToken == token else { return }
            csvWorkspaceExportState = .idle
            stagedCSVWorkspaceExportAuthorization = nil
            csvWorkspaceExportToken = nil
        } catch {
            guard csvWorkspaceExportToken == token else { return }
            csvWorkspaceExportState = .failed(error.localizedDescription)
            stagedCSVWorkspaceExportAuthorization = nil
            csvWorkspaceExportToken = nil
        }
    }

    func handoffCSVExport(to destination: any CSVWorkspaceExportDestination) async throws {
        guard case .exported(let document) = csvWorkspaceExportState,
            let authorization = stagedCSVWorkspaceExportAuthorization
        else {
            throw CSVWorkspaceExportHandoffError.noStagedExport
        }
        try await csvExporter.validateCSVExportAuthorization(authorization)
        try Task.checkCancellation()
        try destination.handoff(document)
        try await csvExporter.validateCSVExportAuthorization(authorization)
    }

    func prepareCSVExportHandoff() async throws -> CSVWorkspaceExportDocument {
        guard case .exported(let document) = csvWorkspaceExportState,
            let authorization = stagedCSVWorkspaceExportAuthorization
        else {
            throw CSVWorkspaceExportHandoffError.noStagedExport
        }
        try await csvExporter.validateCSVExportAuthorization(authorization)
        return document
    }

    func validateCSVExportHandoff() async throws {
        guard let authorization = stagedCSVWorkspaceExportAuthorization else {
            throw CSVWorkspaceExportHandoffError.noStagedExport
        }
        try await csvExporter.validateCSVExportAuthorization(authorization)
    }

    func exportArchive(authorization: AuthorizedOperationContext) async {
        guard authorization.action == .exportArchive else {
            reportArchiveFailure("The current authorization is not an archive export authorization.")
            return
        }
        guard canBeginArchiveExport else { return }
        let token = beginArchiveOperation(.exporting)
        archiveState = .exporting
        do {
            let document = try await service.exportArchive(authorization: authorization)
            try Task.checkCancellation()
            guard isCurrentArchiveOperation(token, .exporting) else { return }
            archiveState = .exported(document)
            finishArchiveOperation(token)
        } catch is CancellationError {
            guard isCurrentArchiveOperation(token, .exporting) else { return }
            archiveState = .idle
            finishArchiveOperation(token)
        } catch {
            guard isCurrentArchiveOperation(token, .exporting) else { return }
            archiveState = .failed(error.localizedDescription)
            finishArchiveOperation(token)
        }
    }

    func verifyRestore(source: any ArchiveEntrySource, authorization: AuthorizedOperationContext) async {
        guard authorization.action == .restoreArchive else {
            rejectArchiveVerification(source)
            return
        }
        guard canBeginArchiveVerification else {
            releaseArchiveSource(source)
            return
        }
        releaseStagedArchivePreview()
        let token = beginArchiveOperation(.verifying)
        restoreSelectionToken = token
        archiveState = .verifyingRestore
        do {
            let preview = try await service.verifyArchive(source, authorization: authorization)
            do { try Task.checkCancellation() } catch {
                preview.discardIfUnadopted()
                throw error
            }
            guard canAcceptArchiveVerification(token) else {
                preview.discardIfUnadopted()
                discardArchiveVerification(source, token: token)
                return
            }
            stagedArchiveAuthorization = authorization
            archiveState = .readyToRestore(preview)
            finishArchiveOperation(token)
        } catch is CancellationError { finishArchiveVerification(source, token: token, state: .idle) } catch {
            finishArchiveVerification(source, token: token, state: .failed(error.localizedDescription))
        }
    }

    private func rejectArchiveVerification(_ source: any ArchiveEntrySource) {
        releaseArchiveSource(source)
        reportArchiveFailure("The current authorization is not an archive restore authorization.")
    }

    private func canAcceptArchiveVerification(_ token: UUID) -> Bool {
        isCurrentArchiveOperation(token, .verifying) && restoreSelectionToken == token
    }

    private func discardArchiveVerification(_ source: any ArchiveEntrySource, token: UUID) {
        releaseArchiveSource(source)
        finishArchiveOperation(token)
    }

    private func finishArchiveVerification(
        _ source: any ArchiveEntrySource,
        token: UUID,
        state: ArchiveTransferState
    ) {
        releaseArchiveSource(source)
        guard isCurrentArchiveOperation(token, .verifying) else { return }
        if restoreSelectionToken == token {
            restoreSelectionToken = nil
            archiveState = state
        }
        finishArchiveOperation(token)
    }

    func restoreArchive(
        expectedApproval: ArchiveRestoreApproval,
        presentation: ArchiveRestoreApprovalPresentation
    ) async {
        guard case .readyToRestore(let preview) = archiveState,
            let authorization = stagedArchiveAuthorization,
            authorization.action == .restoreArchive,
            preview.approval == expectedApproval,
            archiveRestoreApprovalPresentation == presentation,
            archiveOperation == nil
        else {
            if archiveOperation == nil {
                releaseStagedArchivePreview()
                archiveState = .failed("Verify the selected archive again after changing restore authorization.")
            }
            return
        }
        let token = beginArchiveOperation(.restoring)
        archiveState = .restoring
        do {
            try await service.restoreArchive(
                preview.archive, approval: preview.approval,
                authorization: authorization)
            guard isCurrentArchiveOperation(token, .restoring) else { return }
            preview.discardIfUnadopted()
            stagedArchiveAuthorization = nil
            restoreSelectionToken = nil
            archiveState = .restored
            finishArchiveOperation(token)
        } catch {
            guard isCurrentArchiveOperation(token, .restoring) else { return }
            preview.discardIfUnadopted()
            stagedArchiveAuthorization = nil
            restoreSelectionToken = nil
            archiveState = .failed(error.localizedDescription)
            finishArchiveOperation(token)
        }
    }

    func cancelVerifiedRestore() {
        switch archiveState {
        case .verifyingRestore:
            // Keep the source open until the in-flight verifier returns; it owns
            // that access lifetime. Its token makes the completion a no-op.
            restoreSelectionToken = nil
            archiveState = .idle
        case .readyToRestore:
            restoreSelectionToken = nil
            releaseStagedArchivePreview()
            archiveState = .idle
        case .idle, .exporting, .exported, .restoring, .restored, .failed:
            break
        }
    }

    func reportArchiveSelectionFailure(_ error: Error) {
        guard archiveOperation == nil else { return }
        releaseStagedArchivePreview()
        archiveState = .failed(error.localizedDescription)
    }

    private func releaseStagedArchivePreview() {
        if case let .readyToRestore(preview) = archiveState {
            preview.discardIfUnadopted()
        }
        stagedArchiveAuthorization = nil
    }

    private func releaseArchiveSource(_ source: any ArchiveEntrySource) {
        (source as? any ArchiveEntrySourceAccessLifetime)?.close()
    }

    private func beginArchiveOperation(_ operation: ArchiveOperation) -> UUID {
        let token = UUID()
        archiveOperation = operation
        archiveOperationToken = token
        return token
    }

    private func isCurrentArchiveOperation(_ token: UUID, _ operation: ArchiveOperation) -> Bool {
        archiveOperationToken == token && archiveOperation == operation
    }

    private func finishArchiveOperation(_ token: UUID) {
        guard archiveOperationToken == token else { return }
        archiveOperation = nil
        archiveOperationToken = nil
    }

    private func reportArchiveFailure(_ message: String) {
        guard archiveOperation == nil else { return }
        archiveState = .failed(message)
    }
}
