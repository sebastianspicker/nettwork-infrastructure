import CloudSync
import CryptoKit
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension ProductionFeatureMutationAuthority {
    public func reserve(
        _ draft: WorkOrderDraft, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation {
        let trusted = try await sessionAuthorizer.authorizeMutation(namespace: namespace, presentation: authorization)
        let issues = structuralIssues(for: draft) + (try await semanticValidator.issues(for: draft, in: namespace))
        guard issues.isEmpty else { throw ProductionFeatureMutationAuthorityError.invalidDraft(issues) }
        let material = try reservationMaterial(for: draft, trusted: trusted)
        try await commitReservation(material, trusted: trusted, namespace: namespace)
        return try await acknowledgeReservation(material, authorization: authorization, namespace: namespace)
    }

    public func refreshReservation(
        _ reservation: WorkOrderReservationPresentation, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation {
        let trusted = try await authorize(authorization, namespace: namespace)
        let (workOrder, _) = try await exactWorkOrder(id: reservation.workOrderID, in: namespace)
        guard workOrder.reservation?.id == reservation.id,
            workOrder.intentDigest == reservation.exactIntentDigest,
            workOrder.reservation?.ownerID == trusted.actor.cloudKitUserRecordName,
            workOrder.reservation?.resourceKeys == reservation.resourceKeys
        else {
            throw ProductionFeatureMutationAuthorityError.invalidReservation
        }
        let confirmation: WorkOrderReservationPresentation.Confirmation
        if let acknowledgement = workOrder.reservation?.acknowledgedByCloudKit {
            guard acknowledgement.workspaceZone == namespace.workspaceZone,
                acknowledgement.cloudKitAccountRecordName == trusted.account.namespace.cloudKitAccountRecordName,
                acknowledgement.sessionGeneration == trusted.actor.sessionGeneration,
                acknowledgement.reservationID == reservation.id,
                acknowledgement.workOrderID == reservation.workOrderID,
                acknowledgement.ownerID == trusted.actor.cloudKitUserRecordName,
                acknowledgement.resourceKeys == reservation.resourceKeys,
                acknowledgement.intentDigest == reservation.exactIntentDigest,
                acknowledgement.expiresAt == reservation.expiresAt,
                !acknowledgement.systemFields.isEmpty,
                !acknowledgement.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                acknowledgement.acknowledgedAt <= Date.now,
                acknowledgement.acknowledgedAt <= acknowledgement.expiresAt
            else {
                throw ProductionFeatureMutationAuthorityError.invalidReservation
            }
            try await sessionAuthorizer.revalidate(trusted)
            confirmation = Date.now < acknowledgement.expiresAt ? .confirmed : .expired
        } else {
            try await sessionAuthorizer.revalidate(trusted)
            confirmation = .pending
        }
        return presentation(for: workOrder, confirmation: confirmation)
    }

    public func requestApproval(for workOrderID: ObjectID, authorization: OperationsAuthorization, in namespace: PersistenceNamespace) async throws {
        let trusted = try await authorize(authorization, namespace: namespace)
        _ = try await commitTransition(
            workOrderID: workOrderID,
            namespace: namespace,
            trusted: trusted,
            phase: "approve",
            material: .init()
        ) { current in
            try WorkOrderStateMachine.transition(
                current,
                to: .approved,
                context: .init(actorID: trusted.actor.cloudKitUserRecordName, at: trusted.actorSnapshot.capturedAt)
            )
        }
    }

    public func beginExecution(
        workOrderID: ObjectID, reservationID: ObjectID, intentDigest: IntentDigest, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws {
        let trusted = try await authorize(authorization, namespace: namespace)
        _ = try await commitTransition(
            workOrderID: workOrderID,
            namespace: namespace,
            trusted: trusted,
            phase: "begin-execution",
            material: .init()
        ) { current in
            guard current.reservation?.id == reservationID,
                current.intentDigest == intentDigest,
                current.reservation?.acknowledgedByCloudKit != nil
            else {
                throw ProductionFeatureMutationAuthorityError.reservationNotAcknowledged
            }
            return try WorkOrderStateMachine.transition(
                current,
                to: .executing,
                context: .init(actorID: trusted.actor.cloudKitUserRecordName, at: trusted.actorSnapshot.capturedAt)
            )
        }
    }

    public func complete(workOrderID: ObjectID, evidence: [EvidenceHash], authorization: OperationsAuthorization, in namespace: PersistenceNamespace)
        async throws
    {
        let trusted = try await authorize(authorization, namespace: namespace)
        let (current, _) = try await exactWorkOrder(id: workOrderID, in: namespace)
        try validateCompletionEvidence(evidence, current: current)
        let material = try await completionTransitionMaterial(current: current, trusted: trusted, namespace: namespace)
        _ = try await commitTransition(
            workOrderID: workOrderID, namespace: namespace, trusted: trusted, phase: "complete", material: material
        ) { authoritative in
            guard authoritative == current else {
                throw ProductionFeatureMutationAuthorityError.invalidReservation
            }
            return try WorkOrderStateMachine.transition(
                authoritative,
                to: .completed,
                context: .init(actorID: trusted.actor.cloudKitUserRecordName, at: trusted.actorSnapshot.capturedAt)
            )
        }
    }

    public func requestCancellation(
        workOrderID: ObjectID, reason: String, physicalStatus: CancellationPhysicalStatus, authorization: OperationsAuthorization,
        in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation {
        let trusted = try await authorize(authorization, namespace: namespace)
        let (_, updated) = try await commitTransition(
            workOrderID: workOrderID,
            namespace: namespace,
            trusted: trusted,
            phase: "request-cancellation-\(digestString(reason))",
            material: .init()
        ) { current in
            guard [.reserved, .approved, .executing].contains(current.status) else {
                throw ProductionFeatureMutationAuthorityError.invalidCancellationRequestState
            }
            return try WorkOrderStateMachine.requestCancellation(
                current, reason: reason, by: trusted.actor.cloudKitUserRecordName, physicalStatus: physicalStatus, at: trusted.actorSnapshot.capturedAt
            )
        }
        guard updated.status == .cancellationRequested,
            updated.reservation?.ownerID == trusted.actor.cloudKitUserRecordName,
            updated.cancellationHistory.last?.id != nil
        else {
            throw ProductionFeatureMutationAuthorityError.cancellationNotRequested
        }
        let confirmation: WorkOrderReservationPresentation.Confirmation
        if let acknowledgement = updated.reservation?.acknowledgedByCloudKit {
            confirmation =
                trusted.actorSnapshot.capturedAt < acknowledgement.expiresAt
                ? .confirmed
                : .expired
        } else {
            confirmation = .pending
        }
        return presentation(for: updated, confirmation: confirmation)
    }

    public func resolveCancellation(
        workOrderID: ObjectID, reason: String, releaseAuthorization: CancellationReleaseAuthorization,
        authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws {
        let trusted = try await authorize(authorization, namespace: namespace)
        let (current, _) = try await exactWorkOrder(id: workOrderID, in: namespace)
        guard current.status == .cancellationRequested,
            current.cancellationHistory.last?.releaseAuthorization == nil
        else {
            throw ProductionFeatureMutationAuthorityError.cancellationNotRequested
        }
        try validateCancellationReleaseAuthorization(releaseAuthorization, workOrder: current, namespace: namespace, trusted: trusted)

        let lockTombstones = try ResourceReservationLockFactory.tombstones(for: current, deletedAt: trusted.actorSnapshot.capturedAt)
        var lockPreconditions: [ResourceKey: MutationPrecondition] = [:]
        for tombstone in lockTombstones {
            lockPreconditions[tombstone.resourceKey] = try await materializationPrecondition(for: tombstone.resourceKey, in: namespace)
        }

        _ = try await commitTransition(
            workOrderID: workOrderID,
            namespace: namespace,
            trusted: trusted,
            phase: "resolve-cancellation-\(digestString(reason))",
            material: .init(tombstones: lockTombstones, touchedPreconditions: lockPreconditions)
        ) { authoritative in
            guard authoritative == current,
                authoritative.status == .cancellationRequested,
                authoritative.cancellationHistory.last?.releaseAuthorization == nil
            else {
                throw ProductionFeatureMutationAuthorityError.cancellationNotRequested
            }
            return try WorkOrderStateMachine.resolveCancellation(
                authoritative, reason: reason, authorization: releaseAuthorization, at: trusted.actorSnapshot.capturedAt
            )
        }
    }

    public func createCorrectiveWorkOrder(
        for reconciliationID: ObjectID, authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> ObjectID {
        let trusted = try await authorize(authorization, namespace: namespace)
        let draft = try await correctiveBuilder.correctiveDraft(for: reconciliationID, actorID: trusted.actor.cloudKitUserRecordName, in: namespace)
        try requireStructurallyValid(draft)
        try await sessionAuthorizer.revalidate(trusted)
        await draftStore.store(draft, in: namespace)
        return draft.id
    }
}
