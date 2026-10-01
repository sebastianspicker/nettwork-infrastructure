import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

public struct CodableCloudRemoteSemanticValidator: CloudRemoteSemanticValidator {
    public init() {}

    public func validate(_ records: [VerifiedCloudRecord], namespace: PersistenceNamespace) async throws {
        for verified in records where !verified.envelope.isDeleted {
            try validateLiveEnvelope(verified.envelope, namespace: namespace)
        }
    }

    private func validateLiveEnvelope(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        do { try validatePayload(of: envelope, namespace: namespace) } catch let error as CloudMirrorAdapterError { throw error } catch {
            throw CloudMirrorAdapterError.malformedPayload(envelope.resourceKey, String(describing: error))
        }
    }

    private func validatePayload(of envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        switch envelope.recordType {
        case WorkspaceRecordType.physicalTopology, WorkspaceRecordType.workspaceHierarchy, WorkspaceRecordType.templatePlacementState,
            WorkspaceRecordType.location, WorkspaceRecordType.rack,
            WorkspaceRecordType.deviceType, WorkspaceRecordType.portTemplate,
            WorkspaceRecordType.moduleTemplate:
            try validateFoundation(envelope)
        case WorkspaceRecordType.device, WorkspaceRecordType.module, WorkspaceRecordType.rackPlacement, WorkspaceRecordType.floorPlanAnchor,
            WorkspaceRecordType.port, WorkspaceRecordType.cable, WorkspaceRecordType.internalLink:
            try validateTopology(envelope)
        case CloudRecordNaming.workOrderRecordType, CloudRecordNaming.reservationLockRecordType, CloudRecordNaming.auditRecordType,
            CloudRecordNaming.receiptRecordType,
            CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType, CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType,
            CloudRecordNaming.attachmentEvidenceBindingRecordType,
            CloudRecordNaming.floorPlanAssetBindingRecordType, CloudRecordNaming.workspaceAssetRecordType:
            try validateOperational(envelope, namespace: namespace)
        case WorkspaceRecordType.prefix, WorkspaceRecordType.vrf, WorkspaceRecordType.ipAddressRecord, WorkspaceRecordType.vlanGroup, WorkspaceRecordType.vlan,
            WorkspaceRecordType.interface,
            WorkspaceRecordType.ipAddressAssignment, WorkspaceRecordType.interfaceVLANMembership:
            try validateNetwork(envelope)
        case WorkspaceRecordType.topologyTombstone, WorkspaceRecordType.hierarchyTombstone, CloudRecordNaming.workspaceRecordType,
            CloudRecordNaming.shareRecordType,
            CloudRecordNaming.tombstoneRecordType,
            CloudStagedTransferRecordType.session:
            try validateLifecycle(envelope, namespace: namespace)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func validateFoundation(_ envelope: CloudRecordEnvelope) throws {
        switch envelope.recordType {
        case WorkspaceRecordType.physicalTopology:
            try DefaultTopologyEngine.validate(CloudDeterministicCoding.decode(PhysicalTopology.self, from: envelope.payload))
        case WorkspaceRecordType.workspaceHierarchy: try CloudDeterministicCoding.decode(WorkspaceHierarchy.self, from: envelope.payload).validate()
        case WorkspaceRecordType.templatePlacementState: try CloudDeterministicCoding.decode(TemplatePlacementState.self, from: envelope.payload).validate()
        case WorkspaceRecordType.location: try decodeObject(Location.self, envelope: envelope)
        case WorkspaceRecordType.rack: try decodeObject(Rack.self, envelope: envelope)
        case WorkspaceRecordType.deviceType: try decodeObject(DeviceType.self, envelope: envelope)
        case WorkspaceRecordType.portTemplate: try decodeObject(PortTemplate.self, envelope: envelope)
        case WorkspaceRecordType.moduleTemplate: try decodeObject(ModuleTemplate.self, envelope: envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func validateTopology(_ envelope: CloudRecordEnvelope) throws {
        switch envelope.recordType {
        case WorkspaceRecordType.device: try decodeObject(Device.self, envelope: envelope)
        case WorkspaceRecordType.module: try decodeObject(Module.self, envelope: envelope)
        case WorkspaceRecordType.rackPlacement:
            let placement = try CloudDeterministicCoding.decode(RackPlacement.self, from: envelope.payload)
            try verify(envelope.resourceKey == .rackPlacement(deviceID: placement.deviceID), envelope, "rack placement identity")
        case WorkspaceRecordType.floorPlanAnchor: try decodeObject(FloorPlanAnchor.self, envelope: envelope)
        case WorkspaceRecordType.port: try decodeObject(NetworkModel.Port.self, envelope: envelope)
        case WorkspaceRecordType.cable: try decodeObject(Cable.self, envelope: envelope)
        case WorkspaceRecordType.internalLink: try decodeObject(InternalLink.self, envelope: envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func validateOperational(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        switch envelope.recordType {
        case CloudRecordNaming.workOrderRecordType, CloudRecordNaming.reservationLockRecordType,
            CloudRecordNaming.auditRecordType, CloudRecordNaming.receiptRecordType:
            try validateOperationRecord(envelope, namespace: namespace)
        case CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType,
            CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType,
            CloudRecordNaming.attachmentEvidenceBindingRecordType,
            CloudRecordNaming.floorPlanAssetBindingRecordType,
            CloudRecordNaming.workspaceAssetRecordType:
            try validateAssetRecord(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func validateOperationRecord(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        switch envelope.recordType {
        case CloudRecordNaming.workOrderRecordType: try validateWorkOrder(envelope)
        case CloudRecordNaming.reservationLockRecordType: try validateReservationLock(envelope)
        case CloudRecordNaming.auditRecordType: try decodeAndVerify(AuditEvent.self, envelope: envelope)
        case CloudRecordNaming.receiptRecordType: try validateReceipt(envelope, namespace: namespace)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func validateAssetRecord(_ envelope: CloudRecordEnvelope) throws {
        switch envelope.recordType {
        case CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType: try validateQuotaLedger(envelope)
        case CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType: try validateReservationRelease(envelope)
        case CloudRecordNaming.attachmentEvidenceBindingRecordType: try validateEvidenceBinding(envelope)
        case CloudRecordNaming.floorPlanAssetBindingRecordType: try validateFloorPlanBinding(envelope)
        case CloudRecordNaming.workspaceAssetRecordType: try validateWorkspaceAsset(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func validateWorkOrder(_ envelope: CloudRecordEnvelope) throws {
        let value = try CloudDeterministicCoding.decode(WorkOrder.self, from: envelope.payload)
        try verifyIdentity(value.id, envelope: envelope)
        try verify(value.intentDigest != nil, envelope, "work-order intent digest")
    }

    private func validateReservationLock(_ envelope: CloudRecordEnvelope) throws {
        let value = try CloudDeterministicCoding.decode(ResourceReservationLock.self, from: envelope.payload)
        try verify(envelope.resourceKey == value.id, envelope, "reservation lock identity")
        try verify(!value.ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, envelope, "reservation lock identity")
    }

    private func validateReceipt(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        let value = try CloudDeterministicCoding.decode(OperationReceipt.self, from: envelope.payload)
        try verify(value.workspaceZone == namespace.workspaceZone, envelope, "receipt workspace zone")
        try verify(envelope.resourceKey == value.id, envelope, "receipt resource identity")
    }

    private func validateQuotaLedger(_ envelope: CloudRecordEnvelope) throws {
        let value = try CloudDeterministicCoding.decode(AttachmentEvidenceQuotaLedger.self, from: envelope.payload)
        try verify(envelope.resourceKey == value.resourceKey, envelope, "attachment quota ledger identity")
    }

    private func validateReservationRelease(_ envelope: CloudRecordEnvelope) throws {
        let value = try CloudDeterministicCoding.decode(AttachmentEvidenceReservationRelease.self, from: envelope.payload)
        try verify(envelope.resourceKey == value.resourceKey, envelope, "attachment reservation release identity")
    }

    private func validateEvidenceBinding(_ envelope: CloudRecordEnvelope) throws {
        let value = try CloudDeterministicCoding.decode(AttachmentEvidenceBindingRecord.self, from: envelope.payload)
        _ = try AttachmentEvidenceBindingRecord(
            workOrderID: value.workOrderID, attachmentID: value.attachmentID, reservationID: value.reservationID, provenance: value.provenance,
            evidence: value.evidence,
            assetMetadata: value.assetMetadata, intentDigest: value.intentDigest, operationID: value.operationID, auditEventID: value.auditEventID,
            boundAt: value.boundAt)
        try verify(envelope.resourceKey == value.resourceKey, envelope, "attachment evidence binding identity")
        try verify(value.auditEventID == AuditEvent.deterministicID(for: value.operationID), envelope, "attachment evidence binding identity")
        guard let asset = envelope.recordAsset else {
            throw CloudMirrorAdapterError.malformedPayload(envelope.resourceKey, "attachment evidence binding identity")
        }
        try verify(asset.metadata == value.assetMetadata, envelope, "attachment evidence binding identity")
        try verify(asset.metadata.id == value.attachmentID, envelope, "attachment evidence binding identity")
        try verify(
            AttachmentEvidenceBindingRecord.evidenceDigest(for: try asset.validatedBytes()) == value.provenance.domainSeparatedSHA256, envelope,
            "attachment evidence binding identity")
    }

    private func validateFloorPlanBinding(_ envelope: CloudRecordEnvelope) throws {
        let value = try CloudDeterministicCoding.decode(FloorPlanAssetBindingRecord.self, from: envelope.payload)
        _ = try FloorPlanAssetBindingRecord(
            floorID: value.floorID, workOrderID: value.workOrderID, assetMetadata: value.assetMetadata, intentDigest: value.intentDigest,
            operationID: value.operationID,
            auditEventID: value.auditEventID, boundAt: value.boundAt)
        try verify(envelope.resourceKey == value.resourceKey, envelope, "floor-plan asset binding identity")
        try verify(value.auditEventID == AuditEvent.deterministicID(for: value.operationID), envelope, "floor-plan asset binding identity")
        guard let asset = envelope.recordAsset else {
            throw CloudMirrorAdapterError.malformedPayload(envelope.resourceKey, "floor-plan asset binding identity")
        }
        try verify(asset.metadata == value.assetMetadata, envelope, "floor-plan asset binding identity")
        try verify(asset.metadata.id == value.assetMetadata.id, envelope, "floor-plan asset binding identity")
        try verify((try? asset.validatedBytes()) != nil, envelope, "floor-plan asset binding identity")
    }

    private func validateWorkspaceAsset(_ envelope: CloudRecordEnvelope) throws {
        let decoded = try CloudDeterministicCoding.decode(CloudWorkspaceAssetRecord.self, from: envelope.payload)
        let value = try CloudWorkspaceAssetRecord(assetID: decoded.assetID, relativePath: decoded.relativePath, metadata: decoded.metadata)
        try verify(envelope.resourceKey == value.resourceKey, envelope, "workspace asset identity")
        guard let descriptor = envelope.recordAsset else { throw CloudMirrorAdapterError.malformedPayload(envelope.resourceKey, "workspace asset identity") }
        try verify(descriptor.metadata == value.metadata, envelope, "workspace asset identity")
        try verify((try? descriptor.validatedBytes()) != nil, envelope, "workspace asset identity")
    }

    private func validateNetwork(_ envelope: CloudRecordEnvelope) throws {
        switch envelope.recordType {
        case WorkspaceRecordType.prefix: try decodeObject(Prefix.self, envelope: envelope)
        case WorkspaceRecordType.vrf: try decodeObject(VRF.self, envelope: envelope)
        case WorkspaceRecordType.ipAddressRecord:
            let value = try CloudDeterministicCoding.decode(IPAddressRecord.self, from: envelope.payload)
            try verify(envelope.resourceKey == .string(value.id), envelope, "IP address resource identity")
        case WorkspaceRecordType.vlanGroup: try decodeObject(VLANGroup.self, envelope: envelope)
        case WorkspaceRecordType.vlan: try decodeObject(VLAN.self, envelope: envelope)
        case WorkspaceRecordType.interface: try decodeObject(Interface.self, envelope: envelope)
        case WorkspaceRecordType.ipAddressAssignment: try decodeObject(IPAddressAssignment.self, envelope: envelope)
        case WorkspaceRecordType.interfaceVLANMembership: try decodeObject(InterfaceVLANMembership.self, envelope: envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func validateLifecycle(_ envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) throws {
        switch envelope.recordType {
        case WorkspaceRecordType.topologyTombstone: try decodeAndVerify(TopologyTombstone.self, envelope: envelope)
        case WorkspaceRecordType.hierarchyTombstone: try decodeAndVerify(HierarchyTombstone.self, envelope: envelope)
        case CloudRecordNaming.workspaceRecordType:
            let value = try CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: envelope.payload)
            try verify(value.workspaceID == namespace.workspaceID, envelope, "workspace identity")
            try verify(value.zoneName == namespace.zoneName, envelope, "workspace identity")
            try verify(value.zoneOwnerRecordName == namespace.zoneOwnerRecordName, envelope, "workspace identity")
        case CloudRecordNaming.shareRecordType:
            let value = try CloudDeterministicCoding.decode(CloudWorkspaceShareRecord.self, from: envelope.payload)
            try verify(value.workspaceID == namespace.workspaceID, envelope, "share workspace identity")
        case CloudRecordNaming.tombstoneRecordType: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        case CloudStagedTransferRecordType.session:
            let value = try CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: envelope.payload)
            try verify(envelope.resourceKey == value.resourceKey, envelope, "transfer session identity")
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func decodeObject<T: Decodable & Identifiable>(_ type: T.Type, envelope: CloudRecordEnvelope) throws where T.ID == ObjectID {
        try verifyIdentity(
            CloudDeterministicCoding.decode(
                type,
                from: envelope.payload
            ).id, envelope: envelope)
    }
    private func decodeAndVerify<T: Decodable & Identifiable>(_ type: T.Type, envelope: CloudRecordEnvelope) throws where T.ID == ObjectID {
        try decodeObject(type, envelope: envelope)
    }
    private func verifyIdentity(_ id: ObjectID, envelope: CloudRecordEnvelope) throws {
        try verify(envelope.resourceKey == .object(id), envelope, "resource identity")
    }
    private func verify(_ condition: Bool, _ envelope: CloudRecordEnvelope, _ reason: String) throws {
        guard condition else { throw CloudMirrorAdapterError.malformedPayload(envelope.resourceKey, reason) }
    }
}
