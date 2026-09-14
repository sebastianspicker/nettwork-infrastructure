import ContentSafety
import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

/// Presentation-only state used by the operations features. The application
/// integration layer supplies a real implementation backed by the authorized
/// domain and CloudKit boundaries.
@MainActor
protocol OperationsFeatureService {
    func synchronizeForeground() async -> SyncReceipt
    func stagedDraft(id: ObjectID) async throws -> WorkOrderDraft
    func validateDraft(_ draft: WorkOrderDraft, authorization: OperationsAuthorization) async throws -> WorkOrderValidation
    func reserve(_ draft: WorkOrderDraft, authorization: OperationsAuthorization) async throws -> WorkOrderReservationPresentation
    func refreshReservation(
        _ reservation: WorkOrderReservationPresentation,
        authorization: OperationsAuthorization
    ) async throws -> WorkOrderReservationPresentation
    func requestApproval(for workOrderID: ObjectID, authorization: OperationsAuthorization) async throws
    func beginExecution(workOrderID: ObjectID, reservationID: ObjectID, intentDigest: IntentDigest, authorization: OperationsAuthorization) async throws
    func complete(workOrderID: ObjectID, evidence: [EvidenceHash], authorization: OperationsAuthorization) async throws
    func requestCancellation(
        workOrderID: ObjectID,
        reason: String,
        physicalStatus: CancellationPhysicalStatus,
        authorization: OperationsAuthorization
    ) async throws -> WorkOrderReservationPresentation
    func resolveCancellation(
        workOrderID: ObjectID,
        reason: String,
        releaseAuthorization: CancellationReleaseAuthorization,
        authorization: OperationsAuthorization
    ) async throws
    func correctiveWorkOrder(for reconciliationID: ObjectID, authorization: OperationsAuthorization) async throws -> ObjectID
}

/// UI-facing boundary for the two-phase evidence workflow. Implementations keep
/// raw content, staging claims, session checks, and authoritative writes out of
/// the feature model.
@MainActor
protocol AttachmentEvidenceFeatureService {
    func prepareEvidence(
        source: any OpaqueContentSource,
        authorization: AuthorizedOperationContext
    ) async throws -> PreparedWorkOrderEvidence

    func bindPreparedEvidence(
        _ prepared: PreparedWorkOrderEvidence,
        to workOrderID: ObjectID,
        authorization: AuthorizedOperationContext
    ) async throws -> AttachmentEvidenceBindingResult

    func cleanupPreparedEvidence(
        _ prepared: PreparedWorkOrderEvidence,
        authorization: AuthorizedOperationContext
    ) async throws
}

/// The app retains only the opaque staged descriptor and exact evidence hash.
/// It never exposes source URLs or attachment bytes to the UI.
struct PreparedWorkOrderEvidence: Equatable, Sendable, Identifiable {
    let descriptor: SanitizedContentDescriptor
    let evidence: EvidenceHash

    var id: ObjectID { evidence.id }
}

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

struct OperationsAuthorization: Equatable, Sendable {
    let actorID: String
    let role: OfficialClientRole
    let sessionGeneration: UInt64
    let isFresh: Bool

    var permitsPrivilegedAction: Bool {
        isFresh && role != .viewer && !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WorkOrderDraft: Identifiable, Equatable, Sendable {
    let id: ObjectID
    var title: String
    var kind: WorkOrderKind
    var ticket: String
    var notes: String
    var resourceKeys: Set<ResourceKey>
    var operations: [PlannedWorkOperation]
    var evidence: [EvidenceHash]

    init(
        id: ObjectID = .init(),
        title: String = "",
        kind: WorkOrderKind = .connect,
        ticket: String = "",
        notes: String = "",
        resourceKeys: Set<ResourceKey> = [],
        operations: [PlannedWorkOperation] = [],
        evidence: [EvidenceHash] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.ticket = ticket
        self.notes = notes
        self.resourceKeys = resourceKeys
        self.operations = operations
        self.evidence = evidence
    }
}

struct WorkOrderValidation: Equatable, Sendable {
    let isValid: Bool
    let exactIntentDigest: IntentDigest?
    let issues: [String]

    static let unvalidated = WorkOrderValidation(isValid: false, exactIntentDigest: nil, issues: ["Validate the draft before requesting a reservation."])
}

struct WorkOrderReservationPresentation: Identifiable, Equatable, Sendable {
    enum Confirmation: Equatable, Sendable {
        case pending, confirmed, expired
        case rejected(String)
    }

    let id: ObjectID
    let workOrderID: ObjectID
    let exactIntentDigest: IntentDigest
    let resourceKeys: Set<ResourceKey>
    let expiresAt: Date
    let confirmation: Confirmation
    let workOrderStatus: WorkOrderStatus
    let cancellationRequestID: ObjectID?

    var isConfirmedAndFresh: Bool {
        if case .confirmed = confirmation { return Date.now < expiresAt }
        return false
    }
}

struct CancellationReleaseRequest: Equatable, Sendable {
    let workOrderID: ObjectID
    let reservationID: ObjectID
    let cancellationRequestID: ObjectID
    let physicalAttestation: String
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

struct ReconciliationComparison: Identifiable, Equatable, Sendable {
    let id: ObjectID
    let title: String
    let reason: String
    let baseSummary: String
    let intendedSummary: String
    let currentSummary: String
    let isSecurityEvent: Bool
}
