import Foundation
import NetworkModel

public enum AuthoritativeActivationMutationValidator {
    public static func validate(
        _ mutation: AuthoritativeActivationMutation,
        against state: AuthoritativeActivationMutationState
    ) throws {
        try validateMutationMetadata(mutation)
        let context = try validationContext(for: mutation)
        let assertionKeys = try validateReadAssertions(mutation, state: state, context: context)
        let preconditions = try collectPreconditions(mutation)
        let conditionalKeys = context.touched
            .union([context.auditKey, context.receiptKey])
            .union(assertionKeys)
        try validatePreconditions(
            preconditions, for: mutation, state: state,
            conditionalKeys: conditionalKeys, sentinelKey: context.sentinelKey)
        let workOrderID = try validateActivationCapability(mutation, state: state)
        try validateAuditAndReceipt(mutation, touched: context.touched, requiredWorkOrderID: workOrderID)
    }
}
private extension AuthoritativeActivationMutationValidator {
    static func validateMutationMetadata(_ mutation: AuthoritativeActivationMutation) throws {
        guard !mutation.workspaceZone.containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !mutation.workspaceZone.zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !mutation.workspaceZone.zoneOwnerRecordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AuthoritativeActivationMutationValidationError.invalidScope
        }
        guard !mutation.actor.actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !mutation.actor.installationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !mutation.actor.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActorSnapshot
        }
        guard !mutation.encodedAuditEvent.isEmpty, !mutation.encodedReceipt.isEmpty,
            (try? CanonicalJSONCoding.decode(AuditEvent.self, from: mutation.encodedAuditEvent)) == mutation.auditEvent,
            (try? CanonicalJSONCoding.decode(OperationReceipt.self, from: mutation.encodedReceipt)) == mutation.receipt
        else {
            throw AuthoritativeActivationMutationValidationError.invalidImmutablePayload
        }
    }
    static func validationContext(for mutation: AuthoritativeActivationMutation) throws -> ActivationValidationContext {
        let sentinelKey = mutation.bootstrapSentinelResourceKey
        var touched = Set<ResourceKey>()
        try validateSaves(mutation.saves, sentinelKey: sentinelKey, touched: &touched)
        try validateTombstones(mutation.tombstones, touched: &touched)
        let auditKey = ResourceKey.object(mutation.auditEvent.id)
        let receiptKey = mutation.receipt.id
        try validateGeneratedKeys(auditKey, receiptKey, outside: touched)
        return ActivationValidationContext(
            sentinelKey: sentinelKey, auditKey: auditKey,
            receiptKey: receiptKey, touched: touched)
    }

    static func validateSaves(
        _ saves: [AuthoritativeRecordSave], sentinelKey: ResourceKey,
        touched: inout Set<ResourceKey>
    ) throws {
        var sentinelSaveCount = 0
        for save in saves {
            try validate(save, addingTo: &touched)
            if save.resourceKey == sentinelKey { sentinelSaveCount += 1 }
        }
        guard sentinelSaveCount == 1 else {
            throw AuthoritativeActivationMutationValidationError.missingBootstrapSentinel(sentinelKey)
        }
    }

    private static func validate(_ save: AuthoritativeRecordSave, addingTo touched: inout Set<ResourceKey>) throws {
        guard !save.recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, save.schemaVersion >= 1, !save.encodedRecord.isEmpty,
            save.recordAsset == nil || isValidRecordBoundAsset(save)
        else { throw AuthoritativeActivationMutationValidationError.invalidRecordSave(save.resourceKey) }
        guard touched.insert(save.resourceKey).inserted else {
            throw AuthoritativeActivationMutationValidationError.duplicateTouchedResource(save.resourceKey)
        }
        guard !AuthoritativeActivationMutation.isTransferInfrastructureResourceKey(save.resourceKey),
            save.recordType != AuthoritativeActivationMutation.transferSessionRecordType
        else { throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(save.resourceKey) }
    }

    static func validateTombstones(
        _ tombstones: [AuthoritativeTombstone], touched: inout Set<ResourceKey>
    ) throws {
        for tombstone in tombstones {
            guard !tombstone.recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !tombstone.encodedTombstone.isEmpty
            else {
                throw AuthoritativeActivationMutationValidationError.invalidTombstone(tombstone.resourceKey)
            }
            guard touched.insert(tombstone.resourceKey).inserted else {
                throw AuthoritativeActivationMutationValidationError.duplicateTouchedResource(tombstone.resourceKey)
            }
            if AuthoritativeActivationMutation.isTransferInfrastructureResourceKey(tombstone.resourceKey)
                || tombstone.recordType == AuthoritativeActivationMutation.transferSessionRecordType
            {
                throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(tombstone.resourceKey)
            }
        }
    }

    static func validateGeneratedKeys(
        _ auditKey: ResourceKey, _ receiptKey: ResourceKey,
        outside touched: Set<ResourceKey>
    ) throws {
        guard !touched.contains(auditKey), !touched.contains(receiptKey), auditKey != receiptKey else {
            throw AuthoritativeActivationMutationValidationError.duplicateTouchedResource(
                touched.contains(auditKey) ? auditKey : receiptKey)
        }
    }

    static func validateReadAssertions(
        _ mutation: AuthoritativeActivationMutation,
        state: AuthoritativeActivationMutationState, context: ActivationValidationContext
    ) throws -> Set<ResourceKey> {
        var assertionKeys = Set<ResourceKey>()
        for assertion in mutation.readAssertions {
            try validateReadAssertion(assertion)
            guard assertionKeys.insert(assertion.resourceKey).inserted else {
                throw AuthoritativeActivationMutationValidationError.duplicateReadAssertion(assertion.resourceKey)
            }
            guard !context.touched.contains(assertion.resourceKey), assertion.resourceKey != context.auditKey,
                assertion.resourceKey != context.receiptKey
            else {
                throw AuthoritativeActivationMutationValidationError.readAssertionOverlapsMutation(assertion.resourceKey)
            }
            try validateCurrentReadAssertion(assertion, state: state)
        }
        return assertionKeys
    }

    static func validateReadAssertion(_ assertion: AuthoritativeReadAssertion) throws {
        guard !assertion.recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            assertion.schemaVersion >= 1, !assertion.encodedRecord.isEmpty,
            !assertion.precondition.systemFields.isEmpty,
            !assertion.precondition.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AuthoritativeActivationMutationValidationError.invalidReadAssertion(assertion.resourceKey)
        }
    }

    static func validateCurrentReadAssertion(
        _ assertion: AuthoritativeReadAssertion,
        state: AuthoritativeActivationMutationState
    ) throws {
        guard let current = state.currentRecords[assertion.resourceKey],
            current.recordType == assertion.recordType, current.schemaVersion == assertion.schemaVersion,
            current.encodedRecord == assertion.encodedRecord,
            current.precondition == assertion.precondition
        else {
            throw AuthoritativeActivationMutationValidationError.invalidReadAssertion(assertion.resourceKey)
        }
    }

    static func collectPreconditions(
        _ mutation: AuthoritativeActivationMutation
    ) throws -> [ResourceKey: MutationPrecondition] {
        var preconditions = [ResourceKey: MutationPrecondition]()
        for precondition in mutation.preconditions {
            let key = precondition.resourceKey
            guard preconditions.updateValue(precondition, forKey: key) == nil else {
                throw AuthoritativeActivationMutationValidationError.duplicatePrecondition(key)
            }
            if case let .exactSystemFields(_, exact) = precondition,
                exact.systemFields.isEmpty || exact.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw AuthoritativeActivationMutationValidationError.invalidExactPrecondition(key)
            }
        }
        return preconditions
    }

    static func validatePreconditions(
        _ preconditions: [ResourceKey: MutationPrecondition],
        for mutation: AuthoritativeActivationMutation, state: AuthoritativeActivationMutationState,
        conditionalKeys: Set<ResourceKey>, sentinelKey: ResourceKey
    ) throws {
        try validateConditionalPreconditionKeys(preconditions, conditionalKeys: conditionalKeys)
        try validateSentinelPrecondition(preconditions, sentinelKey: sentinelKey)
        try validateReadAssertionPreconditions(mutation.readAssertions, preconditions: preconditions)
        try validatePreconditionState(preconditions, state: state, conditionalKeys: conditionalKeys)
    }

    static func validateConditionalPreconditionKeys(
        _ preconditions: [ResourceKey: MutationPrecondition],
        conditionalKeys: Set<ResourceKey>
    ) throws {
        if let key = MutationPreconditionValidationPolicy.mismatchedKey(
            preconditions: preconditions, conditionalKeys: conditionalKeys)
        {
            throw AuthoritativeActivationMutationValidationError.missingPrecondition(key)
        }
    }

    static func validateSentinelPrecondition(
        _ preconditions: [ResourceKey: MutationPrecondition],
        sentinelKey: ResourceKey
    ) throws {
        guard let sentinelPrecondition = preconditions[sentinelKey],
            case .exactSystemFields = sentinelPrecondition
        else {
            throw AuthoritativeActivationMutationValidationError.invalidBootstrapSentinelPrecondition(sentinelKey)
        }
    }

    static func validateReadAssertionPreconditions(
        _ assertions: [AuthoritativeReadAssertion],
        preconditions: [ResourceKey: MutationPrecondition]
    ) throws {
        if let key = MutationPreconditionValidationPolicy.firstReadAssertionMismatch(
            assertions, preconditions: preconditions)
        {
            throw AuthoritativeActivationMutationValidationError.readAssertionPreconditionMismatch(key)
        }
    }

    static func validatePreconditionState(
        _ preconditions: [ResourceKey: MutationPrecondition],
        state: AuthoritativeActivationMutationState, conditionalKeys: Set<ResourceKey>
    ) throws {
        for key in conditionalKeys {
            guard let precondition = preconditions[key] else {
                throw AuthoritativeActivationMutationValidationError.missingPrecondition(key)
            }
            try validate(precondition, for: key, state: state)
        }
    }

    static func validate(
        _ precondition: MutationPrecondition, for key: ResourceKey,
        state: AuthoritativeActivationMutationState
    ) throws {
        switch precondition {
        case .mustNotExist:
            guard state.knownRecords[key] == nil else {
                throw AuthoritativeActivationMutationValidationError.resourceAlreadyExists(key)
            }
        case .exactSystemFields(_, let expected):
            guard let actual = state.knownRecords[key] else {
                throw AuthoritativeActivationMutationValidationError.missingRecord(key)
            }
            guard actual == expected else {
                throw AuthoritativeActivationMutationValidationError.preconditionConflict(key)
            }
        }
    }

    static func validateAuditAndReceipt(
        _ mutation: AuthoritativeActivationMutation,
        touched: Set<ResourceKey>, requiredWorkOrderID: ObjectID?
    ) throws {
        let auditKey = ResourceKey.object(mutation.auditEvent.id)
        let receiptKey = mutation.receipt.id
        try validateGeneratedRecordPreconditions(mutation, auditKey: auditKey, receiptKey: receiptKey)
        let expectedChanges = expectedAuditChanges(for: mutation)
        let expectedObjectIDs = expectedAffectedObjectIDs(in: touched)
        try validateAuditEvent(
            mutation, touched: touched, expectedChanges: expectedChanges,
            expectedObjectIDs: expectedObjectIDs, requiredWorkOrderID: requiredWorkOrderID)
        try validateReceipt(mutation)
    }

    static func validateGeneratedRecordPreconditions(
        _ mutation: AuthoritativeActivationMutation,
        auditKey: ResourceKey, receiptKey: ResourceKey
    ) throws {
        let preconditions = Dictionary(uniqueKeysWithValues: mutation.preconditions.map { ($0.resourceKey, $0) })
        guard let auditPrecondition = preconditions[auditKey],
            let receiptPrecondition = preconditions[receiptKey], case .mustNotExist = auditPrecondition,
            case .mustNotExist = receiptPrecondition
        else {
            throw AuthoritativeActivationMutationValidationError.invalidReceipt
        }
    }

    static func expectedAuditChanges(for mutation: AuthoritativeActivationMutation) -> [AuditRecordChange] {
        (mutation.saves.map { AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedRecord) }
            + mutation.tombstones.map { AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedTombstone) })
            .sorted { $0.resourceKey < $1.resourceKey }
    }

    static func expectedAffectedObjectIDs(in touched: Set<ResourceKey>) -> [ObjectID] {
        touched.compactMap { key -> ObjectID? in
            guard case let .object(id) = key else { return nil }
            return id
        }.sorted()
    }

    static func validateAuditEvent(
        _ mutation: AuthoritativeActivationMutation, touched: Set<ResourceKey>,
        expectedChanges: [AuditRecordChange], expectedObjectIDs: [ObjectID], requiredWorkOrderID: ObjectID?
    ) throws {
        let auditEvent = mutation.auditEvent
        guard auditEvent.id == AuditEvent.deterministicID(for: mutation.operationID),
            auditEvent.operationID == mutation.operationID,
            auditEvent.correlationID == mutation.operationID, auditEvent.actorID == mutation.actor.actorID,
            auditEvent.installationID == mutation.actor.installationID,
            auditEvent.sessionID == mutation.actor.sessionID,
            auditEvent.sessionGeneration == mutation.actor.sessionGeneration,
            auditEvent.workOrderID == requiredWorkOrderID,
            auditEvent.occurredAt == mutation.actor.capturedAt, auditEvent.serverOccurredAt == nil,
            auditEvent.result == .accepted, auditEvent.errorClassification == nil,
            auditEvent.affectedResourceKeys == touched.sorted(),
            auditEvent.affectedObjectIDs == expectedObjectIDs, auditEvent.changes == expectedChanges
        else {
            throw AuthoritativeActivationMutationValidationError.invalidAuditEvent
        }
    }

    static func validateReceipt(_ mutation: AuthoritativeActivationMutation) throws {
        let expectedReceipt = OperationReceipt(
            workspaceZone: mutation.workspaceZone,
            operationID: mutation.operationID, intentDigest: mutation.intentDigest,
            auditEventID: mutation.auditEvent.id)
        guard mutation.receipt == expectedReceipt else {
            throw AuthoritativeActivationMutationValidationError.invalidReceipt
        }
    }

    static func isValidRecordBoundAsset(_ save: AuthoritativeRecordSave) -> Bool {
        guard let asset = save.recordAsset, let bytes = try? asset.validatedBytes() else { return false }
        switch save.recordType {
        case WorkspaceRecordType.attachmentEvidenceBinding:
            return isValidAttachmentEvidenceAsset(save, asset: asset, bytes: bytes)
        case AuthoritativeActivationMutation.floorPlanAssetBindingRecordType:
            return isValidFloorPlanAsset(save, asset: asset)
        default: return false
        }
    }

    static func isValidAttachmentEvidenceAsset(
        _ save: AuthoritativeRecordSave,
        asset: CloudRecordAssetDescriptor, bytes: Data
    ) -> Bool {
        guard let binding = try? CanonicalJSONCoding.decode(AttachmentEvidenceBindingRecord.self, from: save.encodedRecord),
            (try? AttachmentEvidenceBindingRecord(
                workOrderID: binding.workOrderID, attachmentID: binding.attachmentID,
                reservationID: binding.reservationID, provenance: binding.provenance, evidence: binding.evidence,
                assetMetadata: binding.assetMetadata, intentDigest: binding.intentDigest, operationID: binding.operationID,
                auditEventID: binding.auditEventID, boundAt: binding.boundAt)) != nil,
            binding.resourceKey == save.resourceKey, binding.assetMetadata == asset.metadata,
            AttachmentEvidenceBindingRecord.evidenceDigest(for: bytes) == binding.provenance.domainSeparatedSHA256
        else {
            return false
        }
        return true
    }

    static func isValidFloorPlanAsset(_ save: AuthoritativeRecordSave, asset: CloudRecordAssetDescriptor) -> Bool {
        guard let binding = try? CanonicalJSONCoding.decode(FloorPlanAssetBindingRecord.self, from: save.encodedRecord),
            (try? FloorPlanAssetBindingRecord(
                floorID: binding.floorID, workOrderID: binding.workOrderID, assetMetadata: binding.assetMetadata,
                intentDigest: binding.intentDigest, operationID: binding.operationID, auditEventID: binding.auditEventID,
                boundAt: binding.boundAt)) != nil, binding.resourceKey == save.resourceKey,
            binding.assetMetadata == asset.metadata
        else {
            return false
        }
        return true
    }
}

private struct ActivationValidationContext {
    let sentinelKey: ResourceKey
    let auditKey: ResourceKey
    let receiptKey: ResourceKey
    let touched: Set<ResourceKey>
}
