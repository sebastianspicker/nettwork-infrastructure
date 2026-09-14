import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    func validateMirror(_ record: LocalMirrorRecord, in namespace: PersistenceNamespace) throws {
        guard record.namespace == namespace,
            !record.recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            record.schemaVersion >= 1
        else { throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey) }
        if !record.isTombstone {
            guard let payload = record.payload, !payload.isEmpty,
                record.exactPrecondition != nil
            else {
                throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey)
            }
        }
    }

    func validateSyncState(_ state: LocalSyncState, in namespace: PersistenceNamespace) throws {
        guard state.namespace == namespace else { throw PersistenceStoreError.invalidNamespace }
    }

    func validateNewOperation(_ operation: OutboxOperation) throws {
        let namespace = operation.namespace
        let envelope = operation.envelope
        guard operation.state == .pending, operation.attemptCount == 0,
            operation.nextRetryAt == nil, operation.lastFailure == nil, operation.receipt == nil,
            !operation.resourceKeys.isEmpty,
            !operation.dependencyOperationIDs.contains(operation.operationID),
            envelope.accountContext.namespace == namespace,
            envelope.accountContext.namespace.workspaceZone == namespace.workspaceZone,
            envelope.actorContext.sessionGeneration == namespace.sessionGeneration,
            envelope.actorContext.cloudKitUserRecordName == namespace.cloudKitAccountRecordName,
            envelope.actorContext.installationID == envelope.mutation.actor.installationID,
            envelope.actorContext.cloudKitUserRecordName == envelope.mutation.actor.actorID,
            envelope.mutation.actor.sessionGeneration == namespace.sessionGeneration,
            envelope.mutation.workspaceZone == namespace.workspaceZone,
            envelope.mutation.operationID == operation.operationID,
            envelope.mutation.workOrder.intentDigest == envelope.mutation.intentDigest,
            envelope.mutation.receipt
                == OperationReceipt(
                    workspaceZone: namespace.workspaceZone,
                    operationID: operation.operationID, intentDigest: envelope.mutation.intentDigest,
                    auditEventID: envelope.mutation.auditEvent.id),
            envelope.mutation.resourceKeys == operation.resourceKeys,
            Set(envelope.mutation.preconditions.map(\.resourceKey)) == operation.resourceKeys,
            envelope.mutation.preconditions.count == operation.resourceKeys.count
        else {
            throw PersistenceStoreError.invalidOperation(operation.operationID)
        }
        try validateReservationAcknowledgement(in: envelope, namespace: namespace, operationID: operation.operationID)
        for precondition in envelope.mutation.preconditions {
            switch precondition {
            case .mustNotExist(let resourceKey):
                guard envelope.baseSnapshots[resourceKey] == nil else { throw PersistenceStoreError.invalidOperation(operation.operationID) }
            case .exactSystemFields(let resourceKey, let exact):
                guard !exact.systemFields.isEmpty,
                    !exact.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let snapshot = envelope.baseSnapshots[resourceKey],
                    snapshot.systemFields == exact.systemFields,
                    snapshot.changeTag == exact.changeTag
                else {
                    throw PersistenceStoreError.invalidOperation(operation.operationID)
                }
            }
        }
    }

    func validateReservationAcknowledgement(in envelope: ExecutionEnvelope, namespace: PersistenceNamespace, operationID: ObjectID) throws {
        let workOrder = envelope.mutation.workOrder
        guard let reservation = workOrder.reservation else {
            guard workOrder.status != .executing else {
                throw PersistenceStoreError.invalidReservationAcknowledgement(operationID)
            }
            return
        }
        guard let acknowledgement = reservation.acknowledgedByCloudKit else {
            guard workOrder.status != .executing else {
                throw PersistenceStoreError.invalidReservationAcknowledgement(operationID)
            }
            return
        }
        guard let intentDigest = workOrder.intentDigest,
            acknowledgement.workspaceZone == namespace.workspaceZone,
            acknowledgement.cloudKitAccountRecordName == namespace.cloudKitAccountRecordName,
            acknowledgement.sessionGeneration == namespace.sessionGeneration,
            acknowledgement.reservationID == reservation.id,
            acknowledgement.workOrderID == workOrder.id,
            acknowledgement.ownerID == reservation.ownerID,
            acknowledgement.resourceKeys == reservation.resourceKeys,
            acknowledgement.intentDigest == intentDigest,
            !acknowledgement.systemFields.isEmpty,
            !acknowledgement.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            acknowledgement.acknowledgedAt <= envelope.clientTime,
            envelope.clientTime < acknowledgement.expiresAt
        else {
            throw PersistenceStoreError.invalidReservationAcknowledgement(operationID)
        }
    }

    func mutateOperation(operationID: ObjectID, namespace: PersistenceNamespace, update: (inout OutboxOperation) throws -> Void) throws {
        try transaction {
            try validateActiveLease(for: namespace)
            let key = PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "outbox:\(operationID.description)")
            guard let model = try outboxModel(matching: key) else { throw PersistenceStoreError.unknownOperation(operationID) }
            var operation = try PersistenceCoding.decode(OutboxOperation.self, from: model.operationData)
            guard operation.namespace == namespace, operation.operationID == operationID else {
                throw PersistenceStoreError.malformedStoredValue("outbox identity")
            }
            try update(&operation)
            model.operationData = try PersistenceCoding.encode(operation)
            model.stateRaw = operation.state.rawValue
            model.attemptCount = operation.attemptCount
            model.nextRetryAt = operation.nextRetryAt
            model.lastFailureData = try operation.lastFailure.map { try PersistenceCoding.encode($0) }
            model.receiptData = try operation.receipt.map { try PersistenceCoding.encode($0) }
        }
    }

    func decodedOperations(namespace: PersistenceNamespace) throws -> [OutboxOperation] {
        try outboxModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace)).compactMap { model in
            guard !model.operationData.isEmpty else { return nil }
            let operation = try PersistenceCoding.decode(OutboxOperation.self, from: model.operationData)
            guard operation.namespace == namespace else { throw PersistenceStoreError.malformedStoredValue("outbox namespace") }
            return operation
        }
    }

    func decodeMirror(_ model: LocalRecordMirror, namespace: PersistenceNamespace) throws -> LocalMirrorRecord {
        let resourceKey = try PersistenceCoding.decode(ResourceKey.self, from: model.resourceKeyData)
        let visibility =
            try model.visibilityData.map {
                try PersistenceCoding.decode(WorkspaceRecordVisibility.self, from: $0)
            } ?? .live
        let assetMetadata = try model.recordAssetMetadataData.map {
            try PersistenceCoding.decode(CloudRecordAssetMetadata.self, from: $0)
        }
        return LocalMirrorRecord(
            namespace: namespace, resourceKey: resourceKey,
            recordType: model.recordType, schemaVersion: model.schemaVersion, payload: model.payload,
            systemFields: model.systemFields, changeTag: model.changeTag, isTombstone: model.isTombstone,
            visibility: visibility, recordAssetMetadata: assetMetadata,
            serverModifiedAt: model.serverModifiedAt, verifiedAt: model.verifiedAt)
    }

    func overwrite(_ model: LocalRecordMirror, with record: LocalMirrorRecord) throws {
        model.resourceKeyData = try PersistenceCoding.encode(record.resourceKey)
        model.recordType = record.recordType
        model.schemaVersion = record.schemaVersion
        model.payload = record.payload
        model.systemFields = record.systemFields
        model.changeTag = record.changeTag
        model.isTombstone = record.isTombstone
        model.visibilityData = try PersistenceCoding.encode(record.visibility)
        model.recordAssetMetadataData = try record.recordAssetMetadata.map { try PersistenceCoding.encode($0) }
        model.serverModifiedAt = record.serverModifiedAt
        model.verifiedAt = record.verifiedAt
    }

    /// V9 writes only rows incident to the incoming records. A missing or
    /// incompatible marker is fail-closed; `repairMirrorMaintenanceIfNeeded`
    /// is the explicit, separately-auditable full-mirror recovery path.
}
