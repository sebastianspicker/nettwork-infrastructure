import Foundation
import NetworkModel

public enum CancellationPhysicalStatus: String, Codable, Sendable { case unknown, notStarted, completed, notPerformed }

public struct CancellationReleaseScope: Codable, Hashable, Sendable {
    public let workspaceZone: AuthoritativeWorkspaceZone
    public let workOrderID: ObjectID
    public let reservationID: ObjectID
    public let cancellationRequestID: ObjectID
    public let actorID: String
    public let installationID: String
    public let sessionID: String
    public let sessionGeneration: UInt64
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        workspaceZone: AuthoritativeWorkspaceZone, workOrderID: ObjectID, reservationID: ObjectID, cancellationRequestID: ObjectID, actorID: String,
        installationID: String, sessionID: String,
        sessionGeneration: UInt64, issuedAt: Date, expiresAt: Date
    ) {
        self.workspaceZone = workspaceZone
        self.workOrderID = workOrderID
        self.reservationID = reservationID
        self.cancellationRequestID = cancellationRequestID
        self.actorID = actorID
        self.installationID = installationID
        self.sessionID = sessionID
        self.sessionGeneration = sessionGeneration
        self.issuedAt = issuedAt.canonicalPayloadTimestamp
        self.expiresAt = expiresAt.canonicalPayloadTimestamp
    }
}

public enum CancellationReleaseAuthorization: Codable, Hashable, Sendable {
    case attestation(scope: CancellationReleaseScope, statement: String)
    case emergencyOverride(scope: CancellationReleaseScope, reason: String)

    public var scope: CancellationReleaseScope {
        switch self {
        case let .attestation(scope, _), let .emergencyOverride(scope, _): scope
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, scope, statement, reason }
    private enum Kind: String, Codable { case attestation, emergencyOverride }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .attestation:
            self = .attestation(
                scope: try container.decode(CancellationReleaseScope.self, forKey: .scope), statement: try container.decode(String.self, forKey: .statement))
        case .emergencyOverride:
            self = .emergencyOverride(
                scope: try container.decode(CancellationReleaseScope.self, forKey: .scope), reason: try container.decode(String.self, forKey: .reason))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .attestation(scope, statement):
            try container.encode(Kind.attestation, forKey: .kind)
            try container.encode(scope, forKey: .scope)
            try container.encode(statement, forKey: .statement)
        case let .emergencyOverride(scope, reason):
            try container.encode(Kind.emergencyOverride, forKey: .kind)
            try container.encode(scope, forKey: .scope)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public struct WorkOrderCancellation: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public let requestedBy: String
    public let reason: String
    public let requestedAt: Date
    public let physicalStatus: CancellationPhysicalStatus
    public let releaseAuthorization: CancellationReleaseAuthorization?
    public let resolvedAt: Date?
    public init(
        id: ObjectID = .init(), requestedBy: String, reason: String, requestedAt: Date, physicalStatus: CancellationPhysicalStatus,
        releaseAuthorization: CancellationReleaseAuthorization? = nil, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.requestedBy = requestedBy
        self.reason = reason
        self.requestedAt = requestedAt.canonicalPayloadTimestamp
        self.physicalStatus = physicalStatus
        self.releaseAuthorization = releaseAuthorization
        self.resolvedAt = resolvedAt?.canonicalPayloadTimestamp
    }
}

public struct WorkOrderTransitionContext: Hashable, Sendable {
    public let actorID: String
    public let at: Date
    public let cancellationPhysicalStatus: CancellationPhysicalStatus
    public let releaseAuthorization: CancellationReleaseAuthorization?
    public init(
        actorID: String, at: Date = .now, cancellationPhysicalStatus: CancellationPhysicalStatus = .unknown,
        releaseAuthorization: CancellationReleaseAuthorization? = nil
    ) {
        self.actorID = actorID
        self.at = at.canonicalPayloadTimestamp
        self.cancellationPhysicalStatus = cancellationPhysicalStatus
        self.releaseAuthorization = releaseAuthorization
    }
}

public enum WorkOrderTransitionError: Error, Hashable, Sendable {
    case invalidTransition(from: WorkOrderStatus, to: WorkOrderStatus)
    case cancellationReasonRequired
    case resourcesRequired
    case cloudKitAcknowledgementRequired
    case cloudKitAcknowledgementMismatch
    case cloudKitAcknowledgementExpired
    case reservationAlreadyAcknowledged
    case cancellationReleaseAuthorizationRequired
    case invalidActor
    case revisionOverflow
}

public enum WorkOrderStateMachine {
    public static func validateStatusTransition(from: WorkOrderStatus, to: WorkOrderStatus) throws {
        guard allowedTransitions[from, default: []].contains(to) else {
            throw WorkOrderTransitionError.invalidTransition(from: from, to: to)
        }
    }

    /// Compatibility entry point. New code should record the actual actor with the context overload.
    public static func transition(_ order: WorkOrder, to status: WorkOrderStatus, cancellationReason: String? = nil) throws -> WorkOrder {
        try transition(order, to: status, context: WorkOrderTransitionContext(actorID: order.creatorID), cancellationReason: cancellationReason)
    }

    public static func transition(_ order: WorkOrder, to status: WorkOrderStatus, context: WorkOrderTransitionContext, cancellationReason: String? = nil) throws
        -> WorkOrder
    {
        let reason = try validatedTransitionReason(order, status: status, context: context, cancellationReason: cancellationReason)
        var updated = order
        updated.status = status
        updated.advanceRevision()
        try apply(status: status, reason: reason, context: context, to: &updated)
        return updated
    }

    private static func validatedTransitionReason(_ order: WorkOrder, status: WorkOrderStatus, context: WorkOrderTransitionContext, cancellationReason: String?)
        throws -> String?
    {
        try validateTransitionPrerequisites(order, status: status, context: context)
        if status == .executing { try validateExecutingTransition(order, context: context) }
        let normalizedReason = try validatedCancellationReason(status: status, value: cancellationReason)
        if order.status == .cancellationRequested && status == .cancelled && context.releaseAuthorization == nil {
            throw WorkOrderTransitionError.cancellationReleaseAuthorizationRequired
        }
        guard order.revision < Int.max else { throw WorkOrderTransitionError.revisionOverflow }
        return normalizedReason
    }

    private static func validateTransitionPrerequisites(_ order: WorkOrder, status: WorkOrderStatus, context: WorkOrderTransitionContext) throws {
        guard !context.actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkOrderTransitionError.invalidActor }
        try validateStatusTransition(from: order.status, to: status)
        guard status != .reserved || !order.reservedResourceKeys.isEmpty else { throw WorkOrderTransitionError.resourcesRequired }
    }

    private static func validatedCancellationReason(status: WorkOrderStatus, value: String?) throws -> String? {
        let reason = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status != .cancelled || !(reason?.isEmpty ?? true) else { throw WorkOrderTransitionError.cancellationReasonRequired }
        return reason
    }

    private static func apply(status: WorkOrderStatus, reason: String?, context: WorkOrderTransitionContext, to updated: inout WorkOrder) throws {
        switch status {
        case .approved:
            updated.approvedBy = context.actorID
            updated.approvedAt = context.at
        case .executing:
            updated.executedBy = context.actorID
            updated.executionStartedAt = context.at
        case .completed: updated.completedAt = context.at
        case .cancellationRequested:
            try applyCancellationRequest(reason, context: context, to: &updated)
        case .cancelled:
            try applyCancellation(reason, context: context, to: &updated)
        case .draft, .reserved, .reconciliation: break
        }
    }

    private static func applyCancellationRequest(_ reason: String?, context: WorkOrderTransitionContext, to updated: inout WorkOrder) throws {
        guard let reason, !reason.isEmpty else { throw WorkOrderTransitionError.cancellationReasonRequired }
        updated.cancellationReason = reason
        updated.cancellationHistory.append(
            WorkOrderCancellation(requestedBy: context.actorID, reason: reason, requestedAt: context.at, physicalStatus: context.cancellationPhysicalStatus))
    }

    private static func applyCancellation(_ reason: String?, context: WorkOrderTransitionContext, to updated: inout WorkOrder) throws {
        guard let reason, !reason.isEmpty else { throw WorkOrderTransitionError.cancellationReasonRequired }
        updated.cancellationReason = reason
        guard let index = updated.cancellationHistory.indices.last, updated.cancellationHistory[index].releaseAuthorization == nil else {
            updated.cancellationHistory.append(
                WorkOrderCancellation(
                    requestedBy: context.actorID, reason: reason, requestedAt: context.at, physicalStatus: .notStarted,
                    releaseAuthorization: context.releaseAuthorization, resolvedAt: context.at))
            return
        }
        let request = updated.cancellationHistory[index]
        updated.cancellationHistory[index] = WorkOrderCancellation(
            id: request.id, requestedBy: request.requestedBy, reason: request.reason, requestedAt: request.requestedAt,
            physicalStatus: request.physicalStatus, releaseAuthorization: context.releaseAuthorization, resolvedAt: context.at)
    }

    private static func validateExecutingTransition(_ order: WorkOrder, context: WorkOrderTransitionContext) throws {
        guard let reservation = order.reservation, !reservation.ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !reservation.resourceKeys.isEmpty,
            let acknowledgement = reservation.acknowledgedByCloudKit
        else { throw WorkOrderTransitionError.cloudKitAcknowledgementRequired }
        guard let intentDigest = order.intentDigest,
            acknowledgement.reservationID == reservation.id, acknowledgement.workOrderID == order.id,
            acknowledgement.ownerID == reservation.ownerID, reservation.ownerID == context.actorID,
            acknowledgement.cloudKitAccountRecordName == context.actorID,
            acknowledgement.resourceKeys == reservation.resourceKeys,
            acknowledgement.intentDigest == intentDigest
        else { throw WorkOrderTransitionError.cloudKitAcknowledgementMismatch }
        try validateAcknowledgementMetadata(acknowledgement, at: context.at)
    }

    private static func validateAcknowledgementMetadata(_ acknowledgement: CloudKitAcknowledgement, at date: Date) throws {
        let zone = acknowledgement.workspaceZone
        guard !zone.containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !zone.zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !zone.zoneOwnerRecordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !acknowledgement.cloudKitAccountRecordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !acknowledgement.systemFields.isEmpty,
            !acknowledgement.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw WorkOrderTransitionError.cloudKitAcknowledgementMismatch }
        guard acknowledgement.acknowledgedAt <= date, date < acknowledgement.expiresAt else { throw WorkOrderTransitionError.cloudKitAcknowledgementExpired }
    }

    /// Binds the exact server-returned metadata for a reservation without
    /// changing its lifecycle status. The acknowledgement is a separate
    /// conditional revision because CloudKit metadata does not exist until the
    /// initial reservation record has been accepted by the server.
    public static func acknowledgeReservation(
        _ order: WorkOrder, acknowledgement: CloudKitAcknowledgement,
        observedAt: Date = .now
    ) throws -> WorkOrder {
        guard order.status == .reserved, let reservation = order.reservation,
            let intentDigest = order.intentDigest
        else {
            throw WorkOrderTransitionError.cloudKitAcknowledgementRequired
        }
        guard reservation.acknowledgedByCloudKit == nil else {
            throw WorkOrderTransitionError.reservationAlreadyAcknowledged
        }
        let canonicalIntent = CanonicalWorkIntent(
            intentSchemaVersion: order.intentSchemaVersion ?? 1,
            workOrderID: order.id, kind: order.kind, creatorID: order.creatorID, ticket: order.ticket,
            notes: order.notes, operations: order.plannedOperations, resourceKeys: reservation.resourceKeys,
            evidenceHashes: order.evidenceHashes)
        guard acknowledgement.reservationID == reservation.id, acknowledgement.workOrderID == order.id,
            acknowledgement.ownerID == reservation.ownerID,
            acknowledgement.cloudKitAccountRecordName == reservation.ownerID,
            acknowledgement.resourceKeys == reservation.resourceKeys,
            acknowledgement.intentDigest == intentDigest, (try? canonicalIntent.digest()) == intentDigest,
            !acknowledgement.workspaceZone.containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !acknowledgement.workspaceZone.zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !acknowledgement.workspaceZone.zoneOwnerRecordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !acknowledgement.systemFields.isEmpty,
            !acknowledgement.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw WorkOrderTransitionError.cloudKitAcknowledgementMismatch
        }
        guard acknowledgement.acknowledgedAt <= observedAt, observedAt < acknowledgement.expiresAt else {
            throw WorkOrderTransitionError.cloudKitAcknowledgementExpired
        }
        guard order.revision < Int.max else { throw WorkOrderTransitionError.revisionOverflow }

        var updated = order
        updated.reservation = WorkOrderReservation(
            id: reservation.id, ownerID: reservation.ownerID,
            resourceKeys: reservation.resourceKeys, acknowledgedByCloudKit: acknowledgement)
        updated.advanceRevision()
        return updated
    }

    public static func requestCancellation(
        _ order: WorkOrder, reason: String, by actorID: String, physicalStatus: CancellationPhysicalStatus = .unknown, at: Date = .now
    ) throws -> WorkOrder {
        try transition(
            order, to: .cancellationRequested, context: WorkOrderTransitionContext(actorID: actorID, at: at, cancellationPhysicalStatus: physicalStatus),
            cancellationReason: reason)
    }

    public static func resolveCancellation(_ order: WorkOrder, reason: String, authorization: CancellationReleaseAuthorization, at: Date = .now) throws
        -> WorkOrder
    {
        let actorID: String
        actorID = authorization.scope.actorID
        return try transition(
            order, to: .cancelled, context: WorkOrderTransitionContext(actorID: actorID, at: at, releaseAuthorization: authorization),
            cancellationReason: reason)
    }

    private static let allowedTransitions: [WorkOrderStatus: Set<WorkOrderStatus>] = [
        .draft: [.reserved, .cancelled],
        .reserved: [.approved, .cancellationRequested, .cancelled, .reconciliation],
        .approved: [.executing, .cancellationRequested, .cancelled, .reconciliation],
        .executing: [.completed, .cancellationRequested, .reconciliation], .completed: [.reconciliation],
        .cancellationRequested: [.cancelled, .reconciliation], .cancelled: [.reconciliation],
        .reconciliation: [],
    ]
}
