import Foundation
import NetworkModel

extension AuthoritativeActivationMutationValidator {
    static func validateActivationCapability(
        _ mutation: AuthoritativeActivationMutation,
        state: AuthoritativeActivationMutationState
    ) throws -> ObjectID? {
        let sentinel = try activationSentinel(for: mutation, state: state)
        let sessionAssertions = transferSessionAssertions(in: mutation)
        if sessionAssertions.isEmpty {
            return try validateLocalActivation(mutation, state: state, sentinel: sentinel)
        }
        return try validateTransferActivation(
            mutation, sentinel: sentinel,
            sessionAssertions: sessionAssertions)
    }

    static func activationSentinel(
        for mutation: AuthoritativeActivationMutation,
        state: AuthoritativeActivationMutationState
    ) throws -> ActivationSentinel {
        let sentinelKey = mutation.bootstrapSentinelResourceKey
        guard let sentinelSave = mutation.saves.first(where: { $0.resourceKey == sentinelKey }),
            sentinelSave.recordType == AuthoritativeActivationMutation.workspaceSentinelRecordType,
            sentinelSave.schemaVersion == 1, let current = state.currentSentinel,
            current.recordType == AuthoritativeActivationMutation.workspaceSentinelRecordType,
            current.schemaVersion == 1,
            let currentWorkspace = try? StableActivationPayloadCoding.decode(WorkspaceSentinelPayload.self, from: current.encodedRecord),
            let proposedWorkspace = try? StableActivationPayloadCoding.decode(WorkspaceSentinelPayload.self, from: sentinelSave.encodedRecord),
            currentWorkspace.matches(mutation.workspaceZone),
            proposedWorkspace.matches(mutation.workspaceZone)
        else {
            throw AuthoritativeActivationMutationValidationError.invalidCurrentBootstrapSentinel(sentinelKey)
        }
        return ActivationSentinel(
            key: sentinelKey, save: sentinelSave, current: current,
            currentWorkspace: currentWorkspace, proposedWorkspace: proposedWorkspace)
    }

    static func transferSessionAssertions(
        in mutation: AuthoritativeActivationMutation
    ) -> [AuthoritativeReadAssertion] {
        mutation.readAssertions.filter {
            $0.recordType == AuthoritativeActivationMutation.transferSessionRecordType
                || AuthoritativeActivationMutation.isTransferInfrastructureResourceKey($0.resourceKey)
        }
    }

    static func validateLocalActivation(
        _ mutation: AuthoritativeActivationMutation,
        state: AuthoritativeActivationMutationState, sentinel: ActivationSentinel
    ) throws -> ObjectID? {
        guard mutation.tombstones.isEmpty, sentinel.save.encodedRecord == sentinel.current.encodedRecord,
            case .active = sentinel.currentWorkspace.lifecycle,
            case .active = sentinel.proposedWorkspace.lifecycle
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(sentinel.key)
        }
        let floorPlanBindingSaves = mutation.saves.filter {
            $0.recordType == AuthoritativeActivationMutation.floorPlanAssetBindingRecordType
        }
        if !floorPlanBindingSaves.isEmpty {
            return try validateFloorPlanAssetActivation(mutation, bindingSaves: floorPlanBindingSaves)
        }
        let bindingSaves = mutation.saves.filter {
            $0.recordType == "NettworkAttachmentEvidenceBinding"
        }
        guard let bindingSave = bindingSaves.first else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(sentinel.key)
        }
        return try validateAttachmentEvidenceActivation(
            mutation, state: state, sentinelSave: sentinel.save,
            bindingSave: bindingSave)
    }

    static func validateFloorPlanAssetActivation(
        _ mutation: AuthoritativeActivationMutation,
        bindingSaves: [AuthoritativeRecordSave]
    ) throws -> ObjectID {
        let invalidKey = bindingSaves.first?.resourceKey ?? mutation.bootstrapSentinelResourceKey
        guard bindingSaves.count == 1, mutation.saves.count == 2, mutation.readAssertions.count == 1,
            let bindingSave = bindingSaves.first,
            let binding = try? StableActivationPayloadCoding.decode(FloorPlanAssetBindingRecord.self, from: bindingSave.encodedRecord),
            let asset = bindingSave.recordAsset, binding.resourceKey == bindingSave.resourceKey,
            binding.assetMetadata == asset.metadata, binding.intentDigest == mutation.intentDigest,
            binding.operationID == mutation.operationID, binding.auditEventID == mutation.auditEvent.id,
            let workOrderAssertion = mutation.readAssertions.first,
            workOrderAssertion.resourceKey == .object(binding.workOrderID),
            workOrderAssertion.recordType == "NettworkWorkOrder", workOrderAssertion.schemaVersion == 1,
            let workOrder = try? StableActivationPayloadCoding.decode(WorkOrder.self, from: workOrderAssertion.encodedRecord),
            workOrder.id == binding.workOrderID, workOrder.kind == .floorPlan,
            workOrder.status == .completed, workOrder.intentDigest == binding.intentDigest
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(invalidKey)
        }
        guard
            workOrder.plannedOperations.contains(where: { operation in
                guard case let .floorPlan(.bindAsset(planned)) = operation else { return false }
                return planned.floorID == binding.floorID && planned.assetMetadata == binding.assetMetadata
            })
        else {
            throw AuthoritativeActivationMutationValidationError.invalidActivationRecordSet(invalidKey)
        }
        return binding.workOrderID
    }

    static func validateTransferActivation(
        _ mutation: AuthoritativeActivationMutation,
        sentinel: ActivationSentinel, sessionAssertions: [AuthoritativeReadAssertion]
    ) throws -> ObjectID? {
        guard mutation.readAssertions.count == 1, let assertion = sessionAssertions.first,
            assertion.recordType == AuthoritativeActivationMutation.transferSessionRecordType,
            assertion.schemaVersion == 1,
            let session = try? StableActivationPayloadCoding.decode(TransferSessionAssertionPayload.self, from: assertion.encodedRecord),
            assertion.resourceKey == .string("workspace-transfer-session:\(session.transferID.description)"),
            session.isComplete, mutation.saves.count == 1, mutation.tombstones.isEmpty,
            case .empty = sentinel.currentWorkspace.lifecycle,
            case let .active(commit) = sentinel.proposedWorkspace.lifecycle,
            commit.transferID == session.transferID, commit.memberCount == session.cursor,
            commit.rollingDigest == session.rollingDigest
        else {
            throw AuthoritativeActivationMutationValidationError.invalidTransferSessionAssertion(
                sessionAssertions.first?.resourceKey ?? sentinel.key)
        }
        return nil
    }
}

struct ActivationSentinel {
    let key: ResourceKey
    let save: AuthoritativeRecordSave
    let current: AuthoritativeActivationSentinelSnapshot
    let currentWorkspace: WorkspaceSentinelPayload
    let proposedWorkspace: WorkspaceSentinelPayload
}
