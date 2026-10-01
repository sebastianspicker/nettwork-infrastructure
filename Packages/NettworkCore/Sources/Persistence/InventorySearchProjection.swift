import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension InventorySearchIndexBuilder {
    struct Projection {
        let topology: PhysicalTopology
        let hierarchy: WorkspaceHierarchy
        let placements: [RackPlacement]
        let addresses: [IPAddressRecord]
        let interfaces: [Interface]
        let workOrders: [WorkOrder]
        let portStateFacts: [ObjectID: PortStateFact]

        init(records: [LocalMirrorRecord]) throws {
            let placementState = try Self.single(
                records, as: TemplatePlacementState.self,
                types: [WorkspaceRecordType.templatePlacementState, WorkspaceRecordType.Legacy.templatePlacementState])
            let topologyAggregate = try Self.latestTopology(records)
            let hierarchyAggregate = try Self.single(
                records, as: WorkspaceHierarchy.self, types: [WorkspaceRecordType.workspaceHierarchy, WorkspaceRecordType.Legacy.workspaceHierarchy])
            let topologySeed = placementState?.topology ?? topologyAggregate ?? PhysicalTopology()
            let hierarchySeed = placementState?.hierarchy ?? hierarchyAggregate ?? WorkspaceHierarchy()
            topology = PhysicalTopology(
                deviceTypes: try Self.overlay(
                    topologySeed.deviceTypes, records: records, as: DeviceType.self,
                    types: [WorkspaceRecordType.deviceType, WorkspaceRecordType.Legacy.deviceType]),
                devices: try Self.overlay(
                    topologySeed.devices, records: records, as: Device.self, types: [WorkspaceRecordType.device, WorkspaceRecordType.Legacy.device]),
                modules: try Self.overlay(
                    topologySeed.modules, records: records, as: Module.self, types: [WorkspaceRecordType.module, WorkspaceRecordType.Legacy.module]),
                ports: try Self.overlay(
                    topologySeed.ports, records: records, as: NetworkModel.Port.self, types: [WorkspaceRecordType.port, WorkspaceRecordType.Legacy.port]),
                cables: try Self.overlay(
                    topologySeed.cables, records: records, as: Cable.self, types: [WorkspaceRecordType.cable, WorkspaceRecordType.Legacy.cable]),
                internalLinks: try Self.overlay(
                    topologySeed.internalLinks, records: records, as: InternalLink.self,
                    types: [WorkspaceRecordType.internalLink, WorkspaceRecordType.Legacy.internalLink]),
                reservations: topologySeed.reservations, plannedWork: topologySeed.plannedWork,
                tombstones: try Self.overlay(
                    topologySeed.tombstones, records: records, as: TopologyTombstone.self,
                    types: [WorkspaceRecordType.topologyTombstone, WorkspaceRecordType.Legacy.topologyTombstone]),
                revision: topologySeed.revision, appliedOperationIDs: topologySeed.appliedOperationIDs)
            hierarchy = WorkspaceHierarchy(
                locations: try Self.overlay(
                    hierarchySeed.locations, records: records, as: Location.self, types: [WorkspaceRecordType.location, WorkspaceRecordType.Legacy.location]),
                racks: try Self.overlay(
                    hierarchySeed.racks, records: records, as: Rack.self, types: [WorkspaceRecordType.rack, WorkspaceRecordType.Legacy.rack]),
                tombstones: try Self.overlay(
                    hierarchySeed.tombstones, records: records, as: HierarchyTombstone.self,
                    types: [WorkspaceRecordType.hierarchyTombstone, WorkspaceRecordType.Legacy.hierarchyTombstone])
            )
            placements = try Self.overlayPlacements(
                placementState?.placements ?? [],
                records: records,
                types: [WorkspaceRecordType.rackPlacement, WorkspaceRecordType.Legacy.rackPlacement]
            )
            addresses = try Self.direct(records, as: IPAddressRecord.self, types: [WorkspaceRecordType.ipAddressRecord], key: { .string($0.id) })
            interfaces = try Self.direct(records, as: Interface.self, types: [WorkspaceRecordType.interface], key: { .object($0.id) })
            workOrders = try Self.direct(
                records, as: WorkOrder.self, types: [WorkspaceRecordType.workOrder, LocalRecordKind.workOrder], key: { .object($0.id) })
            let facts = try Self.direct(
                records,
                as: PortStateFact.self,
                types: [WorkspaceRecordType.inventoryPortStateFact],
                key: { .string(InventorySearchIndexBuilder.portStateFactKey($0.portID)) }
            )
            portStateFacts = Dictionary(facts.map { ($0.portID, $0) }, uniquingKeysWith: { current, _ in current })
            try DefaultTopologyEngine.validate(topology)
            if !hierarchy.locations.isEmpty || !hierarchy.racks.isEmpty || !hierarchy.tombstones.isEmpty { try hierarchy.validate() }
        }

        private static func single<T: Decodable>(_ records: [LocalMirrorRecord], as type: T.Type, types: Set<String>) throws -> T? {
            let matches = records.filter { !$0.isTombstone && types.contains($0.recordType) }
            guard matches.count <= 1 else { throw PersistenceStoreError.malformedStoredValue("ambiguous inventory aggregate") }
            return try matches.first.map { try decode(type, record: $0) }
        }

        private static func latestTopology(_ records: [LocalMirrorRecord]) throws -> PhysicalTopology? {
            let matches = records.filter {
                !$0.isTombstone && [WorkspaceRecordType.physicalTopology, LocalRecordKind.physicalTopology].contains($0.recordType)
            }
            let values = try matches.map { try decode(PhysicalTopology.self, record: $0) }
            return values.max { $0.revision < $1.revision }
        }

        private static func overlay<T: Decodable & Identifiable>(_ seed: [T], records: [LocalMirrorRecord], as type: T.Type, types: Set<String>) throws -> [T]
        where T.ID == ObjectID {
            var values: [ObjectID: T] = [:]
            for value in seed {
                guard values.updateValue(value, forKey: value.id) == nil else {
                    throw PersistenceStoreError.invalidMirrorRecord(.object(value.id))
                }
            }
            var directIDs = Set<ObjectID>()
            for record in records.filter({ types.contains($0.recordType) }).sorted(by: recordOrder) {
                if record.isTombstone {
                    guard case let .object(id) = record.resourceKey,
                        directIDs.insert(id).inserted
                    else {
                        throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey)
                    }
                    values.removeValue(forKey: id)
                    continue
                }
                let value = try decode(type, record: record)
                guard record.resourceKey == .object(value.id), directIDs.insert(value.id).inserted else {
                    throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey)
                }
                values[value.id] = value
            }
            return values.values.sorted { $0.id < $1.id }
        }

        private static func direct<T: Decodable & Identifiable>(_ records: [LocalMirrorRecord], as type: T.Type, types: Set<String>, key: (T) -> ResourceKey)
            throws -> [T] where T.ID: Hashable
        {
            var values: [T.ID: T] = [:]
            for record in records where !record.isTombstone && types.contains(record.recordType) {
                let value = try decode(type, record: record)
                guard record.resourceKey == key(value), values.updateValue(value, forKey: value.id) == nil else {
                    throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey)
                }
            }
            return values.values.sorted { String(describing: $0.id) < String(describing: $1.id) }
        }

        private static func overlayPlacements(
            _ seed: [RackPlacement],
            records: [LocalMirrorRecord],
            types: Set<String>
        ) throws -> [RackPlacement] {
            var values = Dictionary(seed.map { ($0.deviceID, $0) }, uniquingKeysWith: { current, _ in current })
            guard values.count == seed.count else {
                throw PersistenceStoreError.malformedStoredValue("duplicate rack placement seed")
            }
            var directDeviceIDs = Set<ObjectID>()
            for record in records.filter({ types.contains($0.recordType) }).sorted(by: recordOrder) {
                if record.isTombstone {
                    guard let deviceID = rackPlacementDeviceID(from: record.resourceKey),
                        directDeviceIDs.insert(deviceID).inserted
                    else {
                        throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey)
                    }
                    values.removeValue(forKey: deviceID)
                    continue
                }
                let placement = try decode(RackPlacement.self, record: record)
                guard record.resourceKey == .rackPlacement(deviceID: placement.deviceID),
                    directDeviceIDs.insert(placement.deviceID).inserted
                else {
                    throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey)
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

        static func decode<T: Decodable>(_ type: T.Type, record: LocalMirrorRecord) throws -> T {
            guard let payload = record.payload, payload.count <= 1_048_576 else { throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey) }
            do { return try CanonicalJSONCoding.decode(type, from: payload) } catch {
                throw PersistenceStoreError.invalidMirrorRecord(record.resourceKey)
            }
        }

        private static func recordOrder(_ lhs: LocalMirrorRecord, _ rhs: LocalMirrorRecord) -> Bool {
            if lhs.serverModifiedAt != rhs.serverModifiedAt { return lhs.serverModifiedAt < rhs.serverModifiedAt }
            if lhs.resourceKey != rhs.resourceKey { return lhs.resourceKey < rhs.resourceKey }
            return lhs.recordType < rhs.recordType
        }
    }
}
