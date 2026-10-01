import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension CompositeCloudRemoteReferenceValidator {
    func references(for envelope: CloudRecordEnvelope) throws -> RecordReferences {
        if envelope.isDeleted { return try deletedReferences(for: envelope) }
        switch envelope.recordType {
        case WorkspaceRecordType.location, WorkspaceRecordType.rack, WorkspaceRecordType.deviceType, WorkspaceRecordType.portTemplate,
            WorkspaceRecordType.moduleTemplate, WorkspaceRecordType.physicalTopology,
            WorkspaceRecordType.workspaceHierarchy,
            WorkspaceRecordType.templatePlacementState:
            return try foundationReferences(envelope)
        case WorkspaceRecordType.device, WorkspaceRecordType.module, WorkspaceRecordType.rackPlacement, WorkspaceRecordType.floorPlanAnchor,
            WorkspaceRecordType.port, WorkspaceRecordType.cable, WorkspaceRecordType.internalLink,
            WorkspaceRecordType.topologyTombstone,
            WorkspaceRecordType.hierarchyTombstone:
            return try topologyReferences(envelope)
        case WorkspaceRecordType.prefix, WorkspaceRecordType.vrf, WorkspaceRecordType.ipAddressRecord, WorkspaceRecordType.vlanGroup:
            return try addressReferences(envelope)
        case WorkspaceRecordType.vlan, WorkspaceRecordType.interface, WorkspaceRecordType.ipAddressAssignment, WorkspaceRecordType.interfaceVLANMembership:
            return try networkReferences(envelope)
        case CloudRecordNaming.workOrderRecordType, CloudRecordNaming.reservationLockRecordType, CloudRecordNaming.auditRecordType,
            CloudRecordNaming.receiptRecordType,
            CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType:
            return try operationalReferences(envelope)
        case CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType, CloudRecordNaming.attachmentEvidenceBindingRecordType,
            CloudRecordNaming.floorPlanAssetBindingRecordType,
            CloudRecordNaming.workspaceAssetRecordType, CloudRecordNaming.workspaceRecordType, CloudRecordNaming.shareRecordType,
            CloudRecordNaming.tombstoneRecordType,
            CloudStagedTransferRecordType.session:
            return try terminalReferences(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func deletedReferences(for envelope: CloudRecordEnvelope) throws -> RecordReferences {
        guard envelope.recordType == CloudRecordNaming.importedHistoricalReferenceRecordType else {
            return RecordReferences(deletedResourceKeys: [envelope.resourceKey])
        }
        let marker = try CloudDeterministicCoding.decode(ImportedHistoricalReferenceRecord.self, from: envelope.payload)
        return RecordReferences(historicalReferences: Set(marker.auditEventIDs.map(ResourceKey.object)), deletedResourceKeys: [marker.resourceKey])
    }

    private func foundationReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.location:
            let value = try CloudDeterministicCoding.decode(Location.self, from: envelope.payload)
            return value.deletedAt == nil ? live(value.parentID.map { [$0] } ?? []) : deletion(envelope)
        case WorkspaceRecordType.rack:
            let value = try CloudDeterministicCoding.decode(Rack.self, from: envelope.payload)
            return value.deletedAt == nil ? live([value.locationID]) : deletion(envelope)
        case WorkspaceRecordType.deviceType:
            return live(try CloudDeterministicCoding.decode(DeviceType.self, from: envelope.payload).moduleSlots.flatMap(\.allowedModuleTemplateIDs))
        case WorkspaceRecordType.portTemplate, WorkspaceRecordType.moduleTemplate, WorkspaceRecordType.physicalTopology, WorkspaceRecordType.workspaceHierarchy,
            WorkspaceRecordType.templatePlacementState:
            return RecordReferences()
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func topologyReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.device, WorkspaceRecordType.module, WorkspaceRecordType.rackPlacement, WorkspaceRecordType.floorPlanAnchor,
            WorkspaceRecordType.port:
            return try topologyObjectReferences(envelope)
        case WorkspaceRecordType.cable, WorkspaceRecordType.internalLink, WorkspaceRecordType.topologyTombstone, WorkspaceRecordType.hierarchyTombstone:
            return try topologyRelationshipReferences(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func topologyObjectReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.device:
            let value = try CloudDeterministicCoding.decode(Device.self, from: envelope.payload)
            return live([value.typeID] + (value.rackID.map { [$0] } ?? []))
        case WorkspaceRecordType.module:
            let value = try CloudDeterministicCoding.decode(Module.self, from: envelope.payload)
            return live([value.deviceID, value.templateID])
        case WorkspaceRecordType.rackPlacement:
            let value = try CloudDeterministicCoding.decode(RackPlacement.self, from: envelope.payload)
            return live([value.deviceID, value.rackID])
        case WorkspaceRecordType.floorPlanAnchor:
            let value = try CloudDeterministicCoding.decode(FloorPlanAnchor.self, from: envelope.payload)
            return live([value.objectID, value.floorID])
        case WorkspaceRecordType.port:
            let value = try CloudDeterministicCoding.decode(NetworkModel.Port.self, from: envelope.payload)
            return live([value.deviceID] + (value.moduleID.map { [$0] } ?? []))
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func topologyRelationshipReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.cable:
            let value = try CloudDeterministicCoding.decode(Cable.self, from: envelope.payload)
            return live([value.endpointA, value.endpointB])
        case WorkspaceRecordType.internalLink:
            let value = try CloudDeterministicCoding.decode(InternalLink.self, from: envelope.payload)
            return live([value.endpointA, value.endpointB])
        case WorkspaceRecordType.topologyTombstone: return tombstone(try CloudDeterministicCoding.decode(TopologyTombstone.self, from: envelope.payload).id)
        case WorkspaceRecordType.hierarchyTombstone: return tombstone(try CloudDeterministicCoding.decode(HierarchyTombstone.self, from: envelope.payload).id)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func addressReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.prefix: return try prefixReferences(envelope)
        case WorkspaceRecordType.vrf, WorkspaceRecordType.ipAddressRecord, WorkspaceRecordType.vlanGroup:
            return try addressRecordReferences(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func prefixReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        let value = try CloudDeterministicCoding.decode(Prefix.self, from: envelope.payload)
        return value.isActive ? live([value.vrfID]) : deletion(envelope)
    }

    private func addressRecordReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.vrf:
            return try CloudDeterministicCoding.decode(VRF.self, from: envelope.payload).isActive ? RecordReferences() : deletion(envelope)
        case WorkspaceRecordType.ipAddressRecord:
            let value = try CloudDeterministicCoding.decode(IPAddressRecord.self, from: envelope.payload)
            return value.isActive
                ? live([value.vrfID] + (value.assignedInterfaceID.map { [$0] } ?? [])) : RecordReferences(deletedResourceKeys: [.string(value.id)])
        case WorkspaceRecordType.vlanGroup:
            return try CloudDeterministicCoding.decode(VLANGroup.self, from: envelope.payload).isActive ? RecordReferences() : deletion(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func networkReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.vlan, WorkspaceRecordType.interface: return try networkConfigurationReferences(envelope)
        case WorkspaceRecordType.ipAddressAssignment, WorkspaceRecordType.interfaceVLANMembership: return try networkBindingReferences(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func networkConfigurationReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.vlan:
            let value = try CloudDeterministicCoding.decode(VLAN.self, from: envelope.payload)
            return value.isActive ? live([value.groupID]) : deletion(envelope)
        case WorkspaceRecordType.interface:
            let value = try CloudDeterministicCoding.decode(Interface.self, from: envelope.payload)
            return value.isActive ? live([value.deviceID] + (value.physicalPortID.map { [$0] } ?? []) + (value.vlanID.map { [$0] } ?? [])) : deletion(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func networkBindingReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case WorkspaceRecordType.ipAddressAssignment:
            let value = try CloudDeterministicCoding.decode(IPAddressAssignment.self, from: envelope.payload)
            return value.isActive ? RecordReferences(requiredLiveReferences: [.string(value.addressID), .object(value.interfaceID)]) : deletion(envelope)
        case WorkspaceRecordType.interfaceVLANMembership:
            let value = try CloudDeterministicCoding.decode(InterfaceVLANMembership.self, from: envelope.payload)
            return value.isActive ? live([value.interfaceID, value.vlanID]) : deletion(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func operationalReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case CloudRecordNaming.workOrderRecordType: return try workOrderReferences(envelope)
        case CloudRecordNaming.reservationLockRecordType:
            let value = try CloudDeterministicCoding.decode(ResourceReservationLock.self, from: envelope.payload)
            return RecordReferences(requiredLiveReferences: [.object(value.workOrderID)], historicalReferences: [value.resourceKey])
        case CloudRecordNaming.auditRecordType: return try auditReferences(envelope)
        case CloudRecordNaming.receiptRecordType: return live([try CloudDeterministicCoding.decode(OperationReceipt.self, from: envelope.payload).auditEventID])
        case CloudRecordNaming.attachmentEvidenceQuotaLedgerRecordType:
            return live([try CloudDeterministicCoding.decode(AttachmentEvidenceQuotaLedger.self, from: envelope.payload).workOrderID])
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func terminalReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        switch envelope.recordType {
        case CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType:
            let value = try CloudDeterministicCoding.decode(AttachmentEvidenceReservationRelease.self, from: envelope.payload)
            return RecordReferences(requiredLiveReferences: [
                .object(value.workOrderID), .attachmentEvidenceQuotaLedger(for: value.workOrderID), .attachmentEvidenceBinding(for: value.attachmentID),
                .operationReceipt(operationID: value.operationID),
            ])
        case CloudRecordNaming.attachmentEvidenceBindingRecordType:
            let value = try CloudDeterministicCoding.decode(AttachmentEvidenceBindingRecord.self, from: envelope.payload)
            return RecordReferences(requiredLiveReferences: [
                .object(value.workOrderID), .attachmentEvidenceQuotaLedger(for: value.workOrderID), .attachmentEvidenceReservationRelease(value.reservationID),
                .operationReceipt(operationID: value.operationID), .object(value.auditEventID),
            ])
        case CloudRecordNaming.floorPlanAssetBindingRecordType:
            let value = try CloudDeterministicCoding.decode(FloorPlanAssetBindingRecord.self, from: envelope.payload)
            return RecordReferences(requiredLiveReferences: [
                .object(value.floorID), .object(value.workOrderID), .object(value.auditEventID), .operationReceipt(operationID: value.operationID),
            ])
        case CloudRecordNaming.workspaceAssetRecordType, CloudRecordNaming.workspaceRecordType, CloudRecordNaming.shareRecordType,
            CloudStagedTransferRecordType.session:
            return RecordReferences()
        case CloudRecordNaming.tombstoneRecordType: return deletion(envelope)
        default: throw CloudMirrorAdapterError.unsupportedSemanticRecord(envelope.recordType)
        }
    }

    private func workOrderReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        let value = try CloudDeterministicCoding.decode(WorkOrder.self, from: envelope.payload)
        let lockKeys = Set(value.reservedResourceKeys.map(ResourceKey.reservationLock))
        switch value.status {
        case .draft: return RecordReferences()
        case .reserved, .approved, .executing, .cancellationRequested:
            return RecordReferences(requiredLiveReferences: lockKeys, historicalReferences: value.reservedResourceKeys)
        case .completed, .cancelled, .reconciliation: return RecordReferences(historicalReferences: value.reservedResourceKeys.union(lockKeys))
        }
    }

    private func auditReferences(_ envelope: CloudRecordEnvelope) throws -> RecordReferences {
        let value = try CloudDeterministicCoding.decode(AuditEvent.self, from: envelope.payload)
        var references = Set(value.affectedResourceKeys)
        references.formUnion(value.affectedObjectIDs.map(ResourceKey.object))
        references.formUnion(value.changes.map(\.resourceKey))
        if let workOrderID = value.workOrderID { references.insert(.object(workOrderID)) }
        return RecordReferences(historicalReferences: references)
    }

    private func live(_ ids: some Sequence<ObjectID>) -> RecordReferences { RecordReferences(requiredLiveReferences: Set(ids.map(ResourceKey.object))) }
    private func deletion(_ envelope: CloudRecordEnvelope) -> RecordReferences { RecordReferences(deletedResourceKeys: [envelope.resourceKey]) }
    private func tombstone(_ id: ObjectID) -> RecordReferences { RecordReferences(deletedResourceKeys: [.object(id)]) }
}
