import CloudSync
import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataFeatureReadAdapter {
    static func inventoryKind(_ kind: LocationKind) -> InventoryObjectKind {
        switch kind {
        case .site:
            .site
        case .room:
            .room
        case .workspace, .building, .floor, .unrackedArea:
            .site
        }
    }

    static func topologyCableSnapshot(_ cable: Cable) -> TopologyCableSnapshot {
        TopologyCableSnapshot(
            id: cable.id, assetCode: cable.assetCode, kind: cable.kind, medium: cable.medium, connectorA: cable.connectorA,
            connectorB: cable.connectorB, status: cable.status, color: cable.color, lengthMeters: cable.lengthMeters,
            endpointA: cable.endpointA, endpointB: cable.endpointB
        )
    }

    static func portWarnings(for port: NetworkModel.Port, state: PortState, hasConflict: Bool) -> [String] {
        var warnings: [String] = []
        if state == .reserved { warnings.append("Reserved port. Reservation owner is unavailable in the mirrored domain record.") }
        if state == .planned { warnings.append("Planned topology work is present for this port.") }
        if state == .occupied { warnings.append("Port is occupied by an installed cable.") }
        if port.availability == .unavailable { warnings.append("Port is marked unavailable.") }
        if hasConflict { warnings.append("The local mirror reports unresolved reconciliation conflict(s).") }
        return warnings
    }

    static func isPending(_ status: WorkOrderStatus) -> Bool {
        [
            .draft, .reserved, .approved, .executing,
            .cancellationRequested, .reconciliation,
        ].contains(status)
    }
    static func segmentLabel(_ segment: RichTraceSegment) -> String {
        let asset = segment.cable?.assetCode.value ?? segment.segment.id.description
        return "\(segment.segment.kind.rawValue) · \(asset)"
    }
    static func traceSegmentSnapshot(_ segment: RichTraceSegment, topology: PhysicalTopology) -> TraceSegmentSnapshot {
        let kind: FeatureContracts.TraceSegmentKind = segment.segment.kind == .cable ? .cable : .internalLink
        let detail: String?
        let request: TopologyWorkOrderRequest?
        if segment.segment.kind == .cable,
            let cable = topology.cables.first(where: { $0.id == segment.segment.id })
        {
            let length = cable.lengthMeters.map { " · \($0) m" } ?? ""
            let color = cable.color.map { " · \($0)" } ?? ""
            let connector = "\(cable.connectorA.rawValue) to \(cable.connectorB.rawValue)\(color)\(length)"
            detail = [
                cable.kind.rawValue,
                cable.medium.rawValue,
                connector,
                cable.status.rawValue,
            ].joined(separator: " · ")
            request = TopologyWorkOrderRequest(
                title: "Disconnect \(cable.assetCode.value)",
                ticket: "",
                notes: "Staged from a verified local trace segment.",
                action: .disconnect(DisconnectTopologyCommand(cableID: cable.id)),
                resourceKeys: [.object(cable.id), .object(cable.endpointA), .object(cable.endpointB)]
            )
        } else {
            detail = segment.segment.kind == .internalLink ? "Internal passive mapping" : nil
            request = nil
        }
        return TraceSegmentSnapshot(
            id: segment.id,
            kind: kind,
            label: segmentLabel(segment),
            detail: detail,
            workOrderRequest: request
        )
    }

    static func templateSummary(_ template: DeviceType) -> String {
        guard !template.portTemplates.isEmpty else {
            return "No port templates"
        }
        return "\(template.kind.rawValue), \(template.portTemplates.count) port template(s)"
    }

    static func checkCancellation(at offset: Int) throws {
        if offset.isMultiple(of: 128) { try Task.checkCancellation() }
    }

    static func stableObjectID(_ string: String) -> ObjectID {
        // This is only a display identity for a deterministic IP record name;
        // it never crosses the mutation boundary as an authoritative object ID.
        let hex = SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
        let uuidString =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-" + "\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: uuidString) else {
            preconditionFailure("A SHA-256 digest must produce a valid UUID representation.")
        }
        return ObjectID(uuid)
    }
}

/// One-pass browse indexes shared by hierarchy and rack elevation rendering.
/// They retain the previous row construction and sort order while avoiding
/// repeated full topology scans for every parent, port, and rack face.
struct TopologyBrowseIndexes {
    struct RackFaceKey: Hashable {
        let rackID: ObjectID
        let faceName: String
    }

    let locationChildCount: [ObjectID: Int]
    let rackCountByLocation: [ObjectID: Int]
    let deviceCountByRack: [ObjectID: Int]
    let moduleCountByDevice: [ObjectID: Int]
    let directPortCountByDevice: [ObjectID: Int]
    let portCountByModule: [ObjectID: Int]
    let devicesByID: [ObjectID: Device]
    let modulesByID: [ObjectID: Module]
    let portsByRackFace: [RackFaceKey: [NetworkModel.Port]]
    let cableByEndpoint: [ObjectID: Cable]
    let reservedPortIDs: Set<ObjectID>
    let placementsByRackFace: [RackFaceKey: [RackPlacement]]
    let rackReservationsByRackFace: [RackFaceKey: [RackPlacementReservation]]

    init(
        locations: [Location], racks: [Rack], devices: [Device], modules: [Module],
        ports: [NetworkModel.Port], cables: [Cable],
        reservations: [TopologyReservation], placements: [RackPlacement], rackReservations: [RackPlacementReservation]
    ) throws {
        let indexedDevices = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let indexedModules = Dictionary(modules.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let portIndexes = try Self.portIndexes(ports, devicesByID: indexedDevices)
        locationChildCount = try Self.locationCounts(locations)
        rackCountByLocation = try Self.rackCounts(racks)
        deviceCountByRack = try Self.deviceCounts(devices)
        moduleCountByDevice = try Self.moduleCounts(modules)
        directPortCountByDevice = portIndexes.directByDevice
        portCountByModule = portIndexes.byModule
        devicesByID = indexedDevices
        modulesByID = indexedModules
        portsByRackFace = portIndexes.byRackFace
        cableByEndpoint = try Self.cablesByEndpoint(cables)
        reservedPortIDs = try Self.reservedPortIDs(reservations)
        placementsByRackFace = try Self.placementsByRackFace(placements)
        rackReservationsByRackFace = try Self.rackReservationsByRackFace(rackReservations)
    }

    private static func locationCounts(_ values: [Location]) throws -> [ObjectID: Int] {
        var result: [ObjectID: Int] = [:]
        for (offset, value) in values.enumerated() {
            try checkCancellation(at: offset)
            if let parentID = value.parentID { result[parentID, default: 0] += 1 }
        }
        return result
    }

    private static func rackCounts(_ values: [Rack]) throws -> [ObjectID: Int] {
        var result: [ObjectID: Int] = [:]
        for (offset, value) in values.enumerated() {
            try checkCancellation(at: offset)
            result[value.locationID, default: 0] += 1
        }
        return result
    }

    private static func deviceCounts(_ values: [Device]) throws -> [ObjectID: Int] {
        var result: [ObjectID: Int] = [:]
        for (offset, value) in values.enumerated() {
            try checkCancellation(at: offset)
            if let rackID = value.rackID { result[rackID, default: 0] += 1 }
        }
        return result
    }

    private static func moduleCounts(_ values: [Module]) throws -> [ObjectID: Int] {
        var result: [ObjectID: Int] = [:]
        for (offset, value) in values.enumerated() {
            try checkCancellation(at: offset)
            result[value.deviceID, default: 0] += 1
        }
        return result
    }

    private static func portIndexes(
        _ ports: [NetworkModel.Port], devicesByID: [ObjectID: Device]
    ) throws -> (
        directByDevice: [ObjectID: Int],
        byModule: [ObjectID: Int],
        byRackFace: [RackFaceKey: [NetworkModel.Port]]
    ) {
        var directByDevice: [ObjectID: Int] = [:]
        var byModule: [ObjectID: Int] = [:]
        var byRackFace: [RackFaceKey: [NetworkModel.Port]] = [:]
        for (offset, port) in ports.enumerated() {
            try checkCancellation(at: offset)
            if let moduleID = port.moduleID {
                byModule[moduleID, default: 0] += 1
            } else {
                directByDevice[port.deviceID, default: 0] += 1
            }
            if let rackID = devicesByID[port.deviceID]?.rackID {
                let key = RackFaceKey(rackID: rackID, faceName: port.face.rawValue)
                byRackFace[key, default: []].append(port)
            }
        }
        return (directByDevice, byModule, byRackFace)
    }

    private static func cablesByEndpoint(_ cables: [Cable]) throws -> [ObjectID: Cable] {
        var result: [ObjectID: Cable] = [:]
        for (offset, cable) in cables.enumerated() {
            try checkCancellation(at: offset)
            if result[cable.endpointA] == nil { result[cable.endpointA] = cable }
            if result[cable.endpointB] == nil { result[cable.endpointB] = cable }
        }
        return result
    }

    private static func reservedPortIDs(_ reservations: [TopologyReservation]) throws -> Set<ObjectID> {
        var result = Set<ObjectID>()
        for (offset, reservation) in reservations.enumerated() {
            try checkCancellation(at: offset)
            result.formUnion(reservation.portIDs)
        }
        return result
    }

    private static func placementsByRackFace(_ placements: [RackPlacement]) throws -> [RackFaceKey: [RackPlacement]] {
        var result: [RackFaceKey: [RackPlacement]] = [:]
        for (offset, placement) in placements.enumerated() {
            try checkCancellation(at: offset)
            let key = RackFaceKey(rackID: placement.rackID, faceName: placement.face.rawValue)
            result[key, default: []].append(placement)
        }
        return result
    }

    private static func rackReservationsByRackFace(_ reservations: [RackPlacementReservation]) throws -> [RackFaceKey: [RackPlacementReservation]] {
        var result: [RackFaceKey: [RackPlacementReservation]] = [:]
        for (offset, reservation) in reservations.enumerated() {
            try checkCancellation(at: offset)
            let key = RackFaceKey(rackID: reservation.rackID, faceName: reservation.face.rawValue)
            result[key, default: []].append(reservation)
        }
        return result
    }

    private static func checkCancellation(at offset: Int) throws {
        if offset.isMultiple(of: 128) { try Task.checkCancellation() }
    }
}

@MainActor

struct IPAMWorkflowFlags {
    let isPlanned: Bool
    let isPending: Bool
    let isConflicted: Bool
}

extension Array where Element == LocalMirrorRecord {
    func decoded<T: Decodable>(
        _ type: T.Type,
        recordType: String,
        expectedResourceKey: (T) -> ResourceKey
    ) throws -> [T] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let acceptedTypes = Self.persistenceRecordTypes(for: recordType)
        var values: [T] = []
        for record in self {
            guard !record.isTombstone, acceptedTypes.contains(record.recordType) else { continue }
            guard let payload = record.payload, payload.count <= 1_048_576 else {
                throw ProductionAdapterError.malformedAuthoritativeMirrorRecord(record.resourceKey, record.recordType)
            }
            let value: T
            do {
                value = try decoder.decode(T.self, from: payload)
            } catch {
                throw ProductionAdapterError.malformedAuthoritativeMirrorRecord(record.resourceKey, record.recordType)
            }
            guard record.resourceKey == expectedResourceKey(value) else {
                throw ProductionAdapterError.mirrorRecordIdentityMismatch(record.resourceKey, record.recordType)
            }
            values.append(value)
        }
        return values
    }

    private static func persistenceRecordTypes(for cloudRecordType: String) -> Set<String> {
        switch cloudRecordType {
        case WorkspaceRecordType.physicalTopology: [cloudRecordType, LocalRecordKind.physicalTopology]
        case WorkspaceRecordType.prefix: [cloudRecordType, LocalRecordKind.prefix]
        case CloudRecordNaming.workOrderRecordType: [cloudRecordType, LocalRecordKind.workOrder]
        case CloudRecordNaming.auditRecordType: [cloudRecordType, LocalRecordKind.auditEvent]
        default: [cloudRecordType]
        }
    }
}
