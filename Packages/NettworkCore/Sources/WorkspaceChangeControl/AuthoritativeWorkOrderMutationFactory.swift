import Foundation
import NetworkModel

public enum AuthoritativeWorkOrderMutationFactoryError: Error, Hashable, Sendable {
    case currentWorkOrderMismatch
    case invalidPolicyVersion
}

/// Constructs the complete atomic work-order/audit/receipt mutation from a
/// caller-validated desired state and an exact authoritative snapshot. It does
/// not grant authorization or manufacture CloudKit metadata.
public enum AuthoritativeWorkOrderMutationFactory {
    public static func make(
        operationID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone,
        actor: ActorInstallationSnapshot, currentWorkOrder: WorkOrder?, updatedWorkOrder: WorkOrder,
        state: AuthoritativeMutationState, saves: [AuthoritativeRecordSave] = [],
        tombstones: [AuthoritativeTombstone] = [], readAssertions: [AuthoritativeReadAssertion] = [],
        source: AuditSource = .interactive, policyVersion: String
    ) throws -> AuthoritativeMutation {
        try validate(currentWorkOrder: currentWorkOrder, updatedWorkOrder: updatedWorkOrder, state: state, policyVersion: policyVersion)
        let normalizedPolicy = policyVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let touched = Set(saves.map(\.resourceKey)).union(tombstones.map(\.resourceKey))
        let audit = makeAudit(
            operationID: operationID, actor: actor, workOrder: updatedWorkOrder, source: source, policyVersion: normalizedPolicy, touched: touched,
            saves: saves, tombstones: tombstones)
        let allKeys = touched.union([.object(updatedWorkOrder.id), .object(audit.id), ResourceKey.operationReceipt(operationID: operationID)])
        guard let intentDigest = updatedWorkOrder.intentDigest else {
            throw AuthoritativeMutationValidationError.missingWorkOrderIntentDigest
        }
        let mutation = try AuthoritativeMutation(
            workspaceZone: workspaceZone, operationID: operationID,
            intentDigest: intentDigest, actor: actor,
            workOrder: updatedWorkOrder, expectedWorkOrderRevision: currentWorkOrder?.revision ?? 0,
            resourceKeys: allKeys, saves: saves, tombstones: tombstones,
            preconditions: preconditions(for: allKeys, state: state, readAssertions: readAssertions),
            readAssertions: readAssertions, auditEvent: audit, evidenceHashes: updatedWorkOrder.evidenceHashes
        )
        try AuthoritativeMutationValidator.validate(mutation, against: state)
        return mutation
    }

    private static func validate(currentWorkOrder: WorkOrder?, updatedWorkOrder: WorkOrder, state: AuthoritativeMutationState, policyVersion: String) throws {
        guard state.currentWorkOrder == currentWorkOrder else {
            throw AuthoritativeWorkOrderMutationFactoryError.currentWorkOrderMismatch
        }
        let normalizedPolicy = policyVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPolicy.isEmpty else {
            throw AuthoritativeWorkOrderMutationFactoryError.invalidPolicyVersion
        }
        guard let intentDigest = updatedWorkOrder.intentDigest else {
            throw AuthoritativeMutationValidationError.missingWorkOrderIntentDigest
        }
        _ = intentDigest
    }

    private static func makeAudit(
        operationID: ObjectID, actor: ActorInstallationSnapshot, workOrder: WorkOrder,
        source: AuditSource, policyVersion: String, touched: Set<ResourceKey>,
        saves: [AuthoritativeRecordSave], tombstones: [AuthoritativeTombstone]
    ) -> AuditEvent {
        let changes =
            saves.map {
                AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedRecord)
            }
            + tombstones.map {
                AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedTombstone)
            }
        let affectedObjectIDs = touched.compactMap { key -> ObjectID? in
            guard case .object(let id) = key else { return nil }
            return id
        }.sorted()
        return AuditEvent(
            id: AuditEvent.deterministicID(for: operationID), operationID: operationID,
            actorID: actor.actorID, affectedObjectIDs: affectedObjectIDs, workOrderID: workOrder.id,
            occurredAt: actor.capturedAt, result: .accepted, installationID: actor.installationID,
            sessionID: actor.sessionID, sessionGeneration: actor.sessionGeneration, source: source,
            affectedResourceKeys: Array(touched.union([.object(workOrder.id)])).sorted(), changes: changes,
            ticket: workOrder.ticket, policyVersion: policyVersion)
    }

    private static func preconditions(for keys: Set<ResourceKey>, state: AuthoritativeMutationState, readAssertions: [AuthoritativeReadAssertion])
        -> [MutationPrecondition]
    {
        keys.sorted().map { key -> MutationPrecondition in
            if let exact = state.knownRecords[key] {
                return .exactSystemFields(key, exact)
            }
            return .mustNotExist(key)
        }
            + readAssertions.sorted { $0.resourceKey < $1.resourceKey }.map {
                .exactSystemFields($0.resourceKey, $0.precondition)
            }
    }
}
