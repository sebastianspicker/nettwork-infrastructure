import Foundation

public struct DeviceType: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var name: String
    public var kind: DeviceKind
    /// Values retained for import compatibility. New instances resolve values
    /// against `customFieldSchemas` at template-instantiation time.
    public var customFields: [CustomFieldValue]
    public var version: Int
    public var rackHeightRU: Int
    public var portTemplates: [PortTemplate]
    public var moduleSlots: [ModuleSlotTemplate]
    public var customFieldSchemas: [CustomFieldSchema]

    public init(
        id: ObjectID = .init(), name: String, kind: DeviceKind,
        customFields: [CustomFieldValue] = [], version: Int = 1, rackHeightRU: Int = 1,
        portTemplates: [PortTemplate] = [], moduleSlots: [ModuleSlotTemplate] = [],
        customFieldSchemas: [CustomFieldSchema] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.customFields = customFields
        self.version = version
        self.rackHeightRU = rackHeightRU
        self.portTemplates = portTemplates
        self.moduleSlots = moduleSlots
        self.customFieldSchemas = customFieldSchemas
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, customFields, version, rackHeightRU, portTemplates, moduleSlots, customFieldSchemas }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ObjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(DeviceKind.self, forKey: .kind)
        customFields = try container.decodeIfPresent([CustomFieldValue].self, forKey: .customFields) ?? []
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        rackHeightRU = try container.decodeIfPresent(Int.self, forKey: .rackHeightRU) ?? 1
        portTemplates = try container.decodeIfPresent([PortTemplate].self, forKey: .portTemplates) ?? []
        moduleSlots = try container.decodeIfPresent([ModuleSlotTemplate].self, forKey: .moduleSlots) ?? []
        customFieldSchemas = try container.decodeIfPresent([CustomFieldSchema].self, forKey: .customFieldSchemas) ?? []
    }
}

public enum PortFace: String, Codable, CaseIterable, Sendable { case front, rear }
public enum FiberMode: String, Codable, CaseIterable, Sendable { case duplex }
public enum PortAvailability: String, Codable, CaseIterable, Sendable { case available, unavailable }

public struct PortTemplate: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var name: String
    public var medium: PortMedium
    public var connector: Connector
    public var order: Int
    public var face: PortFace
    public var fiberMode: FiberMode?
    public var customFieldSchemas: [CustomFieldSchema]

    public init(
        id: ObjectID = .init(), name: String, medium: PortMedium, connector: Connector,
        order: Int = 0, face: PortFace = .front, fiberMode: FiberMode? = nil,
        customFieldSchemas: [CustomFieldSchema] = []
    ) {
        self.id = id
        self.name = name
        self.medium = medium
        self.connector = connector
        self.order = order
        self.face = face
        self.fiberMode = fiberMode ?? (medium == .fiber ? .duplex : nil)
        self.customFieldSchemas = customFieldSchemas
    }

    private enum CodingKeys: String, CodingKey { case id, name, medium, connector, order, face, fiberMode, customFieldSchemas }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ObjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        medium = try container.decode(PortMedium.self, forKey: .medium)
        connector = try container.decode(Connector.self, forKey: .connector)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        face = try container.decodeIfPresent(PortFace.self, forKey: .face) ?? .front
        fiberMode = try container.decodeIfPresent(FiberMode.self, forKey: .fiberMode) ?? (medium == .fiber ? .duplex : nil)
        customFieldSchemas = try container.decodeIfPresent([CustomFieldSchema].self, forKey: .customFieldSchemas) ?? []
    }
}

public struct ModuleTemplate: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var name: String
    public var ports: [PortTemplate]
    public var version: Int
    public var customFieldSchemas: [CustomFieldSchema]

    public init(id: ObjectID = .init(), name: String, ports: [PortTemplate], version: Int = 1, customFieldSchemas: [CustomFieldSchema] = []) {
        self.id = id
        self.name = name
        self.ports = ports
        self.version = version
        self.customFieldSchemas = customFieldSchemas
    }

    private enum CodingKeys: String, CodingKey { case id, name, ports, version, customFieldSchemas }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ObjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        ports = try container.decodeIfPresent([PortTemplate].self, forKey: .ports) ?? []
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        customFieldSchemas = try container.decodeIfPresent([CustomFieldSchema].self, forKey: .customFieldSchemas) ?? []
    }
}

public struct Device: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var assetCode: AssetCode
    public var name: String
    public var typeID: ObjectID
    public var rackID: ObjectID?
    public var customFields: [CustomFieldValue]
    /// An instantiated device never changes behavior merely because a mutable
    /// template was edited. Migration is a separate, explicit operation.
    public var templateSnapshot: DeviceTemplateSnapshot?
    public init(
        id: ObjectID = .init(), assetCode: AssetCode, name: String, typeID: ObjectID, rackID: ObjectID? = nil, customFields: [CustomFieldValue] = [],
        templateSnapshot: DeviceTemplateSnapshot? = nil
    ) {
        self.id = id
        self.assetCode = assetCode
        self.name = name
        self.typeID = typeID
        self.rackID = rackID
        self.customFields = customFields
        self.templateSnapshot = templateSnapshot
    }

    private enum CodingKeys: String, CodingKey { case id, assetCode, name, typeID, rackID, customFields, templateSnapshot }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ObjectID.self, forKey: .id)
        assetCode = try container.decode(AssetCode.self, forKey: .assetCode)
        name = try container.decode(String.self, forKey: .name)
        typeID = try container.decode(ObjectID.self, forKey: .typeID)
        rackID = try container.decodeIfPresent(ObjectID.self, forKey: .rackID)
        customFields = try container.decodeIfPresent([CustomFieldValue].self, forKey: .customFields) ?? []
        templateSnapshot = try container.decodeIfPresent(DeviceTemplateSnapshot.self, forKey: .templateSnapshot)
    }
}

public struct Module: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var deviceID: ObjectID
    public var templateID: ObjectID
    public var slot: String
    public var templateSnapshot: ModuleTemplateSnapshot?
    public var customFields: [CustomFieldValue]
    public init(
        id: ObjectID = .init(), deviceID: ObjectID, templateID: ObjectID, slot: String, templateSnapshot: ModuleTemplateSnapshot? = nil,
        customFields: [CustomFieldValue] = []
    ) {
        self.id = id
        self.deviceID = deviceID
        self.templateID = templateID
        self.slot = slot
        self.templateSnapshot = templateSnapshot
        self.customFields = customFields
    }

    private enum CodingKeys: String, CodingKey { case id, deviceID, templateID, slot, templateSnapshot, customFields }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ObjectID.self, forKey: .id)
        deviceID = try container.decode(ObjectID.self, forKey: .deviceID)
        templateID = try container.decode(ObjectID.self, forKey: .templateID)
        slot = try container.decode(String.self, forKey: .slot)
        templateSnapshot = try container.decodeIfPresent(ModuleTemplateSnapshot.self, forKey: .templateSnapshot)
        customFields = try container.decodeIfPresent([CustomFieldValue].self, forKey: .customFields) ?? []
    }
}

public struct RackPlacement: Codable, Hashable, Sendable {
    public var deviceID: ObjectID
    public var rackID: ObjectID
    public var startRU: Int
    public var heightRU: Int
    public var face: Face
    public enum Face: String, Codable, Sendable { case front, rear }
    public init(deviceID: ObjectID, rackID: ObjectID, startRU: Int, heightRU: Int, face: Face) {
        self.deviceID = deviceID
        self.rackID = rackID
        self.startRU = startRU
        self.heightRU = heightRU
        self.face = face
    }
}

public struct FloorPlanAnchor: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var objectID: ObjectID
    public var floorID: ObjectID
    public var x: Double
    public var y: Double
    public init(id: ObjectID = .init(), objectID: ObjectID, floorID: ObjectID, x: Double, y: Double) {
        self.id = id
        self.objectID = objectID
        self.floorID = floorID
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey { case id, objectID, floorID, x, y }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Floor-plan anchor coordinates must be finite unit values."
            )
        }
        self.init(
            id: try container.decode(ObjectID.self, forKey: .id),
            objectID: try container.decode(ObjectID.self, forKey: .objectID),
            floorID: try container.decode(ObjectID.self, forKey: .floorID),
            x: x,
            y: y
        )
    }
}
