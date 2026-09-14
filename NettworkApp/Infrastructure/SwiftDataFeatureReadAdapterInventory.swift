import CloudSync
import ContentSafety
import CryptoKit
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataFeatureReadAdapter {
    func search(_ query: InventorySearchQuery, in namespace: PersistenceNamespace) async throws -> [InventorySearchResult] {
        try await operationBoundary.perform(.search, outputRecordCount: { $0.count }) {
            try await self.performSearch(query, in: namespace)
        }
    }

    private func performSearch(_ query: InventorySearchQuery, in namespace: PersistenceNamespace) async throws -> [InventorySearchResult] {
        guard namespace == account.namespace else { throw ProductionAdapterError.namespaceMismatch }
        let maximum = min(max(query.maximumResults, 1), 50)
        try Task.checkCancellation()
        let records = try await persistence.inventorySearchRecords(
            in: namespace,
            kinds: Set(query.kinds.map(\.rawValue)),
            siteID: query.siteID,
            text: query.text,
            limit: maximum
        )
        try Task.checkCancellation()
        let conflictKeys = try await persistence.unresolvedConflictResourceKeys(in: namespace)
        try Task.checkCancellation()
        return try records.map { record in
            guard let kind = InventoryObjectKind(rawValue: record.kind) else {
                throw ProductionAdapterError.malformedAuthoritativeMirrorRecord(record.resourceKey, "inventory-search-index")
            }
            return InventorySearchResult(
                id: record.objectID,
                kind: kind,
                title: record.title,
                subtitle: record.subtitle,
                siteName: record.siteName,
                searchTerms: record.searchTerms,
                isTombstoned: false,
                isPending: record.isPending,
                isConflicted: conflictKeys.contains(record.resourceKey)
            )
        }
    }

    func siteOptions(in namespace: PersistenceNamespace) async throws -> [InventorySiteOption] {
        let projection = try await readProjection(in: namespace)
        return projection.hierarchy.locations
            .filter { $0.kind == .site && $0.deletedAt == nil }
            .map { InventorySiteOption(id: $0.id, title: $0.name) }
            .sorted { lexicalLess([$0.title, $0.id.description], [$1.title, $1.id.description]) }
    }

    func details(for id: ObjectID, in namespace: PersistenceNamespace) async throws -> InventoryObjectDetails? {
        let projection = try await readProjection(in: namespace)
        guard let result = activeInventoryResult(id, in: projection) else { return nil }
        return inventoryDetails(for: result, in: projection)
    }

    func results(for ids: [ObjectID], in namespace: PersistenceNamespace) async throws -> [InventorySearchResult] {
        guard namespace == account.namespace else { throw ProductionAdapterError.namespaceMismatch }
        let projection = try await readProjection(in: namespace)
        let activeRows = projection.inventoryResults.filter { !$0.isTombstoned }
        let rowsByID = Dictionary(activeRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<ObjectID>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return rowsByID[id]
        }
    }

    private func inventoryDetails(for result: InventorySearchResult, in projection: MirrorProjection) -> InventoryObjectDetails {
        return InventoryObjectDetails(
            result: result,
            containment: projection.containment(for: result.id),
            connectivitySummary: projection.connectivitySummary(for: result.id),
            traceSummary: projection.traceSummary(for: result.id),
            logicalContext: projection.logicalContext(for: result.id),
            reservationSummary: projection.reservationSummary(for: result.id),
            pendingSummary: pendingSummary(for: result),
            recentAuditSummary: recentAuditSummary(for: result.id, in: projection),
            attachmentCount: projection.attachmentCount(for: result.id)
        )
    }

    private func activeInventoryResult(_ id: ObjectID, in projection: MirrorProjection) -> InventorySearchResult? {
        for result in projection.inventoryResults where result.id == id && !result.isTombstoned {
            return result
        }
        return nil
    }

    private func pendingSummary(for result: InventorySearchResult) -> String? {
        guard result.isPending else { return nil }
        return "Planned or reserved work is present in the local mirror."
    }

    private func recentAuditSummary(for id: ObjectID, in projection: MirrorProjection) -> [String] {
        projection.audits
            .filter { audit in
                audit.affectedObjectIDs.contains(id) || audit.affectedResourceKeys.contains(.object(id))
            }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(10)
            .map { "\($0.occurredAt.formatted()) · \($0.result.rawValue) · \($0.actorID)" }
    }

    func hierarchy(in namespace: PersistenceNamespace) async throws -> [TopologyHierarchyNode] {
        let projection = try await readProjection(in: namespace)
        let locations = projection.hierarchy.locations.filter { $0.deletedAt == nil }
        let racks = projection.hierarchy.racks.filter { $0.deletedAt == nil }
        let devices = projection.topology.devices
        let modules = projection.topology.modules
        let ports = projection.topology.ports
        let indexes = try TopologyBrowseIndexes(
            locations: locations, racks: racks, devices: devices, modules: modules, ports: ports, cables: projection.topology.cables,
            reservations: projection.topology.reservations, placements: projection.placements, rackReservations: projection.rackReservations
        )
        var nodes = [TopologyHierarchyNode]()
        nodes += try locationNodes(locations, indexes: indexes)
        nodes += try rackNodes(racks, indexes: indexes)
        nodes += try deviceNodes(devices, indexes: indexes)
        nodes += try moduleNodes(modules, indexes: indexes)
        nodes += try portNodes(ports)
        return
            nodes
            .sorted { lexicalLess([$0.name, $0.id.description], [$1.name, $1.id.description]) }
    }

    private func locationNodes(_ values: [Location], indexes: TopologyBrowseIndexes) throws -> [TopologyHierarchyNode] {
        try values.enumerated().map { offset, value in
            try Self.checkCancellation(at: offset)
            return TopologyHierarchyNode(
                id: value.id,
                parentID: value.parentID,
                kind: .location(value.kind),
                name: value.name,
                detail: value.kind.rawValue,
                childCount: indexes.locationChildCount[value.id, default: 0] + indexes.rackCountByLocation[value.id, default: 0],
                location: value,
                rack: nil
            )
        }
    }

    private func rackNodes(_ values: [Rack], indexes: TopologyBrowseIndexes) throws -> [TopologyHierarchyNode] {
        try values.enumerated().map { offset, value in
            try Self.checkCancellation(at: offset)
            return TopologyHierarchyNode(
                id: value.id,
                parentID: value.locationID,
                kind: .rack,
                name: value.assetCode.value,
                detail: "\(value.heightRU) RU",
                childCount: indexes.deviceCountByRack[value.id, default: 0],
                location: nil,
                rack: value
            )
        }
    }

    private func deviceNodes(_ values: [Device], indexes: TopologyBrowseIndexes) throws -> [TopologyHierarchyNode] {
        try values.enumerated().map { offset, value in
            try Self.checkCancellation(at: offset)
            return TopologyHierarchyNode(
                id: value.id, parentID: value.rackID, kind: .device, name: value.name, detail: value.assetCode.value,
                childCount: indexes.moduleCountByDevice[value.id, default: 0] + indexes.directPortCountByDevice[value.id, default: 0], location: nil, rack: nil
            )
        }
    }

    private func moduleNodes(_ values: [Module], indexes: TopologyBrowseIndexes) throws -> [TopologyHierarchyNode] {
        try values.enumerated().map { offset, value in
            try Self.checkCancellation(at: offset)
            return TopologyHierarchyNode(
                id: value.id, parentID: value.deviceID, kind: .module, name: value.slot, detail: "Module",
                childCount: indexes.portCountByModule[value.id, default: 0], location: nil, rack: nil
            )
        }
    }

    private func portNodes(_ values: [NetworkModel.Port]) throws -> [TopologyHierarchyNode] {
        try values.enumerated().map { offset, value in
            try Self.checkCancellation(at: offset)
            return TopologyHierarchyNode(
                id: value.id,
                parentID: value.moduleID ?? value.deviceID,
                kind: .port,
                name: value.label,
                detail: "\(value.medium.rawValue) · \(value.connector.rawValue) · \(value.face.rawValue)",
                childCount: 0,
                location: nil,
                rack: nil
            )
        }
    }

    func racks(in namespace: PersistenceNamespace) async throws -> [RackElevationSnapshot] {
        let projection = try await readProjection(in: namespace)
        let racks = projection.hierarchy.racks.filter { $0.deletedAt == nil }
        let indexes = try TopologyBrowseIndexes(
            locations: projection.hierarchy.locations.filter { $0.deletedAt == nil },
            racks: racks,
            devices: projection.topology.devices,
            modules: projection.topology.modules,
            ports: projection.topology.ports,
            cables: projection.topology.cables,
            reservations: projection.topology.reservations,
            placements: projection.placements,
            rackReservations: projection.rackReservations
        )
        var snapshots: [RackElevationSnapshot] = []
        snapshots.reserveCapacity(racks.count * 2)
        for (offset, rack) in racks.enumerated() {
            try Self.checkCancellation(at: offset)
            for face in ["front", "rear"] {
                if let snapshot = try rackFaceSnapshot(rack: rack, face: face, projection: projection, indexes: indexes) {
                    snapshots.append(snapshot)
                }
            }
        }
        return snapshots.sorted { lexicalLess([$0.assetCode.value, $0.faceName, $0.id], [$1.assetCode.value, $1.faceName, $1.id]) }
    }

    private func rackFaceSnapshot(rack: Rack, face: String, projection: MirrorProjection, indexes: TopologyBrowseIndexes) throws -> RackElevationSnapshot? {
        let key = TopologyBrowseIndexes.RackFaceKey(rackID: rack.id, faceName: face)
        let ports = try rackPortSnapshots(key: key, projection: projection, indexes: indexes)
        let entries = rackEntries(key: key, indexes: indexes)
        guard !ports.isEmpty || !entries.isEmpty else { return nil }
        return RackElevationSnapshot(
            id: "\(rack.id.description):\(face)",
            rackID: rack.id,
            assetCode: rack.assetCode,
            heightRU: rack.heightRU,
            faceName: face,
            entries: entries.sorted { $0.startRU < $1.startRU },
            ports: ports
        )
    }

    private func rackPortSnapshots(
        key: TopologyBrowseIndexes.RackFaceKey, projection: MirrorProjection, indexes: TopologyBrowseIndexes
    ) throws -> [TopologyPortSnapshot] {
        var result: [TopologyPortSnapshot] = []
        for (offset, port) in indexes.portsByRackFace[key, default: []].enumerated() {
            try Self.checkCancellation(at: offset)
            result.append(topologyPortSnapshot(port, projection: projection, indexes: indexes))
        }
        return result.sorted {
            lexicalLess([$0.faceName, $0.label, $0.id.description], [$1.faceName, $1.label, $1.id.description])
        }
    }

    private func topologyPortSnapshot(
        _ port: NetworkModel.Port,
        projection: MirrorProjection,
        indexes: TopologyBrowseIndexes
    ) -> TopologyPortSnapshot {
        let state = projection.portState(for: port.id)
        let cable = indexes.cableByEndpoint[port.id]
        let hasConflict =
            projection.conflictResourceKeys.contains(.object(port.id)) || cable.map { projection.conflictResourceKeys.contains(.object($0.id)) } == true
        return TopologyPortSnapshot(
            id: port.id,
            deviceID: port.deviceID,
            deviceName: indexes.devicesByID[port.deviceID]?.name ?? "Unavailable device",
            moduleID: port.moduleID,
            moduleSlot: port.moduleID.flatMap { indexes.modulesByID[$0]?.slot },
            label: port.label,
            faceName: port.face.rawValue,
            medium: port.medium,
            connector: port.connector,
            availability: port.availability,
            state: state,
            cable: cable.map(Self.topologyCableSnapshot),
            reservationOwner: reservationOwner(for: port, indexes: indexes),
            warnings: Self.portWarnings(for: port, state: state, hasConflict: hasConflict),
            hasConflict: hasConflict
        )
    }

    private func reservationOwner(for port: NetworkModel.Port, indexes: TopologyBrowseIndexes) -> String? {
        guard indexes.reservedPortIDs.contains(port.id) else { return nil }
        return "Unavailable: reservation owner is not present in the local mirror."
    }

    private func rackEntries(key: TopologyBrowseIndexes.RackFaceKey, indexes: TopologyBrowseIndexes) -> [RackElevationEntrySnapshot] {
        let placements = indexes.placementsByRackFace[key, default: []].compactMap { placement in
            indexes.devicesByID[placement.deviceID].map { device in
                RackElevationEntrySnapshot(
                    id: device.id, name: device.name, assetCode: device.assetCode, startRU: placement.startRU, heightRU: placement.heightRU,
                    isReservation: false
                )
            }
        }
        let reservations = indexes.rackReservationsByRackFace[key, default: []].map { reservation in
            RackElevationEntrySnapshot(
                id: reservation.id, name: "Reserved rack space", assetCode: nil, startRU: reservation.startRU,
                heightRU: reservation.heightRU, isReservation: true
            )
        }
        return placements + reservations
    }

    func deviceDecommissionSnapshot(for deviceID: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceDecommissionSnapshot {
        let projection = try await readProjection(in: namespace)
        guard let device = projection.topology.devices.first(where: { $0.id == deviceID }) else {
            throw ProductionMutationPlannerError.missingTopologyObject(.object(deviceID))
        }
        let interfaces = projection.interfaces
            .filter { $0.isActive && $0.deviceID == deviceID }
            .sorted { $0.id < $1.id }
        let interfaceIDs = Set(interfaces.map(\.id))
        return DeviceDecommissionSnapshot(
            device: device,
            modules: projection.topology.modules
                .filter { $0.deviceID == deviceID }
                .sorted { $0.id < $1.id },
            ports: projection.topology.ports
                .filter { $0.deviceID == deviceID }
                .sorted { $0.id < $1.id },
            rackPlacements: projection.placements
                .filter { $0.deviceID == deviceID }
                .sorted {
                    if $0.rackID != $1.rackID { return $0.rackID < $1.rackID }
                    if $0.face.rawValue != $1.face.rawValue { return $0.face.rawValue < $1.face.rawValue }
                    if $0.startRU != $1.startRU { return $0.startRU < $1.startRU }
                    return $0.heightRU < $1.heightRU
                },
            floorPlanAnchors: projection.anchors
                .filter { $0.objectID == deviceID }
                .sorted { $0.id < $1.id },
            interfaces: interfaces,
            addressAssignments: projection.assignments
                .filter { $0.isActive && interfaceIDs.contains($0.interfaceID) }
                .sorted { $0.id < $1.id },
            vlanMemberships: projection.memberships
                .filter { $0.isActive && interfaceIDs.contains($0.interfaceID) }
                .sorted { $0.id < $1.id },
            addresses: projection.addresses
                .filter { address in
                    address.isActive && address.assignedInterfaceID.map { interfaceIDs.contains($0) } == true
                }
                .sorted { $0.id < $1.id }
        )
    }
}
