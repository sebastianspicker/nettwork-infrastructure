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
        try appendObjectNodes(projection.topology.deviceTypes, type: "NettworkDeviceType", namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.devices, type: "NettworkDevice", namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.modules, type: "NettworkModule", namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.ports, type: "NettworkPort", namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.cables, type: "NettworkCable", namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.internalLinks, type: "NettworkInternalLink", namespace: namespace, to: &values)
        try appendObjectNodes(projection.topology.tombstones, type: "NettworkTopologyTombstone", namespace: namespace, to: &values)
    }

    static func appendHierarchyNodes(_ projection: Projection, namespace: PersistenceNamespace, to values: inout [LocalMirrorRecord]) throws {
        try appendObjectNodes(projection.hierarchy.locations, type: "NettworkLocation", namespace: namespace, to: &values)
        try appendObjectNodes(projection.hierarchy.racks, type: "NettworkRack", namespace: namespace, to: &values)
        try appendObjectNodes(projection.hierarchy.tombstones, type: "NettworkHierarchyTombstone", namespace: namespace, to: &values)
        for value in projection.placements {
            values.append(try nodeRecord(.rackPlacement(deviceID: value.deviceID), "NettworkRackPlacement", value, namespace: namespace))
        }
    }

    static func appendSupplementalNodes(_ projection: Projection, namespace: PersistenceNamespace, to values: inout [LocalMirrorRecord]) throws {
        try appendObjectNodes(projection.interfaces, type: "NettworkInterface", namespace: namespace, to: &values)
        for value in projection.addresses { values.append(try nodeRecord(.string(value.id), "NettworkIPAddressRecord", value, namespace: namespace)) }
        try appendObjectNodes(projection.workOrders, type: "NettworkWorkOrder", namespace: namespace, to: &values)
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
            values.append(try nodeRecord(.string(portStateFactKey(port.id)), "NettworkInventoryPortStateFact", fact, namespace: namespace))
        }
    }
}
