import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

@MainActor
extension OperationsFeatureViewModel {
    func prepareEvidence(
        source: any OpaqueContentSource,
        authorization: AuthorizedOperationContext
    ) async {
        guard canPrepareEvidence else {
            fail("Evidence can only be prepared before the draft is validated and reserved.")
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        let itemID = UUID()
        evidenceItems.append(.init(id: itemID, state: .preparing))
        do {
            let prepared = try await evidenceService.prepareEvidence(source: source, authorization: authorization)
            guard let index = evidenceItems.firstIndex(where: { $0.id == itemID }) else { return }
            evidenceItems[index].prepared = prepared
            evidenceItems[index].state = .prepared
            if !draft.evidence.contains(prepared.evidence) {
                draft.evidence.append(prepared.evidence)
            }
            validation = .unvalidated
            phase = .editing
            lastError = nil
        } catch is CancellationError {
            updateEvidenceItem(itemID) { $0.state = .cancelled }
        } catch {
            updateEvidenceItem(itemID) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func cleanupPreparedEvidence(
        itemID: UUID,
        authorization: AuthorizedOperationContext?
    ) async {
        guard reservation == nil,
            lifecycleOperation == nil,
            let index = evidenceItems.firstIndex(where: { $0.id == itemID }),
            let prepared = evidenceItems[index].prepared,
            evidenceItems[index].state != .cleaningUp,
            evidenceItems[index].state != .binding
        else {
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        guard let authorization else {
            evidenceItems[index].state = .awaitingAuthorization
            return
        }
        evidenceItems[index].state = .cleaningUp
        do {
            try await evidenceService.cleanupPreparedEvidence(prepared, authorization: authorization)
            draft.evidence.removeAll { $0 == prepared.evidence }
            evidenceItems.removeAll { $0.id == itemID }
            validation = .unvalidated
            phase = .editing
        } catch is CancellationError {
            updateEvidenceItem(itemID) { $0.state = .prepared }
        } catch {
            updateEvidenceItem(itemID) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func bindPreparedEvidenceIfPossible(
        using evidenceAuthorization: (() -> AuthorizedOperationContext?)?
    ) async {
        guard lifecycleOperation == nil,
            reservation?.isConfirmedAndFresh == true,
            evidenceItems.contains(where: \.isPreparedButUnbound),
            let operation = beginLifecycleOperation()
        else {
            return
        }
        defer { finishLifecycleOperation(operation) }
        await bindPreparedEvidenceAlreadyLocked(using: evidenceAuthorization)
    }

    func bindPreparedEvidenceAlreadyLocked(
        using evidenceAuthorization: (() -> AuthorizedOperationContext?)?
    ) async {
        guard reservation?.isConfirmedAndFresh == true else { return }
        for itemID in evidenceItems.map(\.id) {
            guard let index = evidenceItems.firstIndex(where: { $0.id == itemID }),
                let prepared = evidenceItems[index].prepared,
                evidenceItems[index].isPreparedButUnbound
            else {
                continue
            }
            guard let authorization = evidenceAuthorization?() else {
                evidenceItems[index].state = .awaitingAuthorization
                continue
            }
            evidenceItems[index].state = .binding
            do {
                let result = try await evidenceService.bindPreparedEvidence(
                    prepared,
                    to: draft.id,
                    authorization: authorization
                )
                guard result.evidence == prepared.evidence else {
                    throw AttachmentEvidenceBindingError.invalidReceipt
                }
                updateEvidenceItem(itemID) { $0.state = .bound(result.receipt) }
                lastError = nil
            } catch is CancellationError {
                updateEvidenceItem(itemID) { $0.state = .prepared }
            } catch {
                updateEvidenceItem(itemID) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    func dismissError() {
        lastError = nil
        if let phaseBeforeFailure {
            phase = phaseBeforeFailure
            self.phaseBeforeFailure = nil
        }
    }

    func phase(for reservation: WorkOrderReservationPresentation) -> Phase {
        switch reservation.workOrderStatus {
        case .reserved, .approved, .executing:
            return reservation.isConfirmedAndFresh ? confirmedPhase(for: reservation.workOrderStatus) : .awaitingConfirmation
        case .completed, .cancelled: return .completed
        case .reconciliation: return .reconciling
        case .draft: return .editing
        case .cancellationRequested: return .cancellationRequested
        }
    }

    private func confirmedPhase(for status: WorkOrderStatus) -> Phase {
        switch status {
        case .reserved: return .reserved
        case .approved: return .approved
        case .executing: return .executing
        default: return .editing
        }
    }

    fileprivate func updateEvidenceItem(_ itemID: UUID, _ update: (inout WorkOrderEvidenceItem) -> Void) {
        guard let index = evidenceItems.firstIndex(where: { $0.id == itemID }) else { return }
        update(&evidenceItems[index])
    }

    func beginLifecycleOperation() -> UUID? {
        guard lifecycleOperation == nil else { return nil }
        let operation = UUID()
        lifecycleOperation = operation
        return operation
    }

    func finishLifecycleOperation(_ operation: UUID) {
        guard lifecycleOperation == operation else { return }
        lifecycleOperation = nil
    }

    var isPristineDraft: Bool {
        draft.title.isEmpty && draft.ticket.isEmpty && draft.notes.isEmpty && draft.resourceKeys.isEmpty && draft.operations.isEmpty && draft.evidence.isEmpty
    }

    func fail(_ error: Error) { fail(error.localizedDescription) }
    func fail(_ message: String) {
        if case .failed = phase {
        } else {
            phaseBeforeFailure = phase
        }
        lastError = message
        phase = .failed(message)
    }
}
