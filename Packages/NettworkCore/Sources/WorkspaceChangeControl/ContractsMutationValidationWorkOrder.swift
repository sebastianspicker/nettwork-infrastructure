import Foundation
import NetworkModel

extension AuthoritativeMutationValidator {
    static func validateMutationMetadata(_ mutation: AuthoritativeMutation) throws {
        guard !mutation.workspaceZone.containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !mutation.workspaceZone.zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AuthoritativeMutationValidationError.invalidScope
        }
        guard !mutation.actor.actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !mutation.actor.installationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !mutation.actor.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AuthoritativeMutationValidationError.invalidActorSnapshot
        }
        guard mutation.workOrder.intentDigest != nil else {
            throw AuthoritativeMutationValidationError.missingWorkOrderIntentDigest
        }
        guard mutation.workOrder.intentDigest == mutation.intentDigest else {
            throw AuthoritativeMutationValidationError.intentDigestMismatch
        }
        guard !mutation.encodedWorkOrder.isEmpty,
            !mutation.encodedAuditEvent.isEmpty,
            !mutation.encodedReceipt.isEmpty,
            (try? StableMutationPayloadCoding.decode(WorkOrder.self, from: mutation.encodedWorkOrder)) == mutation.workOrder,
            (try? StableMutationPayloadCoding.decode(AuditEvent.self, from: mutation.encodedAuditEvent)) == mutation.auditEvent,
            (try? StableMutationPayloadCoding.decode(OperationReceipt.self, from: mutation.encodedReceipt)) == mutation.receipt
        else {
            throw AuthoritativeMutationValidationError.invalidImmutablePayload
        }
    }

    static func validateSubmittedWorkOrder(
        _ mutation: AuthoritativeMutation,
        state: AuthoritativeMutationState
    ) throws {
        guard let current = state.currentWorkOrder else {
            guard mutation.workOrder.revision == mutation.expectedWorkOrderRevision else {
                throw AuthoritativeMutationValidationError.invalidSubmittedWorkOrderRevision(
                    expected: mutation.expectedWorkOrderRevision, actual: mutation.workOrder.revision)
            }
            return
        }
        guard current.id == mutation.workOrder.id,
            current.revision == mutation.expectedWorkOrderRevision
        else {
            throw AuthoritativeMutationValidationError.staleWorkOrderRevision(
                expected: mutation.expectedWorkOrderRevision,
                actual: current.revision
            )
        }
        guard current.revision < Int.max,
            mutation.workOrder.revision == current.revision + 1
        else {
            throw AuthoritativeMutationValidationError.invalidSubmittedWorkOrderRevision(
                expected: current.revision + 1,
                actual: mutation.workOrder.revision
            )
        }
        try validateWorkOrderTransition(current, submitted: mutation.workOrder, observedAt: mutation.actor.capturedAt)
    }

    static func validateWorkOrderTransition(
        _ current: WorkOrder,
        submitted: WorkOrder,
        observedAt: Date
    ) throws {
        if current.status == submitted.status {
            guard current.status == .reserved,
                let acknowledgement = submitted.reservation?.acknowledgedByCloudKit,
                (try? WorkOrderStateMachine.acknowledgeReservation(
                    current,
                    acknowledgement: acknowledgement, observedAt: observedAt)) == submitted
            else {
                throw AuthoritativeMutationValidationError.invalidWorkOrderTransition
            }
            return
        }
        do {
            try WorkOrderStateMachine.validateStatusTransition(from: current.status, to: submitted.status)
        } catch {
            throw AuthoritativeMutationValidationError.invalidWorkOrderTransition
        }
    }

    static func validateReservationAuthority(
        _ mutation: AuthoritativeMutation,
        state: AuthoritativeMutationState
    ) throws {
        guard [.reserved, .approved, .executing, .cancellationRequested].contains(mutation.workOrder.status) else {
            return
        }
        let reservation = try validatedReservation(for: mutation)
        guard canonicalIntentMatches(mutation, reservation: reservation) else {
            throw AuthoritativeMutationValidationError.reservationIntentMismatch
        }
        if mutation.workOrder.status == .reserved,
            state.currentWorkOrder?.status != .reserved,
            reservation.ownerID != mutation.actor.actorID
        {
            throw AuthoritativeMutationValidationError.reservationOwnerMismatch
        }
    }

    static func validatedReservation(for mutation: AuthoritativeMutation) throws -> WorkOrderReservation {
        guard let reservation = mutation.workOrder.reservation,
            !reservation.ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !reservation.resourceKeys.isEmpty
        else {
            throw AuthoritativeMutationValidationError.reservationScopeMismatch
        }
        return reservation
    }

    static func canonicalIntentMatches(
        _ mutation: AuthoritativeMutation,
        reservation: WorkOrderReservation
    ) -> Bool {
        let workOrder = mutation.workOrder
        let canonicalIntent = CanonicalWorkIntent(
            intentSchemaVersion: workOrder.intentSchemaVersion ?? 1,
            workOrderID: workOrder.id,
            kind: workOrder.kind,
            creatorID: workOrder.creatorID,
            ticket: workOrder.ticket,
            notes: workOrder.notes,
            operations: workOrder.plannedOperations,
            resourceKeys: reservation.resourceKeys,
            evidenceHashes: workOrder.evidenceHashes
        )
        return (try? canonicalIntent.digest()) == mutation.intentDigest
    }

    static func validateExecutingReservation(_ mutation: AuthoritativeMutation) throws {
        guard mutation.workOrder.status == .executing else { return }
        guard let reservation = mutation.workOrder.reservation,
            let acknowledgement = reservation.acknowledgedByCloudKit,
            reservation.ownerID == mutation.actor.actorID,
            acknowledgement.ownerID == mutation.actor.actorID,
            acknowledgement.cloudKitAccountRecordName == mutation.actor.actorID
        else {
            throw AuthoritativeMutationValidationError.reservationOwnerMismatch
        }
        try validateExecutingReservationScope(acknowledgement, reservation: reservation, mutation: mutation)
        guard canonicalIntentMatches(mutation, reservation: reservation),
            acknowledgement.intentDigest == mutation.intentDigest
        else {
            throw AuthoritativeMutationValidationError.reservationIntentMismatch
        }
        guard acknowledgement.acknowledgedAt <= mutation.actor.capturedAt,
            mutation.actor.capturedAt < acknowledgement.expiresAt
        else {
            throw AuthoritativeMutationValidationError.reservationExpired
        }
    }

    static func validateExecutingReservationScope(
        _ acknowledgement: CloudKitAcknowledgement,
        reservation: WorkOrderReservation,
        mutation: AuthoritativeMutation
    ) throws {
        guard acknowledgement.workspaceZone == mutation.workspaceZone,
            acknowledgement.sessionGeneration == mutation.actor.sessionGeneration,
            acknowledgement.reservationID == reservation.id,
            acknowledgement.workOrderID == mutation.workOrder.id,
            acknowledgement.resourceKeys == reservation.resourceKeys,
            !acknowledgement.systemFields.isEmpty,
            !acknowledgement.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AuthoritativeMutationValidationError.reservationScopeMismatch
        }
    }
}
