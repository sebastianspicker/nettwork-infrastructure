import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension CompositeCloudRemoteReferenceValidator {
    func validateFloorPlanAssetRelationships(candidate: [CloudRecordEnvelope], snapshot: CloudRemoteMirrorSnapshot, activeTransferIDs: Set<ObjectID>) throws {
        guard requiresFloorAssetValidation(candidate) else { return }
        let postState = activePostState(snapshot: snapshot, candidate: candidate, activeTransferIDs: activeTransferIDs)
        let bindings = try floorAssetBindings(in: postState)
        try validateUniqueFloorBindings(bindings)
        let changedKeys = Set(candidate.map(\.resourceKey))
        for binding in bindings where floorBindingNeedsValidation(binding, changedKeys: changedKeys) {
            try validateFloorBinding(binding, postState: postState)
        }
    }

    private func requiresFloorAssetValidation(_ candidate: [CloudRecordEnvelope]) -> Bool {
        let types: Set<String> = [
            CloudRecordNaming.floorPlanAssetBindingRecordType, CloudRecordNaming.workOrderRecordType, CloudRecordNaming.auditRecordType,
            CloudRecordNaming.receiptRecordType,
        ]
        return candidate.contains { !$0.isDeleted && types.contains($0.recordType) }
    }

    private func activePostState(snapshot: CloudRemoteMirrorSnapshot, candidate: [CloudRecordEnvelope], activeTransferIDs: Set<ObjectID>) -> [ResourceKey:
        CloudRecordEnvelope]
    {
        var state = snapshot.recordEnvelopesByResourceKey.filter { _, envelope in
            guard case let .staged(id) = envelope.visibility else { return true }
            return activeTransferIDs.contains(id)
        }
        candidate.forEach { envelope in
            if envelope.isDeleted { state.removeValue(forKey: envelope.resourceKey) } else { state[envelope.resourceKey] = envelope }
        }
        return state
    }

    private func floorAssetBindings(in postState: [ResourceKey: CloudRecordEnvelope]) throws -> [FloorPlanAssetBindingRecord] {
        try postState.values.compactMap { envelope in
            guard envelope.recordType == CloudRecordNaming.floorPlanAssetBindingRecordType else { return nil }
            return try CloudDeterministicCoding.decode(FloorPlanAssetBindingRecord.self, from: envelope.payload)
        }
    }

    private func validateUniqueFloorBindings(_ bindings: [FloorPlanAssetBindingRecord]) throws {
        var seen = Set<ObjectID>()
        for binding in bindings {
            guard seen.insert(binding.floorID).inserted else {
                throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: [binding.resourceKey], reason: "floor has more than one asset binding")
            }
        }
    }

    private func floorBindingNeedsValidation(_ binding: FloorPlanAssetBindingRecord, changedKeys: Set<ResourceKey>) -> Bool {
        [binding.resourceKey, .object(binding.workOrderID), .object(binding.auditEventID), .operationReceipt(operationID: binding.operationID)].contains {
            changedKeys.contains($0)
        }
    }

    private func validateFloorBinding(_ binding: FloorPlanAssetBindingRecord, postState: [ResourceKey: CloudRecordEnvelope]) throws {
        let floor: Location = try floorDependency(Location.self, key: .object(binding.floorID), type: "NettworkLocation", postState: postState)
        let workOrder: WorkOrder = try floorDependency(
            WorkOrder.self, key: .object(binding.workOrderID), type: CloudRecordNaming.workOrderRecordType, postState: postState)
        let audit: AuditEvent = try floorDependency(
            AuditEvent.self, key: .object(binding.auditEventID), type: CloudRecordNaming.auditRecordType, postState: postState)
        let receipt: OperationReceipt = try floorDependency(
            OperationReceipt.self, key: .operationReceipt(operationID: binding.operationID), type: CloudRecordNaming.receiptRecordType, postState: postState)
        guard floorBindingIsAuthoritative(binding, floor: floor, workOrder: workOrder, audit: audit, receipt: receipt) else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: [binding.resourceKey], reason: "floor-plan asset does not form one completed work-order operation")
        }
    }

    private func floorDependency<T: Decodable>(_ type: T.Type, key: ResourceKey, type recordType: String, postState: [ResourceKey: CloudRecordEnvelope]) throws
        -> T
    {
        guard let envelope = postState[key], envelope.recordType == recordType else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: [key], reason: "floor-plan asset dependency is missing")
        }
        return try CloudDeterministicCoding.decode(type, from: envelope.payload)
    }

    private func floorBindingIsAuthoritative(
        _ binding: FloorPlanAssetBindingRecord, floor: Location, workOrder: WorkOrder, audit: AuditEvent, receipt: OperationReceipt
    ) -> Bool {
        floorBindingMatchesWorkOrder(binding, floor: floor, workOrder: workOrder) && floorBindingMatchesReceipt(binding, audit: audit, receipt: receipt)
    }

    private func floorBindingMatchesWorkOrder(_ binding: FloorPlanAssetBindingRecord, floor: Location, workOrder: WorkOrder) -> Bool {
        floor.kind == .floor && workOrder.kind == .floorPlan && workOrder.status == .completed && workOrder.intentDigest == binding.intentDigest
            && floorBindingWasPlanned(binding, workOrder: workOrder)
    }

    private func floorBindingMatchesReceipt(_ binding: FloorPlanAssetBindingRecord, audit: AuditEvent, receipt: OperationReceipt) -> Bool {
        audit.id == binding.auditEventID
            && audit.operationID == binding.operationID
            && audit.workOrderID == binding.workOrderID
            && receipt.operationID == binding.operationID
            && receipt.intentDigest == binding.intentDigest
            && receipt.auditEventID == binding.auditEventID
    }

    private func floorBindingWasPlanned(_ binding: FloorPlanAssetBindingRecord, workOrder: WorkOrder) -> Bool {
        workOrder.plannedOperations.contains { operation in
            guard case let .floorPlan(.bindAsset(value)) = operation else { return false }
            return value.floorID == binding.floorID && value.assetMetadata == binding.assetMetadata
        }
    }
}
