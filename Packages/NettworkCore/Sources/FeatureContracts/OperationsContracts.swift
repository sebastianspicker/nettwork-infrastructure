import ContentSafety
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Presentation-only state used by the operations features. The application
/// integration layer supplies a real implementation backed by the authorized
/// domain and CloudKit boundaries.
@MainActor
public protocol OperationsFeatureService {
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
public protocol AttachmentEvidenceFeatureService {
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
public struct PreparedWorkOrderEvidence: Equatable, Sendable, Identifiable {
    public let descriptor: SanitizedContentDescriptor
    public let evidence: EvidenceHash

    public init(descriptor: SanitizedContentDescriptor, evidence: EvidenceHash) {
        self.descriptor = descriptor
        self.evidence = evidence
    }

    public var id: ObjectID { evidence.id }
}

public struct OperationsAuthorization: Equatable, Sendable {
    public let actorID: String
    public let role: OfficialClientRole
    public let sessionGeneration: UInt64
    public let isFresh: Bool

    public init(actorID: String, role: OfficialClientRole, sessionGeneration: UInt64, isFresh: Bool) {
        self.actorID = actorID
        self.role = role
        self.sessionGeneration = sessionGeneration
        self.isFresh = isFresh
    }

    public var permitsPrivilegedAction: Bool {
        isFresh && role != .viewer && !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct WorkOrderDraft: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public var title: String
    public var kind: WorkOrderKind
    public var ticket: String
    public var notes: String
    public var resourceKeys: Set<ResourceKey>
    public var operations: [PlannedWorkOperation]
    public var evidence: [EvidenceHash]

    public init(
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

public struct WorkOrderValidation: Equatable, Sendable {
    public let isValid: Bool
    public let exactIntentDigest: IntentDigest?
    public let issues: [String]

    public init(isValid: Bool, exactIntentDigest: IntentDigest?, issues: [String]) {
        self.isValid = isValid
        self.exactIntentDigest = exactIntentDigest
        self.issues = issues
    }

    public static let unvalidated = WorkOrderValidation(isValid: false, exactIntentDigest: nil, issues: ["Validate the draft before requesting a reservation."])
}

public struct WorkOrderReservationPresentation: Identifiable, Equatable, Sendable {
    public enum Confirmation: Equatable, Sendable {
        case pending, confirmed, expired
        case rejected(String)
    }

    public let id: ObjectID
    public let workOrderID: ObjectID
    public let exactIntentDigest: IntentDigest
    public let resourceKeys: Set<ResourceKey>
    public let expiresAt: Date
    public let confirmation: Confirmation
    public let workOrderStatus: WorkOrderStatus
    public let cancellationRequestID: ObjectID?

    public init(
        id: ObjectID,
        workOrderID: ObjectID,
        exactIntentDigest: IntentDigest,
        resourceKeys: Set<ResourceKey>,
        expiresAt: Date,
        confirmation: Confirmation,
        workOrderStatus: WorkOrderStatus,
        cancellationRequestID: ObjectID?
    ) {
        self.id = id
        self.workOrderID = workOrderID
        self.exactIntentDigest = exactIntentDigest
        self.resourceKeys = resourceKeys
        self.expiresAt = expiresAt
        self.confirmation = confirmation
        self.workOrderStatus = workOrderStatus
        self.cancellationRequestID = cancellationRequestID
    }

    public var isConfirmedAndFresh: Bool {
        if case .confirmed = confirmation { return Date.now < expiresAt }
        return false
    }
}

public struct CancellationReleaseRequest: Equatable, Sendable {
    public let workOrderID: ObjectID
    public let reservationID: ObjectID
    public let cancellationRequestID: ObjectID
    public let physicalAttestation: String

    public init(workOrderID: ObjectID, reservationID: ObjectID, cancellationRequestID: ObjectID, physicalAttestation: String) {
        self.workOrderID = workOrderID
        self.reservationID = reservationID
        self.cancellationRequestID = cancellationRequestID
        self.physicalAttestation = physicalAttestation
    }
}
