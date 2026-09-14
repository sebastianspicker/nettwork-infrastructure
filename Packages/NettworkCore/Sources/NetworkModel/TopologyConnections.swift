import Foundation

public struct Port: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var deviceID: ObjectID
    public var moduleID: ObjectID?
    /// Stable identity of the template port that materialized this port.
    /// Legacy/imported ports may be nil and must be explicitly reconciled
    /// before a template migration can change their shape.
    public var templatePortID: ObjectID?
    public var label: String
    public var medium: PortMedium
    public var connector: Connector
    /// Patch-panel and outlet faces are explicit so an internal link cannot
    /// accidentally join two front (or two rear) terminations.
    public var face: PortFace
    /// Fiber ports in v1 represent a duplex pair, not individual strands.
    public var fiberMode: FiberMode?
    /// This is the only directly writable state. Occupancy, reservations, and
    /// planned work are aggregate facts and are calculated by `PhysicalTopology`.
    public var availability: PortAvailability
    public var customFields: [CustomFieldValue]

    /// Source-compatible convenience for earlier import clients. A
    /// caller cannot use this initializer to forge occupied, reserved, or
    /// planned state; those values are intentionally derived by the aggregate.
    public init(
        id: ObjectID = .init(), deviceID: ObjectID, moduleID: ObjectID? = nil,
        templatePortID: ObjectID? = nil, label: String, medium: PortMedium, connector: Connector,
        state: PortState, face: PortFace = .front, fiberMode: FiberMode? = nil,
        customFields: [CustomFieldValue] = []
    ) {
        self.init(
            id: id, deviceID: deviceID, moduleID: moduleID, templatePortID: templatePortID,
            label: label, medium: medium, connector: connector, face: face, fiberMode: fiberMode,
            availability: state == .unavailable ? .unavailable : .available, customFields: customFields)
    }

    public init(
        id: ObjectID = .init(), deviceID: ObjectID, moduleID: ObjectID? = nil,
        templatePortID: ObjectID? = nil, label: String, medium: PortMedium, connector: Connector,
        face: PortFace = .front, fiberMode: FiberMode? = nil, availability: PortAvailability = .available,
        customFields: [CustomFieldValue] = []
    ) {
        self.id = id
        self.deviceID = deviceID
        self.moduleID = moduleID
        self.templatePortID = templatePortID
        self.label = label
        self.medium = medium
        self.connector = connector
        self.face = face
        self.fiberMode = fiberMode ?? (medium == .fiber ? .duplex : nil)
        self.availability = availability
        self.customFields = customFields
    }

    /// A stand-alone port has no graph context, so it can only expose its
    /// availability-derived fallback. Use `PhysicalTopology.portState(for:)`
    /// for the authoritative state.
    public var state: PortState { availability == .unavailable ? .unavailable : .free }

    private enum CodingKeys: String, CodingKey {
        case id, deviceID, moduleID, templatePortID, label, medium, connector, state, face, fiberMode, availability, customFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ObjectID.self, forKey: .id)
        deviceID = try container.decode(ObjectID.self, forKey: .deviceID)
        moduleID = try container.decodeIfPresent(ObjectID.self, forKey: .moduleID)
        templatePortID = try container.decodeIfPresent(ObjectID.self, forKey: .templatePortID)
        label = try container.decode(String.self, forKey: .label)
        medium = try container.decode(PortMedium.self, forKey: .medium)
        connector = try container.decode(Connector.self, forKey: .connector)
        face = try container.decodeIfPresent(PortFace.self, forKey: .face) ?? .front
        fiberMode = try container.decodeIfPresent(FiberMode.self, forKey: .fiberMode) ?? (medium == .fiber ? .duplex : nil)
        availability =
            try container.decodeIfPresent(PortAvailability.self, forKey: .availability)
            ?? ((try container.decodeIfPresent(PortState.self, forKey: .state)) == .unavailable ? .unavailable : .available)
        customFields = try container.decodeIfPresent([CustomFieldValue].self, forKey: .customFields) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(moduleID, forKey: .moduleID)
        try container.encodeIfPresent(templatePortID, forKey: .templatePortID)
        try container.encode(label, forKey: .label)
        try container.encode(medium, forKey: .medium)
        try container.encode(connector, forKey: .connector)
        try container.encode(face, forKey: .face)
        try container.encodeIfPresent(fiberMode, forKey: .fiberMode)
        try container.encode(availability, forKey: .availability)
        try container.encode(customFields, forKey: .customFields)
    }
}

public struct Cable: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var assetCode: AssetCode
    public var endpointA: ObjectID
    public var endpointB: ObjectID
    public var medium: PortMedium
    /// Legacy/common connector retained for import compatibility. The
    /// per-termination values below are authoritative, notably for C13-to-C14
    /// power leads.
    public var connector: Connector
    public var connectorA: Connector
    public var connectorB: Connector
    public var kind: CableKind
    public var status: CableStatus
    public var color: String?
    public var lengthMeters: Double?
    public init(
        id: ObjectID = .init(), assetCode: AssetCode, endpointA: ObjectID, endpointB: ObjectID, medium: PortMedium, connector: Connector, kind: CableKind,
        status: CableStatus, color: String? = nil, lengthMeters: Double? = nil
    ) {
        self.init(
            id: id, assetCode: assetCode, endpointA: endpointA, connectorA: connector, endpointB: endpointB, connectorB: connector, medium: medium, kind: kind,
            status: status, color: color, lengthMeters: lengthMeters)
    }

    public init(
        id: ObjectID = .init(), assetCode: AssetCode, endpointA: ObjectID, connectorA: Connector, endpointB: ObjectID, connectorB: Connector,
        medium: PortMedium, kind: CableKind, status: CableStatus,
        color: String? = nil, lengthMeters: Double? = nil
    ) {
        self.id = id
        self.assetCode = assetCode
        self.endpointA = endpointA
        self.endpointB = endpointB
        self.medium = medium
        self.connector = connectorA == connectorB ? connectorA : .other
        self.connectorA = connectorA
        self.connectorB = connectorB
        self.kind = kind
        self.status = status
        self.color = color
        self.lengthMeters = lengthMeters
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetCode, endpointA, endpointB, medium, connector, connectorA, connectorB, kind, status, color, lengthMeters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ObjectID.self, forKey: .id)
        assetCode = try container.decode(AssetCode.self, forKey: .assetCode)
        endpointA = try container.decode(ObjectID.self, forKey: .endpointA)
        endpointB = try container.decode(ObjectID.self, forKey: .endpointB)
        medium = try container.decode(PortMedium.self, forKey: .medium)
        connector = try container.decode(Connector.self, forKey: .connector)
        connectorA = try container.decodeIfPresent(Connector.self, forKey: .connectorA) ?? connector
        connectorB = try container.decodeIfPresent(Connector.self, forKey: .connectorB) ?? connector
        kind = try container.decode(CableKind.self, forKey: .kind)
        status = try container.decode(CableStatus.self, forKey: .status)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        lengthMeters = try container.decodeIfPresent(Double.self, forKey: .lengthMeters)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(assetCode, forKey: .assetCode)
        try container.encode(endpointA, forKey: .endpointA)
        try container.encode(endpointB, forKey: .endpointB)
        try container.encode(medium, forKey: .medium)
        try container.encode(connector, forKey: .connector)
        try container.encode(connectorA, forKey: .connectorA)
        try container.encode(connectorB, forKey: .connectorB)
        try container.encode(kind, forKey: .kind)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(lengthMeters, forKey: .lengthMeters)
    }
}

public struct InternalLink: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var endpointA: ObjectID
    public var endpointB: ObjectID
    public init(id: ObjectID = .init(), endpointA: ObjectID, endpointB: ObjectID) {
        self.id = id
        self.endpointA = endpointA
        self.endpointB = endpointB
    }
}

public enum TopologyObjectKind: String, Codable, CaseIterable, Sendable { case device, module, port, cable, internalLink }

/// A retained deletion marker. New topology records may never reuse this ID,
/// even if a stale client still has a copy of the deleted record.
public struct TopologyTombstone: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public var kind: TopologyObjectKind
    public var deletedAt: Date

    public init(id: ObjectID, kind: TopologyObjectKind, deletedAt: Date) {
        self.id = id
        self.kind = kind
        self.deletedAt = deletedAt
    }
}

public struct TopologyReservation: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public var portIDs: Set<ObjectID>

    public init(id: ObjectID = .init(), portIDs: Set<ObjectID>) {
        self.id = id
        self.portIDs = portIDs
    }
}

public struct PlannedTopologyWork: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public var portIDs: Set<ObjectID>

    public init(id: ObjectID = .init(), portIDs: Set<ObjectID>) {
        self.id = id
        self.portIDs = portIDs
    }
}
