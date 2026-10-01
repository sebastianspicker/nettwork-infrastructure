import Foundation
import NetworkModel

extension AuthoritativeMutationValidator {
    static func validateMutationResources(
        _ mutation: AuthoritativeMutation
    ) throws -> MutationValidationContext {
        var touched = Set<ResourceKey>()
        try validateRecordSaves(mutation.saves, mutation: mutation, touched: &touched)
        try validateRecordTombstones(mutation.tombstones, mutation: mutation, touched: &touched)
        let workOrderKey = ResourceKey.object(mutation.workOrder.id)
        let auditEventKey = ResourceKey.object(mutation.auditEvent.id)
        let receiptKey = mutation.receipt.id
        let allTouched = touched.union([workOrderKey, auditEventKey, receiptKey])
        guard mutation.resourceKeys == allTouched else {
            guard let missing = allTouched.subtracting(mutation.resourceKeys).first ?? mutation.resourceKeys.subtracting(allTouched).first else {
                preconditionFailure("Unequal resource key sets must identify a key.")
            }
            throw AuthoritativeMutationValidationError.resourceKeyNotDeclared(missing)
        }
        return MutationValidationContext(
            touched: touched, allTouched: allTouched,
            workOrderKey: workOrderKey, auditEventKey: auditEventKey, receiptKey: receiptKey,
            workspaceSentinelKey: AuthoritativeActivationMutation.bootstrapSentinelResourceKey(
                for: mutation.workspaceZone.workspaceID))
    }

    static func validateRecordSaves(
        _ saves: [AuthoritativeRecordSave], mutation: AuthoritativeMutation,
        touched: inout Set<ResourceKey>
    ) throws {
        for save in saves {
            guard !save.recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                save.schemaVersion >= 1, !save.encodedRecord.isEmpty
            else {
                throw AuthoritativeMutationValidationError.invalidRecordSave(save.resourceKey)
            }
            try validateWritableResource(
                save.resourceKey, recordType: save.recordType,
                workspaceID: mutation.workspaceZone.workspaceID)
            guard touched.insert(save.resourceKey).inserted else {
                throw AuthoritativeMutationValidationError.duplicateTouchedResource(save.resourceKey)
            }
        }
    }

    static func validateRecordTombstones(
        _ tombstones: [AuthoritativeTombstone],
        mutation: AuthoritativeMutation, touched: inout Set<ResourceKey>
    ) throws {
        for tombstone in tombstones {
            guard !tombstone.recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !tombstone.encodedTombstone.isEmpty
            else {
                throw AuthoritativeMutationValidationError.invalidTombstone(tombstone.resourceKey)
            }
            try validateWritableResource(
                tombstone.resourceKey, recordType: tombstone.recordType,
                workspaceID: mutation.workspaceZone.workspaceID)
            guard touched.insert(tombstone.resourceKey).inserted else {
                throw AuthoritativeMutationValidationError.duplicateTouchedResource(tombstone.resourceKey)
            }
        }
    }

    static func validateWritableResource(
        _ key: ResourceKey, recordType: String, workspaceID: ObjectID
    ) throws {
        guard !isReservedActivationInfrastructure(key, recordType: recordType, workspaceID: workspaceID) else {
            throw AuthoritativeMutationValidationError.reservedActivationInfrastructure(key)
        }
    }

    static func validateReadAssertions(
        _ mutation: AuthoritativeMutation, context: MutationValidationContext
    ) throws -> MutationReadAssertions {
        var assertionKeys = Set<ResourceKey>()
        for assertion in mutation.readAssertions {
            try validateReadAssertionShape(assertion)
            try validateReadAssertionInfrastructure(assertion, mutation: mutation, context: context)
            guard assertionKeys.insert(assertion.resourceKey).inserted else {
                throw AuthoritativeMutationValidationError.duplicateReadAssertion(assertion.resourceKey)
            }
            guard !context.allTouched.contains(assertion.resourceKey) else {
                throw AuthoritativeMutationValidationError.readAssertionOverlapsMutation(assertion.resourceKey)
            }
        }
        guard assertionKeys.contains(context.workspaceSentinelKey) else {
            throw AuthoritativeMutationValidationError.missingPrecondition(context.workspaceSentinelKey)
        }
        return MutationReadAssertions(keys: assertionKeys)
    }

    static func validateReadAssertionShape(_ assertion: AuthoritativeReadAssertion) throws {
        guard !assertion.recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            assertion.schemaVersion >= 1, !assertion.encodedRecord.isEmpty,
            !assertion.precondition.systemFields.isEmpty,
            !assertion.precondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AuthoritativeMutationValidationError.invalidReadAssertion(assertion.resourceKey)
        }
    }

    static func validateReadAssertionInfrastructure(
        _ assertion: AuthoritativeReadAssertion,
        mutation: AuthoritativeMutation, context: MutationValidationContext
    ) throws {
        if assertion.resourceKey == context.workspaceSentinelKey {
            try validateWorkspaceSentinelAssertion(assertion, workspaceZone: mutation.workspaceZone)
        } else if isReservedActivationInfrastructure(
            assertion.resourceKey, recordType: assertion.recordType,
            workspaceID: mutation.workspaceZone.workspaceID)
        {
            throw AuthoritativeMutationValidationError.reservedActivationInfrastructure(assertion.resourceKey)
        }
    }

    static func validateWorkspaceSentinelAssertion(
        _ assertion: AuthoritativeReadAssertion,
        workspaceZone: AuthoritativeWorkspaceZone
    ) throws {
        guard assertion.recordType == AuthoritativeActivationMutation.workspaceSentinelRecordType,
            let workspace = try? CanonicalJSONCoding.decode(
                WorkspaceSentinelPayload.self,
                from: assertion.encodedRecord), workspace.matches(workspaceZone),
            case .active = workspace.lifecycle
        else {
            throw AuthoritativeMutationValidationError.invalidReadAssertion(assertion.resourceKey)
        }
    }

    static func isReservedActivationInfrastructure(
        _ key: ResourceKey, recordType: String,
        workspaceID: ObjectID
    ) -> Bool {
        key == AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: workspaceID)
            || AuthoritativeActivationMutation.isTransferInfrastructureResourceKey(key)
            || recordType == AuthoritativeActivationMutation.transferSessionRecordType
    }
}

struct MutationValidationContext {
    let touched: Set<ResourceKey>
    let allTouched: Set<ResourceKey>
    let workOrderKey: ResourceKey
    let auditEventKey: ResourceKey
    let receiptKey: ResourceKey
    let workspaceSentinelKey: ResourceKey
}

struct MutationReadAssertions {
    let keys: Set<ResourceKey>
}
