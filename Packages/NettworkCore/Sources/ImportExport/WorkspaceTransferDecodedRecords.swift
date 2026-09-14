import Foundation
import NetworkModel
import WorkspaceChangeControl

struct WorkspaceTransferDecodedRecords {
    var locations: [Location] = []
    var racks: [Rack] = []
    var deviceTypes: [DeviceType] = []
    var portTemplates: [PortTemplate] = []
    var moduleTemplates: [ModuleTemplate] = []
    var devices: [Device] = []
    var modules: [Module] = []
    var placements: [RackPlacement] = []
    var ports: [NetworkModel.Port] = []
    var links: [InternalLink] = []
    var cables: [Cable] = []
    var anchors: [FloorPlanAnchor] = []
    var vrfs: [VRF] = []
    var prefixes: [Prefix] = []
    var addresses: [IPAddressRecord] = []
    var vlanGroups: [VLANGroup] = []
    var vlans: [VLAN] = []
    var interfaces: [Interface] = []
    var assignments: [IPAddressAssignment] = []
    var memberships: [InterfaceVLANMembership] = []
    var workOrders: [WorkOrder] = []
    var reservationLocks: [ResourceReservationLock] = []
    var releasedReservationLocks: [ResourceReservationLock] = []
    var receipts: [OperationReceipt] = []
    var quotaLedgers: [AttachmentEvidenceQuotaLedger] = []
    var reservationReleases: [AttachmentEvidenceReservationRelease] = []
    var bindings: [AttachmentEvidenceBindingRecord] = []
    var floorPlanBindings: [FloorPlanAssetBindingRecord] = []
    var historicalReferences: [WorkspaceImportedHistoricalReference] = []

    init(records: [WorkspaceTransferRecord]) throws {
        for record in records {
            try consume(record)
        }
    }

    private mutating func consume(_ record: WorkspaceTransferRecord) throws {
        guard record.schemaVersion == WorkspaceTransferRecord.currentSchemaVersion else {
            throw WorkspaceTransferRecordError.unsupportedSchemaVersion(record.schemaVersion)
        }
        if record.tombstone != nil,
            WorkspaceTransferCandidate.hardDeleteRecordTypes.contains(record.recordType),
            try WorkspaceTransferCandidate.validateHardDeleteMarkerIfPresent(record)
        {
            return
        }
        if Self.foundationTypes.contains(record.recordType) {
            try consumeFoundation(record)
        } else if Self.infrastructureTypes.contains(record.recordType) {
            try consumeInfrastructure(record)
        } else if Self.topologyTypes.contains(record.recordType) {
            try consumeTopology(record)
        } else if Self.ipamTypes.contains(record.recordType) {
            try consumeIPAM(record)
        } else if Self.operationalTypes.contains(record.recordType) {
            try consumeOperational(record)
        } else {
            try consumeEvidence(record)
        }
    }

    private mutating func consumeFoundation(_ record: WorkspaceTransferRecord) throws {
        switch record.recordType {
        case .location:
            locations.append(try WorkspaceTransferCandidate.decode(Location.self, record: record, key: ResourceKey.object))
        case .rack:
            racks.append(try WorkspaceTransferCandidate.decode(Rack.self, record: record, key: ResourceKey.object))
        case .deviceType:
            Self.appendLive(try WorkspaceTransferCandidate.decode(DeviceType.self, record: record, key: ResourceKey.object), record: record, to: &deviceTypes)
        case .portTemplate:
            Self.appendLive(
                try WorkspaceTransferCandidate.decode(PortTemplate.self, record: record, key: ResourceKey.object), record: record, to: &portTemplates)
        case .moduleTemplate:
            Self.appendLive(
                try WorkspaceTransferCandidate.decode(ModuleTemplate.self, record: record, key: ResourceKey.object), record: record, to: &moduleTemplates)
        default:
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
    }

    private mutating func consumeInfrastructure(_ record: WorkspaceTransferRecord) throws {
        switch record.recordType {
        case .device:
            Self.appendLive(try WorkspaceTransferCandidate.decode(Device.self, record: record, key: ResourceKey.object), record: record, to: &devices)
        case .module:
            Self.appendLive(try WorkspaceTransferCandidate.decode(Module.self, record: record, key: ResourceKey.object), record: record, to: &modules)
        case .rackPlacement:
            Self.appendLive(try WorkspaceTransferCandidate.decodeRackPlacement(record), record: record, to: &placements)
        case .floorPlanAnchor:
            Self.appendLive(try WorkspaceTransferCandidate.decode(FloorPlanAnchor.self, record: record, key: ResourceKey.object), record: record, to: &anchors)
        default:
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
    }

    private mutating func consumeTopology(_ record: WorkspaceTransferRecord) throws {
        switch record.recordType {
        case .port:
            Self.appendLive(try WorkspaceTransferCandidate.decode(NetworkModel.Port.self, record: record, key: ResourceKey.object), record: record, to: &ports)
        case .internalLink:
            Self.appendLive(try WorkspaceTransferCandidate.decode(InternalLink.self, record: record, key: ResourceKey.object), record: record, to: &links)
        case .cable:
            Self.appendLive(try WorkspaceTransferCandidate.decode(Cable.self, record: record, key: ResourceKey.object), record: record, to: &cables)
        default:
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
    }

    private mutating func consumeIPAM(_ record: WorkspaceTransferRecord) throws {
        switch record.recordType {
        case .vrf: vrfs.append(try WorkspaceTransferCandidate.decode(VRF.self, record: record, key: ResourceKey.object))
        case .prefix: prefixes.append(try WorkspaceTransferCandidate.decode(Prefix.self, record: record, key: ResourceKey.object))
        case .address: addresses.append(try WorkspaceTransferCandidate.decodeAddress(record))
        case .vlanGroup: vlanGroups.append(try WorkspaceTransferCandidate.decode(VLANGroup.self, record: record, key: ResourceKey.object))
        case .vlan: vlans.append(try WorkspaceTransferCandidate.decode(VLAN.self, record: record, key: ResourceKey.object))
        case .interface: interfaces.append(try WorkspaceTransferCandidate.decode(Interface.self, record: record, key: ResourceKey.object))
        case .assignment: assignments.append(try WorkspaceTransferCandidate.decode(IPAddressAssignment.self, record: record, key: ResourceKey.object))
        case .membership: memberships.append(try WorkspaceTransferCandidate.decode(InterfaceVLANMembership.self, record: record, key: ResourceKey.object))
        default: throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
    }

    private mutating func consumeOperational(_ record: WorkspaceTransferRecord) throws {
        switch record.recordType {
        case .workOrder:
            Self.appendLive(try WorkspaceTransferCandidate.decodeOperationalWorkOrder(record), record: record, to: &workOrders)
        case .reservationLock:
            let lock = try WorkspaceTransferCandidate.decodeOperationalReservationLock(record)
            if record.tombstone == nil { reservationLocks.append(lock) } else { releasedReservationLocks.append(lock) }
        case .operationReceipt:
            receipts.append(try WorkspaceTransferCandidate.decodeOperationalReceipt(record))
        case .attachmentEvidenceQuotaLedger:
            quotaLedgers.append(try WorkspaceTransferCandidate.decodeOperationalQuotaLedger(record))
        default:
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
    }

    private mutating func consumeEvidence(_ record: WorkspaceTransferRecord) throws {
        switch record.recordType {
        case .attachmentEvidenceReservationRelease:
            reservationReleases.append(try WorkspaceTransferCandidate.decodeOperationalReservationRelease(record))
        case .attachmentEvidenceBinding:
            bindings.append(try WorkspaceTransferCandidate.decodeOperationalBinding(record))
        case .floorPlanAssetBinding:
            floorPlanBindings.append(try WorkspaceTransferCandidate.decodeFloorPlanAssetBinding(record))
        case .importedHistoricalReference:
            historicalReferences.append(try WorkspaceTransferCandidate.decodeImportedHistoricalReference(record))
        default:
            throw WorkspaceTransferValidationError.malformedPayload(record.recordType)
        }
    }

    private static func appendLive<T>(_ value: T, record: WorkspaceTransferRecord, to values: inout [T]) {
        if record.tombstone == nil { values.append(value) }
    }

    private static let foundationTypes: Set<WorkspaceTransferRecordType> = [
        .location, .rack, .deviceType, .portTemplate, .moduleTemplate,
    ]
    private static let infrastructureTypes: Set<WorkspaceTransferRecordType> = [
        .device, .module, .rackPlacement, .floorPlanAnchor,
    ]
    private static let topologyTypes: Set<WorkspaceTransferRecordType> = [
        .port, .internalLink, .cable,
    ]
    private static let ipamTypes: Set<WorkspaceTransferRecordType> = [
        .vrf, .prefix, .address, .vlanGroup, .vlan, .interface, .assignment, .membership,
    ]
    private static let operationalTypes: Set<WorkspaceTransferRecordType> = [
        .workOrder, .reservationLock, .operationReceipt, .attachmentEvidenceQuotaLedger,
    ]
}
