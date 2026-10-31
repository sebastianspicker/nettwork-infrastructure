import FeatureContracts
import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

@MainActor
extension OperationsFeatureViewModel {
    /// Lists the authoritative work orders and the durable staged drafts. A
    /// draft that already became a work order is listed only as that order.
    func loadWorkOrders() async {
        do {
            let summaries = try await service.workOrders()
            let drafts = try await service.stagedDrafts()
            let workOrderIDs = Set(summaries.map(\.id))
            workOrderRows = summaries.map { OperationsWorkOrderRow(summary: $0) }
            var merged = Dictionary(stagedDrafts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for staged in drafts { merged[staged.id] = staged }
            stagedDrafts = merged.values
                .filter { !workOrderIDs.contains($0.id) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            workOrderListError = nil
        } catch {
            workOrderListError = error.localizedDescription
        }
    }

    /// Continues an existing work order from its authoritative record. The
    /// reopened phase only selects which existing lifecycle action is offered;
    /// each action is still authorized and validated by the service.
    func reopenWorkOrder(_ id: ObjectID, using authorization: OperationsAuthorization) async {
        guard authorization.permitsPrivilegedAction else {
            fail("A fresh technician or administrator authorization is required.")
            return
        }
        guard canReopenWorkOrder else {
            fail("Bind or discard the prepared evidence before opening another work order.")
            return
        }
        guard let operation = beginLifecycleOperation() else { return }
        defer { finishLifecycleOperation(operation) }
        do {
            let reopened = try await service.reopenWorkOrder(id: id, authorization: authorization)
            guard reopened.draft.id == id, reopened.reservation.map({ $0.workOrderID == id && $0.workOrderStatus == reopened.status }) ?? true
            else {
                throw OperationsFeatureModelError.invalidAuthoritativePresentation
            }
            adopt(reopened)
        } catch {
            fail(error)
        }
    }

    private func adopt(_ reopened: ReopenedWorkOrder) {
        evidenceItems = []
        draft = reopened.draft
        reservation = reopened.reservation
        if let digest = reopened.reservation?.exactIntentDigest {
            // The authoritative digest binds every later lifecycle check.
            validation = WorkOrderValidation(isValid: true, exactIntentDigest: digest, issues: [])
            validatedDraft = reopened.draft
        }
        isReleasedWorkOrder = reopened.status == .cancelled
        phaseBeforeFailure = nil
        lastError = nil
        phase = reopened.reservation.map { phase(for: $0) } ?? Self.phase(forUnreserved: reopened.status)
    }

    var canReserveFreshCopy: Bool { lifecycleOperation == nil && isReleasedWorkOrder && isWorkOrderFinished }

    /// Renews a released reservation: the same reviewed intent becomes a new
    /// draft that must be validated and reserved through the normal path. An
    /// expired reservation cannot be extended in place, because its locks stay
    /// on the server until the cancellation path releases them.
    func prepareFreshCopyOfReleasedWorkOrder() {
        guard canReserveFreshCopy else {
            fail("Release the expired reservation through cancellation before reserving it again.")
            return
        }
        let released = draft
        reservation = nil
        evidenceItems = []
        isReleasedWorkOrder = false
        draft = WorkOrderDraft(
            title: released.title, kind: released.kind, ticket: released.ticket, notes: released.notes, resourceKeys: released.resourceKeys,
            operations: released.operations)
        phaseBeforeFailure = nil
        lastError = nil
        phase = .editing
    }

    /// Guidance for a reservation that no longer protects its work.
    var reservationRecoveryText: String? {
        if isReleasedWorkOrder {
            return "The reservation was released. Reserve a fresh copy to renew it; the copy is validated and reserved again."
        }
        guard let reservation, [.reserved, .approved, .executing].contains(reservation.workOrderStatus), !reservation.isConfirmedAndFresh else {
            return nil
        }
        switch reservation.confirmation {
        case .pending:
            return "The reservation is not confirmed yet. Synchronize, then reserve again to resume it, or request cancellation to release it."
        default:
            return "The reservation expired at \(reservation.expiresAt.formatted()). Request cancellation to release its resources, "
                + "then reserve a fresh copy."
        }
    }

    private static func phase(forUnreserved status: WorkOrderStatus) -> Phase {
        switch status {
        case .draft: .editing
        case .completed, .cancelled: .completed
        case .reconciliation: .reconciling
        case .reserved, .approved, .executing, .cancellationRequested: .awaitingConfirmation
        }
    }
}
