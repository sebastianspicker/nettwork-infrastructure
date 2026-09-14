import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum CloudReservationAcknowledgementError: Error, Hashable, Sendable {
    case invalidAccountScope
    case invalidActor
    case missingReservation
    case alreadyAcknowledged
    case recordMismatch
    case intentMismatch
    case invalidAcknowledgementWindow
}

/// Converts a server-returned reserved work-order record into the exact
/// acknowledgement required for later offline execution. This does not create
/// the reservation or write the acknowledgement back to the work order.
public enum CloudReservationAcknowledgementVerifier {
    public static func verify(
        reservedWorkOrder: WorkOrder, serverRecord: CloudExactRecordSnapshot,
        account: AccountContext, actor: ActorContext, expiresAt: Date, observedAt: Date = .now
    ) throws -> CloudKitAcknowledgement {
        try OfficialClientPolicy.authorizeMutation(actor: actor, account: account)
        let reservation = try validateReservation(reservedWorkOrder, serverRecord: serverRecord, account: account, actor: actor)
        let canonicalIntent = CanonicalWorkIntent(
            intentSchemaVersion: reservedWorkOrder.intentSchemaVersion ?? 1,
            workOrderID: reservedWorkOrder.id, kind: reservedWorkOrder.kind,
            creatorID: reservedWorkOrder.creatorID, ticket: reservedWorkOrder.ticket,
            notes: reservedWorkOrder.notes, operations: reservedWorkOrder.plannedOperations,
            resourceKeys: reservation.resourceKeys, evidenceHashes: reservedWorkOrder.evidenceHashes)
        guard let intentDigest = reservedWorkOrder.intentDigest, (try? canonicalIntent.digest()) == intentDigest else {
            throw CloudReservationAcknowledgementError.intentMismatch
        }
        guard serverRecord.serverModifiedAt <= observedAt, observedAt < expiresAt else {
            throw CloudReservationAcknowledgementError.invalidAcknowledgementWindow
        }
        return CloudKitAcknowledgement(
            workspaceZone: account.namespace.workspaceZone,
            cloudKitAccountRecordName: account.namespace.cloudKitAccountRecordName,
            sessionGeneration: account.namespace.sessionGeneration, reservationID: reservation.id,
            workOrderID: reservedWorkOrder.id, ownerID: reservation.ownerID,
            resourceKeys: reservation.resourceKeys, intentDigest: intentDigest,
            systemFields: serverRecord.exactPrecondition.systemFields,
            changeTag: serverRecord.exactPrecondition.changeTag,
            acknowledgedAt: serverRecord.serverModifiedAt, expiresAt: expiresAt)
    }

    private static func validateReservation(_ workOrder: WorkOrder, serverRecord: CloudExactRecordSnapshot, account: AccountContext, actor: ActorContext) throws
        -> WorkOrderReservation
    {
        guard serverRecord.workspaceZone == account.namespace.workspaceZone else { throw CloudReservationAcknowledgementError.invalidAccountScope }
        guard actor.cloudKitUserRecordName == account.namespace.cloudKitAccountRecordName, actor.sessionGeneration == account.namespace.sessionGeneration else {
            throw CloudReservationAcknowledgementError.invalidActor
        }
        guard workOrder.status == .reserved, let reservation = workOrder.reservation else { throw CloudReservationAcknowledgementError.missingReservation }
        guard reservation.acknowledgedByCloudKit == nil else { throw CloudReservationAcknowledgementError.alreadyAcknowledged }
        guard reservation.ownerID == actor.cloudKitUserRecordName else { throw CloudReservationAcknowledgementError.invalidActor }
        guard serverRecord.resourceKey == .object(workOrder.id), serverRecord.recordType == CloudRecordNaming.workOrderRecordType,
            serverRecord.schemaVersion == CloudRecordNaming.schemaVersion
        else { throw CloudReservationAcknowledgementError.recordMismatch }
        guard !serverRecord.exactPrecondition.systemFields.isEmpty,
            !serverRecord.exactPrecondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (try? CloudDeterministicCoding.decode(
                WorkOrder.self,
                from: serverRecord.payload)) == workOrder
        else { throw CloudReservationAcknowledgementError.recordMismatch }
        return reservation
    }
}
