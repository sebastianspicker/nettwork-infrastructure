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
    let pendingOverlay: Bool
    let confirmedOverlay: Bool
}
