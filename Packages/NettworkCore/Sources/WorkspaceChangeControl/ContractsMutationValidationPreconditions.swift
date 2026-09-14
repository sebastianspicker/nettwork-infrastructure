import Foundation
import NetworkModel

extension AuthoritativeMutationValidator {
    static func collectMutationPreconditions(
        _ mutation: AuthoritativeMutation
    ) throws -> [ResourceKey: MutationPrecondition] {
        var preconditions = [ResourceKey: MutationPrecondition]()
        for precondition in mutation.preconditions {
            let key = precondition.resourceKey
            guard preconditions.updateValue(precondition, forKey: key) == nil else {
                throw AuthoritativeMutationValidationError.duplicatePrecondition(key)
            }
            if case let .exactSystemFields(_, exact) = precondition,
                exact.systemFields.isEmpty || exact.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw AuthoritativeMutationValidationError.invalidExactPrecondition(key)
            }
        }
        return preconditions
    }

    static func validateMutationPreconditions(
        _ preconditions: [ResourceKey: MutationPrecondition],
        mutation: AuthoritativeMutation, state: AuthoritativeMutationState,
        assertions: MutationReadAssertions, conditionalKeys: Set<ResourceKey>, workOrderKey: ResourceKey
    ) throws {
        try validatePreconditionKeys(preconditions, conditionalKeys: conditionalKeys)
        try validateReadAssertionPreconditions(mutation.readAssertions, preconditions: preconditions)
        try validatePreconditionState(preconditions, state: state, conditionalKeys: conditionalKeys)
        try validateWorkOrderPrecondition(preconditions, state: state, workOrderKey: workOrderKey)
        try validateGeneratedRecordPreconditions(preconditions, mutation: mutation)
    }

    static func validatePreconditionKeys(
        _ preconditions: [ResourceKey: MutationPrecondition],
        conditionalKeys: Set<ResourceKey>
    ) throws {
        if let key = MutationPreconditionValidationPolicy.mismatchedKey(
            preconditions: preconditions, conditionalKeys: conditionalKeys)
        {
            throw AuthoritativeMutationValidationError.missingPrecondition(key)
        }
    }

    static func validateReadAssertionPreconditions(
        _ assertions: [AuthoritativeReadAssertion],
        preconditions: [ResourceKey: MutationPrecondition]
    ) throws {
        if let key = MutationPreconditionValidationPolicy.firstReadAssertionMismatch(
            assertions, preconditions: preconditions)
        {
            throw AuthoritativeMutationValidationError.readAssertionPreconditionMismatch(key)
        }
    }

    static func validatePreconditionState(
        _ preconditions: [ResourceKey: MutationPrecondition],
        state: AuthoritativeMutationState, conditionalKeys: Set<ResourceKey>
    ) throws {
        for key in conditionalKeys {
            guard let precondition = preconditions[key] else {
                throw AuthoritativeMutationValidationError.missingPrecondition(key)
            }
            try validatePrecondition(precondition, key: key, state: state)
        }
    }

    static func validatePrecondition(
        _ precondition: MutationPrecondition, key: ResourceKey,
        state: AuthoritativeMutationState
    ) throws {
        switch precondition {
        case .mustNotExist:
            guard state.knownRecords[key] == nil else {
                throw AuthoritativeMutationValidationError.resourceAlreadyExists(key)
            }
        case .exactSystemFields(_, let expected):
            guard let actual = state.knownRecords[key] else {
                throw AuthoritativeMutationValidationError.missingRecord(key)
            }
            guard actual == expected else {
                throw AuthoritativeMutationValidationError.preconditionConflict(key)
            }
        }
    }

    static func validateWorkOrderPrecondition(
        _ preconditions: [ResourceKey: MutationPrecondition],
        state: AuthoritativeMutationState, workOrderKey: ResourceKey
    ) throws {
        guard let workOrderPrecondition = preconditions[workOrderKey] else {
            throw AuthoritativeMutationValidationError.invalidWorkOrderPrecondition
        }
        if state.currentWorkOrder == nil {
            guard case .mustNotExist = workOrderPrecondition else {
                throw AuthoritativeMutationValidationError.invalidWorkOrderPrecondition
            }
        } else {
            guard case .exactSystemFields = workOrderPrecondition else {
                throw AuthoritativeMutationValidationError.invalidWorkOrderPrecondition
            }
        }
    }

    static func validateGeneratedRecordPreconditions(
        _ preconditions: [ResourceKey: MutationPrecondition],
        mutation: AuthoritativeMutation
    ) throws {
        let auditEventKey = ResourceKey.object(mutation.auditEvent.id)
        let receiptKey = mutation.receipt.id
        guard let auditPrecondition = preconditions[auditEventKey],
            let receiptPrecondition = preconditions[receiptKey], case .mustNotExist = auditPrecondition,
            case .mustNotExist = receiptPrecondition
        else {
            throw AuthoritativeMutationValidationError.invalidReceipt
        }
    }

    static func validateAuditEvent(
        _ mutation: AuthoritativeMutation, context: MutationValidationContext,
        assertionKeys: Set<ResourceKey>
    ) throws {
        let auditEvent = mutation.auditEvent
        guard auditEvent.operationID == mutation.operationID,
            auditEvent.correlationID == mutation.operationID, auditEvent.actorID == mutation.actor.actorID,
            auditEvent.installationID == mutation.actor.installationID,
            auditEvent.sessionID == mutation.actor.sessionID,
            auditEvent.sessionGeneration == mutation.actor.sessionGeneration,
            auditEvent.workOrderID == mutation.workOrder.id, auditEvent.result == .accepted,
            Set(auditEvent.affectedResourceKeys).isSuperset(of: context.touched.union([context.workOrderKey])),
            Set(auditEvent.affectedResourceKeys).isDisjoint(with: assertionKeys),
            Set(auditEvent.changes.map(\.resourceKey)).isDisjoint(with: assertionKeys),
            Set(auditEvent.affectedObjectIDs).isDisjoint(with: assertedObjectIDs(assertionKeys))
        else {
            throw AuthoritativeMutationValidationError.invalidAuditEvent
        }
    }

    static func assertedObjectIDs(_ assertionKeys: Set<ResourceKey>) -> Set<ObjectID> {
        Set(
            assertionKeys.compactMap { key in
                guard case let .object(id) = key else { return nil }
                return id
            })
    }

    static func validateEvidenceAndReceipt(_ mutation: AuthoritativeMutation) throws {
        guard Set(mutation.evidenceHashes) == Set(mutation.workOrder.evidenceHashes) else {
            throw AuthoritativeMutationValidationError.evidenceMismatch
        }
        let expectedReceipt = OperationReceipt(
            workspaceZone: mutation.workspaceZone,
            operationID: mutation.operationID, intentDigest: mutation.intentDigest,
            auditEventID: mutation.auditEvent.id)
        guard mutation.receipt == expectedReceipt else {
            throw AuthoritativeMutationValidationError.invalidReceipt
        }
    }
}
