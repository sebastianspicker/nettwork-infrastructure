import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl

@MainActor
extension TransferFeatureViewModel {
    var isCSVOperationInFlight: Bool { csvOperation != nil }
    var canBeginCSVDryRun: Bool { csvOperation == nil }
    var canActivateCSV: Bool {
        guard csvOperation == nil, stagedCSVImport != nil else { return false }
        if case .awaitingActivation = csvState { return true }
        return false
    }

    func dryRunCSV(source: any CSVImportSource, authorization: AuthorizedOperationContext) async {
        guard authorization.action == .importCSV else {
            releaseCSVSource(source)
            reportCSVFailure("The current authorization is not an import authorization.")
            return
        }
        guard canBeginCSVDryRun else {
            releaseCSVSource(source)
            return
        }
        releaseStagedCSVSource()
        let token = beginCSVOperation(.dryRunning)
        csvState = .dryRunning
        do {
            let plan = try await service.dryRunCSV(source, authorization: authorization)
            try Task.checkCancellation()
            guard isCurrentCSVOperation(token, .dryRunning) else {
                releaseCSVSource(source)
                return
            }
            stagedCSVImport = StagedCSVImport(
                source: source, plan: plan, authorization: authorization, generation: token)
            csvState = .awaitingActivation(plan)
            finishCSVOperation(token)
        } catch is CancellationError {
            guard isCurrentCSVOperation(token, .dryRunning) else {
                releaseCSVSource(source)
                return
            }
            releaseCSVSource(source)
            csvState = .idle
            finishCSVOperation(token)
        } catch {
            guard isCurrentCSVOperation(token, .dryRunning) else {
                releaseCSVSource(source)
                return
            }
            releaseCSVSource(source)
            csvState = .failed(error.localizedDescription)
            finishCSVOperation(token)
        }
    }

    func activateCSV(expectedPlan: ImportPlan) async {
        guard case let .awaitingActivation(displayedPlan) = csvState,
            displayedPlan == expectedPlan,
            let stagedImport = stagedCSVImport,
            stagedImport.plan == expectedPlan,
            stagedImport.authorization.action == .importCSV,
            canActivateCSV
        else {
            reportCSVFailure("Run a matching dry run before activation.")
            return
        }
        let token = beginCSVOperation(.activating)
        csvState = .activating
        do {
            try await service.activateCSV(
                stagedImport.plan, source: stagedImport.source,
                authorization: stagedImport.authorization)
            guard isCurrentCSVOperation(token, .activating),
                stagedCSVImport?.generation == stagedImport.generation
            else {
                releaseCSVSource(stagedImport.source)
                return
            }
            csvState = .activated
            releaseCSVSource(stagedImport.source)
            stagedCSVImport = nil
            finishCSVOperation(token)
        } catch {
            guard isCurrentCSVOperation(token, .activating),
                stagedCSVImport?.generation == stagedImport.generation
            else {
                releaseCSVSource(stagedImport.source)
                return
            }
            releaseCSVSource(stagedImport.source)
            stagedCSVImport = nil
            csvState = .failed(error.localizedDescription)
            finishCSVOperation(token)
        }
    }

    func cancelCSVImport() {
        if csvOperation != nil {
            csvOperation = nil
            csvOperationToken = nil
            stagedCSVImport = nil
            csvState = .idle
            return
        }
        releaseStagedCSVSource()
        csvState = .idle
    }

    private func beginCSVOperation(_ operation: CSVOperation) -> UUID {
        let token = UUID()
        csvOperation = operation
        csvOperationToken = token
        return token
    }

    private func isCurrentCSVOperation(_ token: UUID, _ operation: CSVOperation) -> Bool {
        csvOperationToken == token && csvOperation == operation
    }

    private func finishCSVOperation(_ token: UUID) {
        guard csvOperationToken == token else { return }
        csvOperation = nil
        csvOperationToken = nil
    }

    private func reportCSVFailure(_ message: String) {
        guard csvOperation == nil else { return }
        releaseStagedCSVSource()
        csvState = .failed(message)
    }

    private func releaseStagedCSVSource() {
        if let source = stagedCSVImport?.source { releaseCSVSource(source) }
        stagedCSVImport = nil
    }

    private func releaseCSVSource(_ source: any CSVImportSource) {
        (source as? any CSVImportSourceAccessLifetime)?.close()
    }
}
