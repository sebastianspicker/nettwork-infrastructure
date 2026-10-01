import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    private func transferRecords(from records: [LocalMirrorRecord], provenance: ArchiveSourceProvenance) throws -> [WorkspaceTransferRecord] {
        let transfer = try records.compactMap { record in
            try transferRecord(from: record, provenance: provenance)
        }
        return transfer.sorted(by: transferLess)
    }

    private func transferRecord(from record: LocalMirrorRecord, provenance: ArchiveSourceProvenance) throws -> WorkspaceTransferRecord? {
        guard let type = transferRecordType(for: record.recordType) else {
            guard isExplicitlyOmittedMirrorRecordType(record.recordType) else {
                throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(record.resourceKey)
            }
            return nil
        }
        guard record.schemaVersion == WorkspaceTransferRecord.currentSchemaVersion else {
            throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(record.resourceKey)
        }
        let payload = try canonicalTransferPayload(for: record, type: type, provenance: provenance)
        return WorkspaceTransferRecord(
            resourceKey: record.resourceKey,
            recordType: type,
            schemaVersion: record.schemaVersion,
            payload: payload,
            tombstone: try recordTombstone(for: record, type: type, payload: payload)
        )
    }

    private func canonicalTransferPayload(
        for record: LocalMirrorRecord, type: WorkspaceTransferRecordType, provenance: ArchiveSourceProvenance
    ) throws -> Data {
        let payload = record.payload ?? Data()
        if record.isTombstone && payload.isEmpty {
            return try hardDeletePayload(for: record, type: type)
        }
        if let marker = try? WorkspaceTransferCoding.decode(WorkspaceHardDeleteMarker.self, from: payload) {
            return try validatedHardDeletePayload(marker, for: record, type: type)
        }
        if type == .importedHistoricalReference {
            return try canonicalHistoricalReferencePayload(payload, resourceKey: record.resourceKey, provenance: provenance)
        }
        guard !payload.isEmpty else {
            throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(record.resourceKey)
        }
        return payload
    }

    private func hardDeletePayload(for record: LocalMirrorRecord, type: WorkspaceTransferRecordType) throws -> Data {
        guard let tombstone = hardDeleteTombstone(for: type, deletedAt: record.serverModifiedAt) else {
            throw ProductionWorkspaceTransferAuthorityError.unsupportedMirrorTombstone(record.resourceKey)
        }
        return try WorkspaceTransferCoding.encode(
            WorkspaceHardDeleteMarker(
                resourceKey: record.resourceKey,
                recordType: type,
                deletedAt: tombstone.deletedAt
            ))
    }

    private func validatedHardDeletePayload(
        _ marker: WorkspaceHardDeleteMarker, for record: LocalMirrorRecord, type: WorkspaceTransferRecordType
    ) throws -> Data {
        guard record.isTombstone,
            marker.resourceKey == record.resourceKey,
            marker.recordType == type,
            hardDeleteTombstone(for: type, deletedAt: marker.deletedAt) != nil
        else {
            throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(record.resourceKey)
        }
        return try WorkspaceTransferCoding.encode(marker)
    }

    private func canonicalHistoricalReferencePayload(_ payload: Data, resourceKey: ResourceKey, provenance: ArchiveSourceProvenance) throws -> Data {
        guard
            let marker = try? WorkspaceTransferCoding.decode(
                WorkspaceImportedHistoricalReference.self, from: payload
            ), marker.resourceKey == resourceKey
        else {
            throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(resourceKey)
        }
        return try WorkspaceTransferCoding.encode(
            WorkspaceImportedHistoricalReference(
                resourceKey: marker.resourceKey,
                sourceWorkspaceID: provenance.workspaceID,
                sourceContainerIdentifier: provenance.containerIdentifier,
                sourceZoneName: provenance.zoneName,
                sourceZoneOwnerRecordName: provenance.zoneOwnerRecordName,
                auditEventIDs: marker.auditEventIDs,
                recordedAt: marker.recordedAt
            ))
    }

    private func recordTombstone(for record: LocalMirrorRecord, type: WorkspaceTransferRecordType, payload: Data) throws -> WorkspaceTransferTombstone? {
        let embedded = try transferTombstone(from: payload, recordType: type, resourceKey: record.resourceKey)
        guard record.isTombstone else { return embedded }
        let hardDelete = try? WorkspaceTransferCoding.decode(WorkspaceHardDeleteMarker.self, from: payload)
        guard
            let tombstone = embedded
                ?? hardDelete.map({ WorkspaceTransferTombstone(deletedAt: $0.deletedAt) })
                ?? hardDeleteTombstone(for: type, deletedAt: record.serverModifiedAt)
        else {
            throw ProductionWorkspaceTransferAuthorityError.unsupportedMirrorTombstone(record.resourceKey)
        }
        return tombstone
    }

    /// Archive export uses the same aggregate-to-direct normalization as
    /// feature reads and mutation planning. Legacy aggregates are migration
    /// seeds only; complete canonical per-record rows are emitted so a newer
    /// direct mutation can never disappear from the archive.
    func canonicalTransferRecords(from records: [LocalMirrorRecord], provenance: ArchiveSourceProvenance) throws -> [WorkspaceTransferRecord] {
        let normalized = try ProductionMirrorDomainProjection(records: records)
        try validateCanonicalProjection(normalized)
        let retainedRecords = canonicalRetainedRecords(from: records)
        var transfer = try transferRecords(from: retainedRecords, provenance: provenance)
        try appendCanonicalProjection(normalized, to: &transfer)
        try validateCanonicalTombstones(normalized, retainedRecords: retainedRecords)
        return try sortedUniqueTransferRecords(transfer)
    }

    private func hardDeleteTombstone(for type: WorkspaceTransferRecordType, deletedAt: Date) -> WorkspaceTransferTombstone? {
        let hardDeleteTypes: Set<WorkspaceTransferRecordType> = [
            .deviceType, .portTemplate, .moduleTemplate, .device, .module,
            .rackPlacement, .port, .internalLink, .cable, .floorPlanAnchor,
            .workOrder, .reservationLock, .importedHistoricalReference,
        ]
        return hardDeleteTypes.contains(type)
            ? WorkspaceTransferTombstone(deletedAt: deletedAt)
            : nil
    }

    func transferRecordType(for persistedType: String) -> WorkspaceTransferRecordType? {
        if let type = WorkspaceTransferRecordType(rawValue: persistedType) {
            return type
        }
        if let canonicalType = CloudRecordNaming.canonicalRecordType(persistedType),
            let type = WorkspaceTransferRecordType(rawValue: canonicalType)
        {
            return type
        }
        switch persistedType {
        case LocalRecordKind.workOrder: return .workOrder
        case LocalRecordKind.prefix: return .prefix
        default: return nil
        }
    }

    func isExplicitlyOmittedMirrorRecordType(_ persistedType: String) -> Bool {
        [
            CloudRecordNaming.workspaceRecordType,
            CloudRecordNaming.shareRecordType,
            CloudRecordNaming.auditRecordType,
            LocalRecordKind.auditEvent,
            CloudRecordNaming.workspaceAssetRecordType,
            CloudRecordNaming.tombstoneRecordType,
            CloudStagedTransferRecordType.session,
            WorkspaceRecordType.physicalTopology,
            "PhysicalTopology",
            WorkspaceRecordType.workspaceHierarchy,
            WorkspaceRecordType.Legacy.workspaceHierarchy,
            WorkspaceRecordType.templatePlacementState,
            WorkspaceRecordType.Legacy.templatePlacementState,
            WorkspaceRecordType.topologyTombstone,
            WorkspaceRecordType.Legacy.topologyTombstone,
            WorkspaceRecordType.hierarchyTombstone,
            WorkspaceRecordType.Legacy.hierarchyTombstone,
            LocalRecordKind.physicalTopology,
        ].contains(persistedType)
    }

    private func transferTombstone(
        from payload: Data, recordType: WorkspaceTransferRecordType, resourceKey: ResourceKey
    ) throws -> WorkspaceTransferTombstone? {
        switch recordType {
        case .location:
            return try decodedTransferTombstone(Location.self, payload: payload, resourceKey: resourceKey, deletedAt: \.deletedAt)
        case .rack:
            return try decodedTransferTombstone(Rack.self, payload: payload, resourceKey: resourceKey, deletedAt: \.deletedAt)
        case .vrf, .prefix, .address, .vlanGroup, .vlan, .interface, .assignment, .membership:
            return try networkTransferTombstone(payload, recordType: recordType, resourceKey: resourceKey)
        case .deviceType, .portTemplate, .moduleTemplate, .device, .module, .rackPlacement, .port, .internalLink, .cable, .floorPlanAnchor,
            .workOrder, .reservationLock, .operationReceipt, .attachmentEvidenceQuotaLedger, .attachmentEvidenceReservationRelease, .attachmentEvidenceBinding,
            .floorPlanAssetBinding:
            return nil
        case .importedHistoricalReference:
            return try decodedTransferTombstone(
                WorkspaceImportedHistoricalReference.self,
                payload: payload,
                resourceKey: resourceKey,
                deletedAt: { $0.recordedAt }
            )
        }
    }

    private func networkTransferTombstone(
        _ payload: Data, recordType: WorkspaceTransferRecordType, resourceKey: ResourceKey
    ) throws -> WorkspaceTransferTombstone? {
        switch recordType {
        case .vrf:
            return try decodedTransferTombstone(VRF.self, payload: payload, resourceKey: resourceKey, deletedAt: \.tombstonedAt)
        case .prefix:
            return try decodedTransferTombstone(Prefix.self, payload: payload, resourceKey: resourceKey, deletedAt: \.tombstonedAt)
        case .address:
            return try decodedTransferTombstone(IPAddressRecord.self, payload: payload, resourceKey: resourceKey, deletedAt: \.tombstonedAt)
        case .vlanGroup:
            return try decodedTransferTombstone(VLANGroup.self, payload: payload, resourceKey: resourceKey, deletedAt: \.tombstonedAt)
        case .vlan:
            return try decodedTransferTombstone(VLAN.self, payload: payload, resourceKey: resourceKey, deletedAt: \.tombstonedAt)
        case .interface:
            return try decodedTransferTombstone(Interface.self, payload: payload, resourceKey: resourceKey, deletedAt: \.tombstonedAt)
        case .assignment:
            return try decodedTransferTombstone(IPAddressAssignment.self, payload: payload, resourceKey: resourceKey, deletedAt: \.tombstonedAt)
        case .membership:
            return try decodedTransferTombstone(InterfaceVLANMembership.self, payload: payload, resourceKey: resourceKey, deletedAt: \.tombstonedAt)
        default:
            return nil
        }
    }

    private func decodedTransferTombstone<T: Decodable>(
        _ type: T.Type,
        payload: Data,
        resourceKey: ResourceKey,
        deletedAt: (T) -> Date?
    ) throws -> WorkspaceTransferTombstone? {
        guard let value = try? CloudDeterministicCoding.decode(type, from: payload) else {
            throw ProductionWorkspaceTransferAuthorityError.malformedMirrorRecord(resourceKey)
        }
        return deletedAt(value).map(WorkspaceTransferTombstone.init(deletedAt:))
    }
}
