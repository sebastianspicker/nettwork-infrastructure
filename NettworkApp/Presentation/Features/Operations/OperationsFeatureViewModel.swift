import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

@MainActor
@Observable
final class OperationsFeatureViewModel {
    enum Phase: Equatable {
        case editing
        case validating
        case readyToReserve
        case reserving
        case awaitingConfirmation
        case reserved
        case requestingApproval
        case approved
        case beginningExecution
        case executing
        case completing
        case completed
        case cancellationRequested
        case resolvingCancellation
        case reconciling
        case failed(String)
    }

    var draft: WorkOrderDraft {
        didSet {
            guard draft != oldValue else { return }
            validatedDraft = nil
            validation = .unvalidated
            validationGeneration &+= 1
            if phase == .readyToReserve { phase = .editing }
        }
    }
    var validation: WorkOrderValidation = .unvalidated
    var reservation: WorkOrderReservationPresentation?
    var syncReceipt: SyncReceipt?
    var phase: Phase = .editing
    var lastError: String?
    var phaseBeforeFailure: Phase?
    let service: any OperationsFeatureService
    let evidenceService: any AttachmentEvidenceFeatureService
    var evidenceItems: [WorkOrderEvidenceItem] = []
    var stagedDrafts: [WorkOrderDraft] = []
    /// Authoritative work orders from the mirror; each can be reopened.
    var workOrderRows: [OperationsWorkOrderRow] = []
    var workOrderListError: String?
    /// The open work order's reservation was released through cancellation,
    /// so a fresh copy of its intent may be reserved again.
    var isReleasedWorkOrder = false
    var validatedDraft: WorkOrderDraft?
    var validationGeneration: UInt64 = 0
    var lifecycleOperation: UUID?

    init(
        draft: WorkOrderDraft = .init(),
        service: any OperationsFeatureService,
        evidenceService: any AttachmentEvidenceFeatureService
    ) {
        self.draft = draft
        self.service = service
        self.evidenceService = evidenceService
    }

    var hasFreshSync: Bool {
        guard let receipt = syncReceipt else { return false }
        return receipt.failures.isEmpty && receipt.lastSuccessfulServerContact != nil
    }
    var canReserve: Bool {
        lifecycleOperation == nil && validation.isValid && validation.exactIntentDigest != nil && validatedDraft == draft && hasFreshSync
    }
    var canEditDraft: Bool {
        guard reservation == nil, lifecycleOperation == nil else { return false }
        switch phase {
        case .validating, .reserving: return false
        default: return true
        }
    }
    var canRequestApproval: Bool { lifecycleOperation == nil && phase == .reserved && reservation?.isConfirmedAndFresh == true }
    var canExecute: Bool { lifecycleOperation == nil && phase == .approved && reservation?.isConfirmedAndFresh == true }
    var hasUnboundPreparedEvidence: Bool { evidenceItems.contains(where: \.isPreparedButUnbound) }
    var canComplete: Bool {
        lifecycleOperation == nil && phase == .executing && reservation?.isConfirmedAndFresh == true && !hasUnboundPreparedEvidence
    }
    var canRequestCancellation: Bool {
        guard lifecycleOperation == nil else { return false }
        switch phase {
        case .reserved, .approved, .executing: return true
        // An expired or unconfirmed reservation still holds its locks; the
        // cancellation path is how they are released.
        case .awaitingConfirmation: return reservation.map { [.reserved, .approved, .executing].contains($0.workOrderStatus) } ?? false
        default: return false
        }
    }
    var canResolveCancellation: Bool { lifecycleOperation == nil && phase == .cancellationRequested }
    var canSynchronize: Bool { lifecycleOperation == nil }
    var canValidate: Bool { lifecycleOperation == nil && reservation == nil }
    /// A completed (or cancellation-resolved) work order holds no locks, so its
    /// reservation and bound evidence must not keep the next staged draft out.
    var isWorkOrderFinished: Bool { phase == .completed }
    var canSelectStagedDraft: Bool {
        lifecycleOperation == nil && (isWorkOrderFinished || (reservation == nil && evidenceItems.isEmpty))
    }
    /// Reopening replaces the open work order with authoritative state, so
    /// only evidence that is prepared but not yet bound would be lost.
    var canReopenWorkOrder: Bool { lifecycleOperation == nil && !hasUnboundPreparedEvidence }
    var canPrepareEvidence: Bool {
        lifecycleOperation == nil && reservation == nil && (phase == .editing || phase == .readyToReserve) && !evidenceItems.contains { $0.state == .preparing }
    }
}
