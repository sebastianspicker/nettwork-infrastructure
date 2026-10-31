import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

enum WorkOrderEvidenceState: Equatable {
    case preparing
    case prepared
    case awaitingAuthorization
    case binding
    case bound(OperationReceipt)
    case cleaningUp
    case cancelled
    case failed(String)
}

struct WorkOrderEvidenceItem: Identifiable, Equatable {
    let id: UUID
    var prepared: PreparedWorkOrderEvidence?
    var state: WorkOrderEvidenceState

    init(id: UUID = UUID(), prepared: PreparedWorkOrderEvidence? = nil, state: WorkOrderEvidenceState) {
        self.id = id
        self.prepared = prepared
        self.state = state
    }

    var isPreparedButUnbound: Bool {
        prepared != nil
            && {
                switch state {
                case .bound: false
                default: true
                }
            }()
    }
}

enum OperationsFeatureModelError: LocalizedError {
    case invalidAuthoritativePresentation

    var errorDescription: String? {
        "The authoritative work-order response did not match the requested transition."
    }
}

struct OperationsWorkOrderRow: Identifiable, Equatable, Sendable {
    let id: ObjectID
    let title: String
    let status: WorkOrderStatus
    let ticket: String?
    let reservationExpiresAt: Date?
    let updatedAt: Date
    /// Holds resources without a fresh acknowledged reservation.
    let pendingOverlay: Bool
    /// Holds resources under an unexpired acknowledged reservation.
    let confirmedOverlay: Bool

    init(summary: WorkOrderSummary, now: Date = .now) {
        id = summary.id
        title = summary.title
        status = summary.status
        ticket = summary.ticket
        reservationExpiresAt = summary.reservationExpiresAt
        updatedAt = summary.updatedAt
        let holdsResources = [.reserved, .approved, .executing, .cancellationRequested].contains(summary.status)
        confirmedOverlay = holdsResources && summary.reservationExpiresAt.map { now < $0 } == true
        pendingOverlay = holdsResources && !confirmedOverlay
    }
}
