import CloudSync
import ContentSafety
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

struct PreparedFloorPlanAssetMutation {
    let mutation: AuthoritativeActivationMutation
    let receipt: OperationReceipt
}

private struct FloorPlanWorkOrderBindingState {
    let snapshot: CloudExactRecordSnapshot
    let workOrder: WorkOrder
    let metadata: CloudRecordAssetMetadata
    let intentDigest: IntentDigest
}

extension ProductionFloorPlanAssetAtomicBinding {
    func validateFloorPlanRequest(_ request: FloorPlanAssetBindingRequest, account: AccountContext, authorization: AuthorizedOperationContext) throws {
        let descriptor = request.descriptor
        guard authorization.action == .createAttachment,
            authorization.account == account,
            descriptor.namespace == AttachmentNamespace(account: account),
            descriptor.purpose == .floorPlan,
            descriptor.contentType == .jpeg,
            descriptor.id == request.descriptor.id,
            descriptor.byteCount > 0
        else {
            throw ProductionFloorPlanAssetAuthorityError.invalidDescriptor
        }
    }

    func prepareFloorPlanMutation(
        _ request: FloorPlanAssetBindingRequest, account: AccountContext, authorization: AuthorizedOperationContext,
        trusted: TrustedProductionSession, claim: ClaimedStagedAttachment
    ) async throws -> PreparedFloorPlanAssetMutation {
        try validateClaim(claim, descriptor: request.descriptor)
        let namespace = account.namespace
        let workOrderState = try await loadFloorPlanWorkOrder(request, namespace: namespace)
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        let sentinel = try await requiredExactRecord(sentinelKey, recordType: CloudRecordNaming.workspaceRecordType, namespace: namespace)
        let bindingKey = ResourceKey.floorPlanAssetBinding(for: request.floorID)
        let currentBinding = try await loadCurrentBinding(bindingKey, namespace: namespace)
        return try buildFloorPlanMutation(
            request, authorization: authorization, trusted: trusted, claim: claim, workOrder: workOrderState,
            sentinel: sentinel, currentBinding: currentBinding, namespace: namespace)
    }

    private func validateClaim(_ claim: ClaimedStagedAttachment, descriptor: SanitizedContentDescriptor) throws {
        guard claim.attachmentID == descriptor.id,
            claim.token == descriptor.stagingToken,
            claim.namespace == descriptor.namespace,
            claim.expiresAt == descriptor.stagingExpiresAt,
            claim.metadata.purpose == descriptor.purpose,
            claim.metadata.contentType == descriptor.contentType,
            claim.metadata.byteCount == descriptor.byteCount,
            claim.metadata.contentSHA256 == descriptor.contentSHA256,
            claim.metadata.domainSeparatedSHA256 == descriptor.domainSeparatedSHA256,
            claim.sanitizedBytes.count == descriptor.byteCount,
            CloudRecordAssetDescriptor.sha256(for: claim.sanitizedBytes) == descriptor.contentSHA256,
            ContentSafetyService.digest(for: claim.sanitizedBytes, purpose: .floorPlan) == descriptor.domainSeparatedSHA256
        else {
            throw ProductionFloorPlanAssetAuthorityError.invalidDescriptor
        }
    }

    private func loadFloorPlanWorkOrder(
        _ request: FloorPlanAssetBindingRequest, namespace: PersistenceNamespace
    ) async throws -> FloorPlanWorkOrderBindingState {
        let snapshot = try await requiredExactRecord(.object(request.workOrderID), recordType: CloudRecordNaming.workOrderRecordType, namespace: namespace)
        let workOrder = try CloudDeterministicCoding.decode(WorkOrder.self, from: snapshot.payload)
        let descriptor = request.descriptor
        let metadata = try CloudRecordAssetMetadata(
            id: descriptor.id, fieldName: "floorPlanAsset", sha256: descriptor.contentSHA256,
            contentType: descriptor.contentType.rawValue, byteCount: descriptor.byteCount)
        guard workOrder.id == request.workOrderID,
            workOrder.kind == .floorPlan,
            workOrder.status == .completed,
            let intentDigest = workOrder.intentDigest,
            hasMatchingFloorPlanOperation(workOrder, floorID: request.floorID, metadata: metadata)
        else {
            throw ProductionFloorPlanAssetAuthorityError.invalidWorkOrder
        }
        return FloorPlanWorkOrderBindingState(snapshot: snapshot, workOrder: workOrder, metadata: metadata, intentDigest: intentDigest)
    }

    private func hasMatchingFloorPlanOperation(_ workOrder: WorkOrder, floorID: ObjectID, metadata: CloudRecordAssetMetadata) -> Bool {
        workOrder.plannedOperations.contains {
            guard case let .floorPlan(.bindAsset(planned)) = $0 else { return false }
            return planned.floorID == floorID && planned.assetMetadata == metadata
        }
    }

    private func loadCurrentBinding(_ key: ResourceKey, namespace: PersistenceNamespace) async throws -> CloudExactRecordSnapshot? {
        let current = try await exactRecords.exactRecord(for: key, in: namespace.workspaceZone)
        guard let current else { return nil }
        guard current.workspaceZone == namespace.workspaceZone,
            current.resourceKey == key,
            current.recordType == CloudRecordNaming.floorPlanAssetBindingRecordType,
            current.schemaVersion == CloudRecordNaming.schemaVersion
        else {
            throw ProductionFloorPlanAssetAuthorityError.malformedAuthoritativeRecord(key)
        }
        return current
    }

    private func buildFloorPlanMutation(
        _ request: FloorPlanAssetBindingRequest, authorization: AuthorizedOperationContext, trusted: TrustedProductionSession,
        claim: ClaimedStagedAttachment, workOrder: FloorPlanWorkOrderBindingState, sentinel: CloudExactRecordSnapshot,
        currentBinding: CloudExactRecordSnapshot?, namespace: PersistenceNamespace
    ) throws -> PreparedFloorPlanAssetMutation {
        let auditID = AuditEvent.deterministicID(for: authorization.operationID)
        let asset = try makeFloorPlanAsset(workOrder.metadata, bytes: claim.sanitizedBytes)
        let binding = try FloorPlanAssetBindingRecord(
            floorID: request.floorID, workOrderID: workOrder.workOrder.id,
            assetMetadata: workOrder.metadata, intentDigest: workOrder.intentDigest, operationID: authorization.operationID, auditEventID: auditID,
            boundAt: trusted.actorSnapshot.capturedAt)
        let saves = try floorPlanSaves(sentinel: sentinel, binding: binding, asset: asset)
        let audit = floorPlanAudit(workOrder: workOrder.workOrder, trusted: trusted, saves: saves, auditID: auditID, operationID: authorization.operationID)
        let receipt = OperationReceipt(
            workspaceZone: namespace.workspaceZone, operationID: authorization.operationID,
            intentDigest: workOrder.intentDigest, auditEventID: auditID)
        let assertion = AuthoritativeReadAssertion(
            resourceKey: workOrder.snapshot.resourceKey, recordType: workOrder.snapshot.recordType,
            schemaVersion: workOrder.snapshot.schemaVersion, encodedRecord: workOrder.snapshot.payload, precondition: workOrder.snapshot.exactPrecondition)
        let preconditions = floorPlanPreconditions(
            sentinel: sentinel, assertion: assertion, bindingKey: binding.resourceKey,
            currentBinding: currentBinding, auditID: auditID, receipt: receipt)
        let mutation = try AuthoritativeActivationMutation(
            workspaceZone: namespace.workspaceZone, operationID: authorization.operationID,
            intentDigest: workOrder.intentDigest, actor: trusted.actorSnapshot, saves: saves, tombstones: [], preconditions: preconditions,
            readAssertions: [assertion], auditEvent: audit, receipt: receipt)
        return PreparedFloorPlanAssetMutation(mutation: mutation, receipt: receipt)
    }

    private func makeFloorPlanAsset(_ metadata: CloudRecordAssetMetadata, bytes: Data) throws -> CloudRecordAssetDescriptor {
        try CloudRecordAssetDescriptor(
            id: metadata.id, fieldName: metadata.fieldName, sha256: metadata.sha256,
            contentType: metadata.contentType, byteCount: metadata.byteCount, storage: .inline(bytes))
    }

    private func floorPlanSaves(
        sentinel: CloudExactRecordSnapshot, binding: FloorPlanAssetBindingRecord, asset: CloudRecordAssetDescriptor
    ) throws -> [AuthoritativeRecordSave] {
        [
            AuthoritativeRecordSave(
                resourceKey: sentinel.resourceKey, recordType: sentinel.recordType,
                schemaVersion: sentinel.schemaVersion, encodedRecord: sentinel.payload),
            AuthoritativeRecordSave(
                resourceKey: binding.resourceKey, recordType: CloudRecordNaming.floorPlanAssetBindingRecordType,
                schemaVersion: CloudRecordNaming.schemaVersion, encodedRecord: try CloudDeterministicCoding.encode(binding), recordAsset: asset),
        ].sorted { $0.resourceKey < $1.resourceKey }
    }

    private func floorPlanAudit(
        workOrder: WorkOrder, trusted: TrustedProductionSession, saves: [AuthoritativeRecordSave], auditID: ObjectID, operationID: ObjectID
    ) -> AuditEvent {
        AuditEvent(
            id: auditID, operationID: operationID, actorID: trusted.actorSnapshot.actorID, affectedObjectIDs: [],
            workOrderID: workOrder.id, occurredAt: trusted.actorSnapshot.capturedAt, result: .accepted,
            installationID: trusted.actorSnapshot.installationID, sessionID: trusted.actorSnapshot.sessionID,
            sessionGeneration: trusted.actorSnapshot.sessionGeneration, source: .interactive, affectedResourceKeys: saves.map(\.resourceKey).sorted(),
            changes: saves.map { AuditRecordChange(resourceKey: $0.resourceKey, after: $0.encodedRecord) }.sorted { $0.resourceKey < $1.resourceKey },
            ticket: workOrder.ticket, policyVersion: Self.policyVersion)
    }

    private func floorPlanPreconditions(
        sentinel: CloudExactRecordSnapshot, assertion: AuthoritativeReadAssertion, bindingKey: ResourceKey,
        currentBinding: CloudExactRecordSnapshot?, auditID: ObjectID, receipt: OperationReceipt
    ) -> [MutationPrecondition] {
        var values: [MutationPrecondition] = [
            .exactSystemFields(sentinel.resourceKey, sentinel.exactPrecondition),
            .exactSystemFields(assertion.resourceKey, assertion.precondition),
            .mustNotExist(.object(auditID)),
            .mustNotExist(receipt.id),
        ]
        if let currentBinding {
            values.append(.exactSystemFields(bindingKey, currentBinding.exactPrecondition))
        } else {
            values.append(.mustNotExist(bindingKey))
        }
        return values.sorted { $0.resourceKey < $1.resourceKey }
    }
}
