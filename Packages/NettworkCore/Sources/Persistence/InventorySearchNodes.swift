import Foundation
import NetworkModel
import WorkspaceChangeControl

extension InventorySearchIndexBuilder {
    static func nodeRecord<T: Encodable>(_ key: ResourceKey, _ type: String, _ value: T, namespace: PersistenceNamespace) throws -> LocalMirrorRecord {
        LocalMirrorRecord(
            namespace: namespace, resourceKey: key, recordType: type, schemaVersion: 1, payload: try MirroredAuthoritativeCoding.encode(value),
            systemFields: nil, changeTag: nil, isTombstone: false,
            serverModifiedAt: .distantPast, verifiedAt: .distantPast)
    }

    static func appendTopologyNodes(_ projection: Projection, namespace: PersistenceNamespace, to values: inout [LocalMirrorRecord]) throws {
        try appendObjectNodes(projection.topology.deviceTypes, type: WorkspaceRecordType.deviceType, namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.devices, type: WorkspaceRecordType.device, namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.modules, type: WorkspaceRecordType.module, namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.ports, type: WorkspaceRecordType.port, namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.cables, type: WorkspaceRecordType.cable, namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.internalLinks, type: WorkspaceRecordType.internalLink, namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.tombstones, type: WorkspaceRecordType.topologyTombstone, namespace: namespace, to: &values)
    }

    static func appendHierarchyNodes(_ projection: Projection, namespace: PersistenceNamespace, to values: inout [LocalMirrorRecord]) throws {
        try appendObjectNodes(projection.hierarchy.locations, type: WorkspaceRecordType.location, namespace: namespace, to: &values)
        try appendObjectNodes(projection.hierarchy.racks, type: WorkspaceRecordType.rack, namespace: namespace, to: &values)
        try appendObjectNodes(projection.hierarchy.tombstones, type: WorkspaceRecordType.hierarchyTombstone, namespace: namespace, to: &values)
        for value in projection.placements {
            values.append(try nodeRecord(.rackPlacement(deviceID: value.deviceID), WorkspaceRecordType.rackPlacement, value, namespace: namespace))
        }
    }

    static func appendSupplementalNodes(_ projection: Projection, namespace: PersistenceNamespace, to values: inout [LocalMirrorRecord]) throws {
        try appendObjectNodes(projection.interfaces, type: WorkspaceRecordType.interface, namespace: namespace, to: &values)
        for value in projection.addresses { values.append(try nodeRecord(.string(value.id), WorkspaceRecordType.ipAddressRecord, value, namespace: namespace)) }
        try appendObjectNodes(projection.workOrders, type: WorkspaceRecordType.workOrder, namespace: namespace, to: &values)
    }

    static func appendObjectNodes<T: Encodable & Identifiable>(
        _ nodes: [T], type: String, namespace: PersistenceNamespace, to values: inout [LocalMirrorRecord]
    ) throws where T.ID == ObjectID {
        for value in nodes { values.append(try nodeRecord(.object(value.id), type, value, namespace: namespace)) }
    }

    static func appendPortStateNodes(_ projection: Projection, namespace: PersistenceNamespace, to values: inout [LocalMirrorRecord]) throws {
        let reserved = Set(projection.topology.reservations.flatMap(\.portIDs))
        let planned = Set(projection.topology.plannedWork.flatMap(\.portIDs))
        for port in projection.topology.ports {
            let fact = PortStateFact(portID: port.id, isReserved: reserved.contains(port.id), isPlanned: planned.contains(port.id))
            values.append(try nodeRecord(.string(portStateFactKey(port.id)), WorkspaceRecordType.inventoryPortStateFact, fact, namespace: namespace))
        }
    }
}
