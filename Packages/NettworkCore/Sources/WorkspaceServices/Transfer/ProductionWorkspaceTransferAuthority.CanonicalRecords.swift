import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func validateCanonicalProjection(_ projection: ProductionMirrorDomainProjection) throws {
        guard projection.topology.reservations.isEmpty,
            projection.topology.plannedWork.isEmpty,
            projection.rackReservations.isEmpty
        else {
            // These legacy aggregate-only values have no lossless canonical
            // transfer record. Refuse export instead of silently discarding
            // exclusion state.
            throw ProductionWorkspaceTransferAuthorityError.legacyAggregateRequiresMigration
        }
    }

    func canonicalRetainedRecords(from records: [LocalMirrorRecord]) -> [LocalMirrorRecord] {
        let canonicalTypes: Set<WorkspaceTransferRecordType> = [
            .location, .rack, .deviceType, .moduleTemplate, .device, .module,
            .rackPlacement, .port, .internalLink, .cable, .floorPlanAnchor,
        ]
        return records.filter { record in
            guard let type = transferRecordType(for: record.recordType) else {
                return !isExplicitlyOmittedMirrorRecordType(record.recordType)
            }
            return !canonicalTypes.contains(type) || record.isTombstone
        }
    }

    func appendCanonicalProjection(_ projection: ProductionMirrorDomainProjection, to transfer: inout [WorkspaceTransferRecord]) throws {
        try appendCanonicalRecords(projection.hierarchy.locations, type: .location, to: &transfer, deletedAt: { $0.deletedAt })
        try appendCanonicalRecords(projection.hierarchy.racks, type: .rack, to: &transfer, deletedAt: { $0.deletedAt })
        try appendCanonicalRecords(projection.topology.deviceTypes, type: .deviceType, to: &transfer)
        try appendCanonicalRecords(projection.moduleTemplates, type: .moduleTemplate, to: &transfer)
        try appendCanonicalRecords(projection.topology.devices, type: .device, to: &transfer)
        try appendCanonicalRecords(projection.topology.modules, type: .module, to: &transfer)
        try appendCanonicalPlacements(projection.placements, to: &transfer)
        try appendCanonicalRecords(projection.topology.ports, type: .port, to: &transfer)
        try appendCanonicalRecords(projection.topology.internalLinks, type: .internalLink, to: &transfer)
        try appendCanonicalRecords(projection.topology.cables, type: .cable, to: &transfer)
        try appendCanonicalRecords(projection.anchors, type: .floorPlanAnchor, to: &transfer)
    }

    func appendCanonicalRecords<T: Encodable & Identifiable>(
        _ values: [T],
        type: WorkspaceTransferRecordType,
        to transfer: inout [WorkspaceTransferRecord],
        deletedAt: (T) -> Date? = { _ in nil }
    ) throws where T.ID == ObjectID {
        for value in values {
            transfer.append(
                WorkspaceTransferRecord(
                    resourceKey: .object(value.id),
                    recordType: type,
                    payload: try WorkspaceTransferCoding.encode(value),
                    tombstone: deletedAt(value).map(WorkspaceTransferTombstone.init(deletedAt:))
                ))
        }
    }

    func appendCanonicalPlacements(_ placements: [RackPlacement], to transfer: inout [WorkspaceTransferRecord]) throws {
        for placement in placements {
            transfer.append(
                WorkspaceTransferRecord(
                    resourceKey: .rackPlacement(deviceID: placement.deviceID),
                    recordType: .rackPlacement,
                    payload: try WorkspaceTransferCoding.encode(placement)
                ))
        }
    }

    func validateCanonicalTombstones(_ projection: ProductionMirrorDomainProjection, retainedRecords: [LocalMirrorRecord]) throws {
        let retained = Dictionary(grouping: retainedRecords.filter(\.isTombstone), by: \.resourceKey)
        try validateTopologyTombstones(projection.topology.tombstones, retained: retained)
        try validateHierarchyTombstones(projection.hierarchy.tombstones, retained: retained)
    }

    func validateTopologyTombstones(_ tombstones: [TopologyTombstone], retained: [ResourceKey: [LocalMirrorRecord]]) throws {
        for tombstone in tombstones {
            try requireRetainedTombstone(
                resourceKey: .object(tombstone.id),
                type: Self.transferType(for: tombstone.kind),
                retained: retained
            )
        }
    }

    func validateHierarchyTombstones(_ tombstones: [HierarchyTombstone], retained: [ResourceKey: [LocalMirrorRecord]]) throws {
        for tombstone in tombstones {
            try requireRetainedTombstone(
                resourceKey: .object(tombstone.id),
                type: Self.transferType(for: tombstone.kind),
                retained: retained
            )
        }
    }

    func requireRetainedTombstone(resourceKey: ResourceKey, type: WorkspaceTransferRecordType, retained: [ResourceKey: [LocalMirrorRecord]]) throws {
        guard
            retained[resourceKey]?.contains(where: {
                transferRecordType(for: $0.recordType) == type
            }) == true
        else {
            throw ProductionWorkspaceTransferAuthorityError.legacyAggregateRequiresMigration
        }
    }

    func sortedUniqueTransferRecords(_ transfer: [WorkspaceTransferRecord]) throws -> [WorkspaceTransferRecord] {
        let sorted = transfer.sorted(by: transferLess)
        guard Set(sorted.map(\.resourceKey)).count == sorted.count else {
            throw ProductionWorkspaceTransferAuthorityError.duplicateActivationResource(
                sorted.first?.resourceKey ?? .string("archive-transfer")
            )
        }
        return sorted
    }

    static func transferType(for kind: TopologyObjectKind) -> WorkspaceTransferRecordType {
        switch kind {
        case .device: .device
        case .module: .module
        case .port: .port
        case .cable: .cable
        case .internalLink: .internalLink
        }
    }

    static func transferType(for kind: HierarchyObjectKind) -> WorkspaceTransferRecordType {
        switch kind {
        case .workspace, .site, .building, .floor, .room, .unrackedArea: .location
        case .rack: .rack
        }
    }

    func transferLess(_ lhs: WorkspaceTransferRecord, _ rhs: WorkspaceTransferRecord) -> Bool {
        lhs.recordType == rhs.recordType ? lhs.resourceKey < rhs.resourceKey : lhs.recordType.rawValue < rhs.recordType.rawValue
    }
}
