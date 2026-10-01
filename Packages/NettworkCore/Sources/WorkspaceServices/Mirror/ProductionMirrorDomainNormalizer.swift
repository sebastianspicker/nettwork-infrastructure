import CloudSync
import CryptoKit
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

enum ProductionMirrorDomainNormalizationError: Error, Hashable, Sendable {
    case ambiguousAggregate(String)
    case incompletePlacementProjection
    case malformedRecord(ResourceKey)
    case resourceKeyMismatch(ResourceKey)
}

/// Converts legacy aggregate snapshots plus the canonical per-record mirror
/// into one projection. Aggregate values are migration seeds only: every
/// direct save or tombstone overlays that seed, so accepted modern mutations
/// cannot be hidden by an older aggregate record.
struct ProductionMirrorDomainProjection: Sendable {
    let topology: PhysicalTopology
    let hierarchy: WorkspaceHierarchy
    let placements: [RackPlacement]
    let rackReservations: [RackPlacementReservation]
    let anchors: [FloorPlanAnchor]
    let moduleTemplates: [ModuleTemplate]

    init(records: [LocalMirrorRecord]) throws {
        let seeds = try Self.seeds(from: records)
        topology = try Self.topology(from: records, seed: seeds.topology)
        hierarchy = try Self.hierarchy(from: records, seed: seeds.hierarchy)
        placements = try Self.overlayPlacements(
            seeds.placement?.placements ?? [], from: records, recordTypes: [WorkspaceRecordType.rackPlacement, WorkspaceRecordType.Legacy.rackPlacement])
        rackReservations = seeds.placement?.rackReservations ?? []
        anchors = try Self.overlay(
            seeds.placement?.anchors ?? [], from: records, as: FloorPlanAnchor.self,
            recordTypes: [WorkspaceRecordType.floorPlanAnchor, WorkspaceRecordType.Legacy.floorPlanAnchor])
        moduleTemplates = try Self.overlay(
            [], from: records, as: ModuleTemplate.self, recordTypes: [WorkspaceRecordType.moduleTemplate, WorkspaceRecordType.Legacy.moduleTemplate])
        try Self.validate(topology: topology, hierarchy: hierarchy, placements: placements, reservations: rackReservations, anchors: anchors)
    }

    private struct Seeds {
        let placement: TemplatePlacementState?
        let topology: PhysicalTopology
        let hierarchy: WorkspaceHierarchy
    }

    private static func seeds(from records: [LocalMirrorRecord]) throws -> Seeds {
        let placement = try singleAggregate(
            records, as: TemplatePlacementState.self,
            recordTypes: [WorkspaceRecordType.templatePlacementState, WorkspaceRecordType.Legacy.templatePlacementState])
        let topologyAggregate = try latestTopologyAggregate(records)
        let hierarchyAggregate = try singleAggregate(
            records, as: WorkspaceHierarchy.self, recordTypes: [WorkspaceRecordType.workspaceHierarchy, WorkspaceRecordType.Legacy.workspaceHierarchy])
        return Seeds(
            placement: placement, topology: placement?.topology ?? topologyAggregate ?? PhysicalTopology(),
            hierarchy: placement?.hierarchy ?? hierarchyAggregate ?? WorkspaceHierarchy())
    }

    private static func topology(from records: [LocalMirrorRecord], seed: PhysicalTopology) throws -> PhysicalTopology {
        PhysicalTopology(
            deviceTypes: try overlay(
                seed.deviceTypes, from: records, as: DeviceType.self, recordTypes: [WorkspaceRecordType.deviceType, WorkspaceRecordType.Legacy.deviceType]),
            devices: try overlay(seed.devices, from: records, as: Device.self, recordTypes: [WorkspaceRecordType.device, WorkspaceRecordType.Legacy.device]),
            modules: try overlay(seed.modules, from: records, as: Module.self, recordTypes: [WorkspaceRecordType.module, WorkspaceRecordType.Legacy.module]),
            ports: try overlay(seed.ports, from: records, as: Port.self, recordTypes: [WorkspaceRecordType.port, WorkspaceRecordType.Legacy.port]),
            cables: try overlay(seed.cables, from: records, as: Cable.self, recordTypes: [WorkspaceRecordType.cable, WorkspaceRecordType.Legacy.cable]),
            internalLinks: try overlay(
                seed.internalLinks, from: records, as: InternalLink.self,
                recordTypes: [WorkspaceRecordType.internalLink, WorkspaceRecordType.Legacy.internalLink]),
            reservations: seed.reservations,
            plannedWork: seed.plannedWork,
            tombstones: try overlay(
                seed.tombstones, from: records, as: TopologyTombstone.self,
                recordTypes: [
                    WorkspaceRecordType.topologyTombstone,
                    WorkspaceRecordType.Legacy.topologyTombstone,
                ]),
            revision: projectionRevision(seed: seed.revision, records: records),
            appliedOperationIDs: seed.appliedOperationIDs
        )
    }

    private static func hierarchy(from records: [LocalMirrorRecord], seed: WorkspaceHierarchy) throws -> WorkspaceHierarchy {
        WorkspaceHierarchy(
            locations: try overlay(
                seed.locations, from: records, as: Location.self, recordTypes: [WorkspaceRecordType.location, WorkspaceRecordType.Legacy.location]),
            racks: try overlay(seed.racks, from: records, as: Rack.self, recordTypes: [WorkspaceRecordType.rack, WorkspaceRecordType.Legacy.rack]),
            tombstones: try overlay(
                seed.tombstones, from: records, as: HierarchyTombstone.self,
                recordTypes: [WorkspaceRecordType.hierarchyTombstone, WorkspaceRecordType.Legacy.hierarchyTombstone])
        )
    }

    private static func validate(
        topology: PhysicalTopology, hierarchy: WorkspaceHierarchy, placements: [RackPlacement], reservations: [RackPlacementReservation],
        anchors: [FloorPlanAnchor]
    ) throws {
        try DefaultTopologyEngine.validate(topology)
        if !hierarchy.locations.isEmpty || !hierarchy.racks.isEmpty || !hierarchy.tombstones.isEmpty {
            try hierarchy.validate()
            try TemplatePlacementState(
                hierarchy: hierarchy, topology: topology, placements: placements, rackReservations: reservations,
                anchors: anchors
            ).validate()
        } else if !placements.isEmpty || !reservations.isEmpty || !anchors.isEmpty {
            throw ProductionMirrorDomainNormalizationError.incompletePlacementProjection
        }
    }

    private static func singleAggregate<T: Decodable>(_ records: [LocalMirrorRecord], as type: T.Type, recordTypes: Set<String>) throws -> T? {
        let matches = records.filter { !$0.isTombstone && recordTypes.contains($0.recordType) }
        guard matches.count <= 1 else {
            throw ProductionMirrorDomainNormalizationError.ambiguousAggregate(recordTypes.sorted().joined(separator: ","))
        }
        guard let record = matches.first else { return nil }
        return try decode(type, from: record)
    }

    private static func latestTopologyAggregate(_ records: [LocalMirrorRecord]) throws -> PhysicalTopology? {
        let matches = records.filter {
            !$0.isTombstone && [WorkspaceRecordType.physicalTopology, LocalRecordKind.physicalTopology].contains($0.recordType)
        }
        let values = try matches.map { try decode(PhysicalTopology.self, from: $0) }
        return values.max { $0.revision < $1.revision }
    }

    private static func overlay<T: Decodable & Identifiable>(
        _ seed: [T], from records: [LocalMirrorRecord], as type: T.Type, recordTypes: Set<String>
    ) throws -> [T] where T.ID == ObjectID {
        var values: [ObjectID: T] = [:]
        for value in seed {
            guard values.updateValue(value, forKey: value.id) == nil else {
                throw ProductionMirrorDomainNormalizationError.resourceKeyMismatch(.object(value.id))
            }
        }
        var directIDs = Set<ObjectID>()
        for record
            in records
            .filter({ recordTypes.contains($0.recordType) })
            .sorted(by: Self.recordOrder)
        {
            if record.isTombstone {
                guard case let .object(id) = record.resourceKey,
                    directIDs.insert(id).inserted
                else {
                    throw ProductionMirrorDomainNormalizationError.resourceKeyMismatch(record.resourceKey)
                }
                values.removeValue(forKey: id)
                continue
            }
            let value = try decode(type, from: record)
            guard record.resourceKey == .object(value.id) else {
                throw ProductionMirrorDomainNormalizationError.resourceKeyMismatch(record.resourceKey)
            }
            guard directIDs.insert(value.id).inserted else {
                throw ProductionMirrorDomainNormalizationError.resourceKeyMismatch(record.resourceKey)
            }
            values[value.id] = value
        }
        return values.values.sorted { $0.id < $1.id }
    }

    private static func overlayPlacements(_ seed: [RackPlacement], from records: [LocalMirrorRecord], recordTypes: Set<String>) throws -> [RackPlacement] {
        var values = [ObjectID: RackPlacement]()
        for placement in seed {
            guard values.updateValue(placement, forKey: placement.deviceID) == nil else {
                throw ProductionMirrorDomainNormalizationError.resourceKeyMismatch(
                    .rackPlacement(deviceID: placement.deviceID)
                )
            }
        }
        var directDeviceIDs = Set<ObjectID>()
        for record
            in records
            .filter({ recordTypes.contains($0.recordType) })
            .sorted(by: Self.recordOrder)
        {
            if record.isTombstone {
                guard let deviceID = rackPlacementDeviceID(from: record.resourceKey),
                    directDeviceIDs.insert(deviceID).inserted
                else {
                    throw ProductionMirrorDomainNormalizationError.resourceKeyMismatch(record.resourceKey)
                }
                values.removeValue(forKey: deviceID)
                continue
            }
            let placement = try decode(RackPlacement.self, from: record)
            let key = ResourceKey.rackPlacement(deviceID: placement.deviceID)
            guard record.resourceKey == key,
                directDeviceIDs.insert(placement.deviceID).inserted
            else {
                throw ProductionMirrorDomainNormalizationError.resourceKeyMismatch(record.resourceKey)
            }
            values[placement.deviceID] = placement
        }
        return values.values.sorted { $0.deviceID < $1.deviceID }
    }

    private static func rackPlacementDeviceID(from resourceKey: ResourceKey) -> ObjectID? {
        guard case let .string(value) = resourceKey else { return nil }
        let prefix = "rack-placement:"
        guard value.hasPrefix(prefix) else { return nil }
        let rawID = String(value.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: rawID),
            uuid.uuidString.lowercased() == rawID
        else { return nil }
        return ObjectID(uuid)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from record: LocalMirrorRecord) throws -> T {
        guard let payload = record.payload,
            payload.count <= 1_048_576,
            let value = try? CloudDeterministicCoding.decode(type, from: payload)
        else {
            throw ProductionMirrorDomainNormalizationError.malformedRecord(record.resourceKey)
        }
        return value
    }

    private static func recordOrder(_ lhs: LocalMirrorRecord, _ rhs: LocalMirrorRecord) -> Bool {
        if lhs.serverModifiedAt != rhs.serverModifiedAt { return lhs.serverModifiedAt < rhs.serverModifiedAt }
        if lhs.resourceKey != rhs.resourceKey { return lhs.resourceKey < rhs.resourceKey }
        return lhs.recordType < rhs.recordType
    }

    private static func projectionRevision(seed: Int, records: [LocalMirrorRecord]) -> Int {
        var data = Data("nettwork.production-mirror-projection.v1".utf8)
        for record in records.sorted(by: recordOrder) {
            data.append(0)
            data.append(Data(record.recordType.utf8))
            data.append(0)
            data.append((try? CloudDeterministicCoding.encode(record.resourceKey)) ?? Data())
            data.append(record.isTombstone ? 1 : 0)
            data.append(record.payload ?? Data())
        }
        let digest = SHA256.hash(data: data)
        let fingerprint = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return max(seed, Int(fingerprint & UInt64(Int.max >> 1)))
    }
}
