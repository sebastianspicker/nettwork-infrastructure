import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum WorkspaceTransferValidationError: Error, Equatable, Sendable {
    case malformedPayload(WorkspaceTransferRecordType)
    case resourceKeyMismatch(WorkspaceTransferRecordType)
    case tombstoneMetadataMismatch(WorkspaceTransferRecordType)
    case missingReference(kind: String, id: String)
    case hierarchyValidationFailed
    case topologyValidationFailed
    case templateValidationFailed
    case placementValidationFailed
    case ipamValidationFailed
    case operationalValidationFailed
}

/// Typed, complete candidate state reconstructed from transfer records. It is
/// intentionally not a persistence model: validation succeeds before callers
/// receive any authoritative save or tombstone material.
public struct WorkspaceTransferCandidate: Sendable {
    public let records: [WorkspaceTransferRecord]
    public let hierarchy: WorkspaceHierarchy
    public let topology: PhysicalTopology
    public let placement: TemplatePlacementState
    public let portTemplates: [PortTemplate]
    public let moduleTemplates: [ModuleTemplate]
    public let vrfs: [VRF]
    public let prefixes: [Prefix]
    public let addresses: [IPAddressRecord]
    public let vlanGroups: [VLANGroup]
    public let vlans: [VLAN]
    public let interfaces: [Interface]
    public let assignments: [IPAddressAssignment]
    public let memberships: [InterfaceVLANMembership]
    public let workOrders: [WorkOrder]
    public let reservationLocks: [ResourceReservationLock]
    public let releasedReservationLocks: [ResourceReservationLock]
    public let operationReceipts: [OperationReceipt]
    public let attachmentEvidenceQuotaLedgers: [AttachmentEvidenceQuotaLedger]
    public let attachmentEvidenceReservationReleases: [AttachmentEvidenceReservationRelease]
    public let attachmentEvidenceBindings: [AttachmentEvidenceBindingRecord]
    public let floorPlanAssetBindings: [FloorPlanAssetBindingRecord]
    public let importedHistoricalReferences: [WorkspaceImportedHistoricalReference]

    public init(records: [WorkspaceTransferRecord]) throws {
        guard Set(records.map(\.resourceKey)).count == records.count else {
            throw WorkspaceTransferValidationError.operationalValidationFailed
        }
        let decoded = try WorkspaceTransferDecodedRecords(records: records)
        let hierarchy = WorkspaceHierarchy(locations: decoded.locations, racks: decoded.racks)
        let topology = PhysicalTopology(
            deviceTypes: decoded.deviceTypes, devices: decoded.devices, modules: decoded.modules, ports: decoded.ports, cables: decoded.cables,
            internalLinks: decoded.links)
        let placement = TemplatePlacementState(hierarchy: hierarchy, topology: topology, placements: decoded.placements, anchors: decoded.anchors)
        try WorkspaceTransferCandidateValidator.validate(
            hierarchy: hierarchy, topology: topology,
            placement: placement, moduleTemplates: decoded.moduleTemplates, vrfs: decoded.vrfs,
            prefixes: decoded.prefixes, addresses: decoded.addresses, vlanGroups: decoded.vlanGroups,
            vlans: decoded.vlans, interfaces: decoded.interfaces, assignments: decoded.assignments,
            memberships: decoded.memberships, standalonePortTemplates: decoded.portTemplates,
            workOrders: decoded.workOrders, reservationLocks: decoded.reservationLocks,
            releasedReservationLocks: decoded.releasedReservationLocks, receipts: decoded.receipts,
            quotaLedgers: decoded.quotaLedgers, reservationReleases: decoded.reservationReleases,
            bindings: decoded.bindings, floorPlanBindings: decoded.floorPlanBindings)
        self.records = records.sorted(by: Self.sort)
        self.hierarchy = hierarchy
        self.topology = topology
        self.placement = placement
        self.portTemplates = decoded.portTemplates
        self.moduleTemplates = decoded.moduleTemplates
        self.vrfs = decoded.vrfs
        self.prefixes = decoded.prefixes
        self.addresses = decoded.addresses
        self.vlanGroups = decoded.vlanGroups
        self.vlans = decoded.vlans
        self.interfaces = decoded.interfaces
        self.assignments = decoded.assignments
        self.memberships = decoded.memberships
        self.workOrders = decoded.workOrders
        self.reservationLocks = decoded.reservationLocks
        self.releasedReservationLocks = decoded.releasedReservationLocks
        self.operationReceipts = decoded.receipts
        self.attachmentEvidenceQuotaLedgers = decoded.quotaLedgers
        self.attachmentEvidenceReservationReleases = decoded.reservationReleases
        self.attachmentEvidenceBindings = decoded.bindings
        self.floorPlanAssetBindings = decoded.floorPlanBindings
        self.importedHistoricalReferences = decoded.historicalReferences
    }

    static func decode<T: Decodable & Identifiable>(_ type: T.Type, record: WorkspaceTransferRecord, key: (ObjectID) -> ResourceKey) throws -> T
    where T.ID == ObjectID {
        let value: T
        do { value = try WorkspaceTransferCoding.decode(T.self, from: record.payload) } catch {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        guard record.resourceKey == key(value.id) else { throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType) }
        try validateTombstone(record, deletedAt: deletedAt(of: value))
        return value
    }

    static func decodeAddress(_ record: WorkspaceTransferRecord) throws -> IPAddressRecord {
        let value: IPAddressRecord
        do { value = try WorkspaceTransferCoding.decode(IPAddressRecord.self, from: record.payload) } catch {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        guard record.resourceKey == .string(value.id) else { throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType) }
        try validateTombstone(record, deletedAt: value.tombstonedAt)
        return value
    }

    static func decodeRackPlacement(_ record: WorkspaceTransferRecord) throws -> RackPlacement {
        let value: RackPlacement
        do { value = try WorkspaceTransferCoding.decode(RackPlacement.self, from: record.payload) } catch {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        guard record.resourceKey == .rackPlacement(deviceID: value.deviceID) else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        try validateTombstone(record, deletedAt: nil)
        return value
    }

    static func decodeOperationalWorkOrder(_ record: WorkspaceTransferRecord) throws -> WorkOrder {
        let value = try strictOperationalDecode(WorkOrder.self, record: record)
        guard record.resourceKey == .object(value.id), value.intentDigest != nil else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        try validateTombstone(record, deletedAt: nil)
        return value
    }

    static func decodeOperationalReceipt(_ record: WorkspaceTransferRecord) throws -> OperationReceipt {
        let value = try strictOperationalDecode(OperationReceipt.self, record: record)
        guard record.resourceKey == value.id else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        try validateOperationalTombstone(record)
        return value
    }

    static func decodeOperationalReservationLock(_ record: WorkspaceTransferRecord) throws -> ResourceReservationLock {
        let value = try strictOperationalDecode(ResourceReservationLock.self, record: record)
        guard record.resourceKey == value.id,
            !value.ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        return value
    }

    static func decodeOperationalQuotaLedger(_ record: WorkspaceTransferRecord) throws -> AttachmentEvidenceQuotaLedger {
        let value = try strictOperationalDecode(AttachmentEvidenceQuotaLedger.self, record: record)
        do {
            _ = try AttachmentEvidenceQuotaLedger(
                workOrderID: value.workOrderID,
                attachmentCount: value.attachmentCount, totalBytes: value.totalBytes,
                updatedAt: value.updatedAt)
        } catch {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        guard record.resourceKey == value.resourceKey else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        try validateOperationalTombstone(record)
        return value
    }

    static func decodeOperationalReservationRelease(_ record: WorkspaceTransferRecord) throws -> AttachmentEvidenceReservationRelease {
        let value = try strictOperationalDecode(AttachmentEvidenceReservationRelease.self, record: record)
        do {
            _ = try AttachmentEvidenceReservationRelease(
                id: value.id, workOrderID: value.workOrderID,
                attachmentID: value.attachmentID, reservedCount: value.reservedCount,
                reservedBytes: value.reservedBytes, expiresAt: value.expiresAt, releasedAt: value.releasedAt,
                operationID: value.operationID)
        } catch {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        guard record.resourceKey == value.resourceKey else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        try validateOperationalTombstone(record)
        return value
    }

    static func decodeOperationalBinding(_ record: WorkspaceTransferRecord) throws -> AttachmentEvidenceBindingRecord {
        let value = try strictOperationalDecode(AttachmentEvidenceBindingRecord.self, record: record)
        do {
            _ = try AttachmentEvidenceBindingRecord(
                workOrderID: value.workOrderID,
                attachmentID: value.attachmentID, reservationID: value.reservationID,
                provenance: value.provenance, evidence: value.evidence, assetMetadata: value.assetMetadata,
                intentDigest: value.intentDigest, operationID: value.operationID,
                auditEventID: value.auditEventID, boundAt: value.boundAt)
        } catch {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        guard record.resourceKey == value.resourceKey,
            value.auditEventID == AuditEvent.deterministicID(for: value.operationID)
        else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        try validateOperationalTombstone(record)
        return value
    }

    static func decodeFloorPlanAssetBinding(_ record: WorkspaceTransferRecord) throws -> FloorPlanAssetBindingRecord {
        let value = try strictOperationalDecode(FloorPlanAssetBindingRecord.self, record: record)
        do {
            _ = try FloorPlanAssetBindingRecord(
                floorID: value.floorID, workOrderID: value.workOrderID,
                assetMetadata: value.assetMetadata, intentDigest: value.intentDigest,
                operationID: value.operationID, auditEventID: value.auditEventID, boundAt: value.boundAt)
        } catch {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        guard record.resourceKey == value.resourceKey else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        try validateOperationalTombstone(record)
        return value
    }

    static func decodeImportedHistoricalReference(
        _ record: WorkspaceTransferRecord
    ) throws -> WorkspaceImportedHistoricalReference {
        let value = try strictOperationalDecode(WorkspaceImportedHistoricalReference.self, record: record)
        guard record.resourceKey == value.resourceKey, record.tombstone?.deletedAt == value.recordedAt,
            !value.sourceContainerIdentifier.isEmpty, !value.sourceZoneName.isEmpty,
            !value.sourceZoneOwnerRecordName.isEmpty, !value.auditEventIDs.isEmpty,
            value.auditEventIDs == value.auditEventIDs.sorted(),
            Set(value.auditEventIDs).count == value.auditEventIDs.count
        else {
            throw WorkspaceTransferValidationError.resourceKeyMismatch(record.recordType)
        }
        return value
    }

    private static func strictOperationalDecode<T: Codable>(_ type: T.Type, record: WorkspaceTransferRecord) throws -> T {
        let value: T
        do { value = try WorkspaceTransferCoding.decode(T.self, from: record.payload) } catch {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        guard let reencoded = try? WorkspaceTransferCoding.encode(value),
            CanonicalPayloadComparison.matches(stored: record.payload, reencoded: reencoded)
        else {
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
        return value
    }

    private static func validateOperationalTombstone(_ record: WorkspaceTransferRecord) throws {
        guard record.tombstone == nil else {
            throw WorkspaceTransferValidationError.tombstoneMetadataMismatch(record.recordType)
        }
    }

    static func validateHardDeleteMarkerIfPresent(_ record: WorkspaceTransferRecord) throws -> Bool {
        guard
            let marker = try? strictOperationalDecode(
                WorkspaceHardDeleteMarker.self, record: record
            )
        else { return false }
        guard marker.resourceKey == record.resourceKey, marker.recordType == record.recordType,
            marker.deletedAt == record.tombstone?.deletedAt
        else {
            throw WorkspaceTransferValidationError.tombstoneMetadataMismatch(record.recordType)
        }
        return true
    }

    private static func validateTombstone(_ record: WorkspaceTransferRecord, deletedAt: Date?) throws {
        if hardDeleteRecordTypes.contains(record.recordType) {
            return
        }
        switch (record.tombstone?.deletedAt, deletedAt) {
        case (nil, nil): return
        case let (value?, actual?) where value == actual: return
        default: throw WorkspaceTransferValidationError.tombstoneMetadataMismatch(record.recordType)
        }
    }

    static let hardDeleteRecordTypes: Set<WorkspaceTransferRecordType> = [
        .deviceType, .portTemplate, .moduleTemplate, .device, .module,
        .rackPlacement, .port, .internalLink, .cable, .floorPlanAnchor,
        .workOrder, .reservationLock, .importedHistoricalReference,
    ]

    private static func deletedAt<T>(of value: T) -> Date? {
        switch value {
        case let value as Location: value.deletedAt
        case let value as Rack: value.deletedAt
        default: ipamDeletedAt(of: value)
        }
    }

    private static func ipamDeletedAt<T>(of value: T) -> Date? {
        switch value {
        case let value as VLANGroup: value.tombstonedAt
        case let value as VRF: value.tombstonedAt
        case let value as Prefix: value.tombstonedAt
        case let value as VLAN: value.tombstonedAt
        case let value as Interface: value.tombstonedAt
        case let value as IPAddressAssignment: value.tombstonedAt
        case let value as InterfaceVLANMembership: value.tombstonedAt
        default: nil
        }
    }

    private static func sort(_ lhs: WorkspaceTransferRecord, _ rhs: WorkspaceTransferRecord) -> Bool {
        if lhs.recordType != rhs.recordType { return lhs.recordType.rawValue < rhs.recordType.rawValue }
        return lhs.resourceKey < rhs.resourceKey
    }
}

public struct ValidatedWorkspaceTransfer: Sendable {
    public let candidate: WorkspaceTransferCandidate
    public let saves: [AuthoritativeRecordSave]
    public let tombstones: [AuthoritativeTombstone]

    public init(records: [WorkspaceTransferRecord]) throws {
        let candidate = try WorkspaceTransferCandidate(records: records)
        var saves: [AuthoritativeRecordSave] = []
        var tombstones: [AuthoritativeTombstone] = []
        for record in candidate.records {
            if let marker = record.tombstone {
                tombstones.append(
                    AuthoritativeTombstone(
                        resourceKey: record.resourceKey, recordType: record.recordType.rawValue, deletedAt: marker.deletedAt, encodedTombstone: record.payload))
            } else {
                saves.append(
                    AuthoritativeRecordSave(
                        resourceKey: record.resourceKey, recordType: record.recordType.rawValue, schemaVersion: record.schemaVersion,
                        encodedRecord: record.payload))
            }
        }
        self.candidate = candidate
        self.saves = saves.sorted { $0.resourceKey < $1.resourceKey }
        self.tombstones = tombstones.sorted { $0.resourceKey < $1.resourceKey }
    }

    public static func reconstructAndValidate(imports: [ImportRecord]) throws -> Self {
        try Self(records: WorkspaceTransferRecordReconstruction.records(from: imports))
    }
}
