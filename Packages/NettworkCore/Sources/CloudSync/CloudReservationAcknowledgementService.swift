import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum CloudReservationAcknowledgementServiceError: Error, Hashable, Sendable {
    case actorSnapshotMismatch
    case reservationRecordMissing
    case workspaceInactive
}

public struct CloudReservationAcknowledgementResult: Hashable, Sendable {
    public let workOrder: WorkOrder
    public let receipt: OperationReceipt

    public init(workOrder: WorkOrder, receipt: OperationReceipt) {
        self.workOrder = workOrder
        self.receipt = receipt
    }
}

/// Completes the second phase of an online reservation. Phase one atomically
/// writes the reserved work order and one exclusion lock per resource. After
/// CloudKit returns exact metadata for that record, this service verifies it
/// and conditionally binds the acknowledgement in a separate audited revision.
public actor CloudReservationAcknowledgementService {
    private let exactRecords: any CloudExactRecordReading
    private let mutations: any AuthoritativeMutationRepository

    public init(exactRecords: any CloudExactRecordReading, mutations: any AuthoritativeMutationRepository) {
        self.exactRecords = exactRecords
        self.mutations = mutations
    }

    public func acknowledge(
        reservedWorkOrder: WorkOrder, account: AccountContext, actor: ActorContext,
        actorSnapshot: ActorInstallationSnapshot, operationID: ObjectID, expiresAt: Date,
        policyVersion: String
    ) async throws -> CloudReservationAcknowledgementResult {
        guard actorSnapshot.actorID == actor.cloudKitUserRecordName,
            actorSnapshot.installationID == actor.installationID,
            actorSnapshot.sessionGeneration == actor.sessionGeneration
        else {
            throw CloudReservationAcknowledgementServiceError.actorSnapshotMismatch
        }
        let key = ResourceKey.object(reservedWorkOrder.id)
        guard let serverRecord = try await exactRecords.exactRecord(for: key, in: account.namespace.workspaceZone) else {
            throw CloudReservationAcknowledgementServiceError.reservationRecordMissing
        }
        let acknowledgement = try CloudReservationAcknowledgementVerifier.verify(
            reservedWorkOrder: reservedWorkOrder, serverRecord: serverRecord, account: account, actor: actor, expiresAt: expiresAt,
            observedAt: actorSnapshot.capturedAt)
        let updated = try WorkOrderStateMachine.acknowledgeReservation(
            reservedWorkOrder,
            acknowledgement: acknowledgement, observedAt: actorSnapshot.capturedAt)
        let workspaceAssertion = try await activeWorkspaceAssertion(for: account)
        let sentinelKey = workspaceAssertion.resourceKey
        let state = AuthoritativeMutationState(
            knownRecords: [key: serverRecord.exactPrecondition, sentinelKey: workspaceAssertion.precondition], currentWorkOrder: reservedWorkOrder)
        let mutation = try AuthoritativeWorkOrderMutationFactory.make(
            operationID: operationID,
            workspaceZone: account.namespace.workspaceZone, actor: actorSnapshot,
            currentWorkOrder: reservedWorkOrder, updatedWorkOrder: updated, state: state,
            readAssertions: [workspaceAssertion], source: .interactive, policyVersion: policyVersion)
        let receipt = try await mutations.commit(mutation)
        guard receipt == mutation.receipt else {
            throw CloudAuthoritativeCommitError.returnedReceiptMismatch
        }
        return CloudReservationAcknowledgementResult(workOrder: updated, receipt: receipt)
    }

    private func activeWorkspaceAssertion(for account: AccountContext) async throws -> AuthoritativeReadAssertion {
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(
            for: account.namespace.workspaceID)
        guard let sentinel = try await exactRecords.exactRecord(for: sentinelKey, in: account.namespace.workspaceZone),
            sentinel.workspaceZone == account.namespace.workspaceZone,
            sentinel.resourceKey == sentinelKey, sentinel.recordType == CloudRecordNaming.workspaceRecordType,
            sentinel.schemaVersion == CloudRecordNaming.schemaVersion,
            let workspace = try? CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: sentinel.payload),
            (try? CloudDeterministicCoding.encode(workspace)) == sentinel.payload,
            workspace.workspaceID == account.namespace.workspaceID,
            workspace.zoneName == account.namespace.zoneName,
            workspace.zoneOwnerRecordName == account.namespace.zoneOwnerRecordName,
            case .active = workspace.lifecycle
        else {
            throw CloudReservationAcknowledgementServiceError.workspaceInactive
        }
        return AuthoritativeReadAssertion(
            resourceKey: sentinelKey, recordType: sentinel.recordType, schemaVersion: sentinel.schemaVersion, encodedRecord: sentinel.payload,
            precondition: sentinel.exactPrecondition)
    }
}
