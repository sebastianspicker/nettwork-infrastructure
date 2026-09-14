import Foundation

/// A named socket on a device template. A module can be installed only in a
/// declared slot and only when its template is one of the permitted choices.
public struct ModuleSlotTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var displayName: String
    public var allowedModuleTemplateIDs: [ObjectID]
    public var isRequired: Bool

    public init(key: String, displayName: String, allowedModuleTemplateIDs: [ObjectID], isRequired: Bool = false) {
        self.key = CustomFieldValue.normalizedKey(key)
        self.displayName = displayName
        self.allowedModuleTemplateIDs = allowedModuleTemplateIDs
        self.isRequired = isRequired
    }
}

public struct ModuleTemplateSnapshot: Codable, Hashable, Sendable {
    public var templateID: ObjectID
    public var version: Int
    public var name: String
    public var ports: [PortTemplate]
    public var customFieldSchemas: [CustomFieldSchema]

    public init(template: ModuleTemplate) {
        templateID = template.id
        version = template.version
        name = template.name
        ports = template.ports
        customFieldSchemas = template.customFieldSchemas
    }
}

/// The materialized definition used to create a device. It is intentionally a
/// value, not a link back to an editable template, so existing devices are
/// stable until a caller explicitly accepts a migration plan.
public struct DeviceTemplateSnapshot: Codable, Hashable, Sendable {
    public var templateID: ObjectID
    public var version: Int
    public var name: String
    public var kind: DeviceKind
    public var rackHeightRU: Int
    public var portTemplates: [PortTemplate]
    public var moduleSlots: [ModuleSlotTemplate]
    public var customFieldSchemas: [CustomFieldSchema]

    public init(template: DeviceType) {
        templateID = template.id
        version = template.version
        name = template.name
        kind = template.kind
        rackHeightRU = template.rackHeightRU
        portTemplates = template.portTemplates
        moduleSlots = template.moduleSlots
        customFieldSchemas = template.customFieldSchemas
    }
}

public enum TemplateValidationError: Error, Hashable, Sendable {
    case invalidVersion(ObjectID)
    case invalidRackHeight(ObjectID)
    case duplicatePortTemplate(ObjectID)
    case duplicatePortOrder(face: PortFace, order: Int)
    case invalidFiberTemplate(ObjectID)
    case invalidConnectorTemplate(ObjectID)
    case duplicateSlot(String)
    case emptySlot(String)
    case emptyAllowedModules(String)
    case duplicateAllowedModule(String, ObjectID)
    case missingRequiredSlot(String)
    case unknownSlot(String)
    case disallowedModule(slot: String, templateID: ObjectID)
    case missingInstantiationID(ObjectID)
    case duplicateInstantiationID(ObjectID)
    case missingSnapshot(ObjectID)
    case incompatibleMigration(ObjectID)
    case invalidMigrationVersion(ObjectID)
}

public enum TemplateCatalog {
    public static func validate(moduleTemplate: ModuleTemplate) throws {
        guard moduleTemplate.version > 0 else { throw TemplateValidationError.invalidVersion(moduleTemplate.id) }
        try validateSchemas(moduleTemplate.customFieldSchemas)
        try validate(portTemplates: moduleTemplate.ports)
    }

    public static func validate(deviceTemplate: DeviceType, moduleTemplates: [ModuleTemplate] = []) throws {
        guard deviceTemplate.version > 0 else { throw TemplateValidationError.invalidVersion(deviceTemplate.id) }
        guard deviceTemplate.rackHeightRU > 0 else { throw TemplateValidationError.invalidRackHeight(deviceTemplate.id) }
        try validateSchemas(deviceTemplate.customFieldSchemas)
        try validate(portTemplates: deviceTemplate.portTemplates)
        try validate(moduleSlots: deviceTemplate.moduleSlots)
        for template in moduleTemplates { try validate(moduleTemplate: template) }
    }

    private static func validate(moduleSlots: [ModuleSlotTemplate]) throws {
        var slots = Set<String>()
        for slot in moduleSlots {
            guard !slot.key.isEmpty else { throw TemplateValidationError.emptySlot(slot.key) }
            guard slots.insert(slot.key).inserted else { throw TemplateValidationError.duplicateSlot(slot.key) }
            guard !slot.allowedModuleTemplateIDs.isEmpty else { throw TemplateValidationError.emptyAllowedModules(slot.key) }
            var allowed = Set<ObjectID>()
            for moduleID in slot.allowedModuleTemplateIDs {
                guard allowed.insert(moduleID).inserted else { throw TemplateValidationError.duplicateAllowedModule(slot.key, moduleID) }
            }
        }
    }

    public static func clone(_ template: DeviceType, id: ObjectID, portIDs: [ObjectID: ObjectID]) throws -> DeviceType {
        try validate(deviceTemplate: template)
        return DeviceType(
            id: id, name: template.name, kind: template.kind,
            customFields: template.customFields, version: 1, rackHeightRU: template.rackHeightRU,
            portTemplates: try clonedPorts(template.portTemplates, ids: portIDs),
            moduleSlots: template.moduleSlots, customFieldSchemas: template.customFieldSchemas)
    }

    public static func clone(_ template: ModuleTemplate, id: ObjectID, portIDs: [ObjectID: ObjectID]) throws -> ModuleTemplate {
        try validate(moduleTemplate: template)
        return ModuleTemplate(
            id: id, name: template.name, ports: try clonedPorts(template.ports, ids: portIDs), version: 1, customFieldSchemas: template.customFieldSchemas)
    }

    public static func nextVersion(of template: DeviceType) throws -> DeviceType {
        try validate(deviceTemplate: template)
        guard template.version < Int.max else { throw TemplateValidationError.invalidVersion(template.id) }
        var next = template
        next.version += 1
        return next
    }

    public static func nextVersion(of template: ModuleTemplate) throws -> ModuleTemplate {
        try validate(moduleTemplate: template)
        guard template.version < Int.max else { throw TemplateValidationError.invalidVersion(template.id) }
        var next = template
        next.version += 1
        return next
    }

    public static func validate(portTemplates: [PortTemplate]) throws {
        var ids = Set<ObjectID>()
        var orders = Set<String>()
        for port in portTemplates {
            guard ids.insert(port.id).inserted else { throw TemplateValidationError.duplicatePortTemplate(port.id) }
            let orderKey = "\(port.face.rawValue):\(port.order)"
            guard orders.insert(orderKey).inserted else { throw TemplateValidationError.duplicatePortOrder(face: port.face, order: port.order) }
            guard port.medium != .fiber || port.fiberMode == .duplex else { throw TemplateValidationError.invalidFiberTemplate(port.id) }
            guard connectorIsValid(port.connector, for: port.medium) else { throw TemplateValidationError.invalidConnectorTemplate(port.id) }
            try validateSchemas(port.customFieldSchemas)
        }
    }

    private static func connectorIsValid(_ connector: Connector, for medium: PortMedium) -> Bool {
        switch medium {
        case .copper: connector == .rj45
        case .fiber: [.lc, .sc, .mpo].contains(connector)
        case .power: [.c13, .c14].contains(connector)
        case .other: connector == .other
        }
    }

    /// `CustomFieldValidator` intentionally validates both a schema and a
    /// record. Template definitions may contain required fields without a
    /// default, so validate their shape with representative valid values.
    private static func validateSchemas(_ schemas: [CustomFieldSchema]) throws {
        let representativeValues = try schemas.map { schema -> CustomFieldValue in
            let value: CustomFieldValue.Value
            switch schema.kind {
            case .text: value = .text("")
            case .number: value = .number(0)
            case .flag: value = .flag(false)
            case .date: value = .date(.distantPast)
            case .choice:
                guard let first = schema.choices.first else {
                    throw CustomFieldValidationError.invalidChoices(schema.key)
                }
                value = .text(first)
            }
            return CustomFieldValue(key: schema.key, value: value)
        }
        _ = try CustomFieldValidator.resolvedValues(values: representativeValues, against: schemas)
    }

    private static func clonedPorts(_ ports: [PortTemplate], ids: [ObjectID: ObjectID]) throws -> [PortTemplate] {
        var cloned = [PortTemplate]()
        var outputIDs = Set<ObjectID>()
        for port in ports {
            guard let id = ids[port.id] else { throw TemplateValidationError.missingInstantiationID(port.id) }
            guard outputIDs.insert(id).inserted else { throw TemplateValidationError.duplicateInstantiationID(id) }
            cloned.append(
                PortTemplate(
                    id: id, name: port.name, medium: port.medium, connector: port.connector, order: port.order, face: port.face, fiberMode: port.fiberMode,
                    customFieldSchemas: port.customFieldSchemas))
        }
        return cloned
    }
}

public struct DeviceInstantiationRequest: Sendable {
    public var deviceID: ObjectID
    public var assetCode: AssetCode
    public var name: String
    public var rackID: ObjectID?
    public var customFields: [CustomFieldValue]
    /// Slot keys map to an installed module template. Omitted optional slots do
    /// not produce records; required slots are validated.
    public var modulesBySlot: [String: ModuleTemplate]
    public var moduleIDsBySlot: [String: ObjectID]
    public var moduleCustomFieldsBySlot: [String: [CustomFieldValue]]
    /// Includes every directly-mounted and module-mounted port template ID.
    public var portIDsByTemplateID: [ObjectID: ObjectID]
    public var portCustomFieldsByTemplateID: [ObjectID: [CustomFieldValue]]

    public init(
        deviceID: ObjectID, assetCode: AssetCode, name: String, rackID: ObjectID? = nil, customFields: [CustomFieldValue] = [],
        modulesBySlot: [String: ModuleTemplate] = [:],
        moduleIDsBySlot: [String: ObjectID] = [:], moduleCustomFieldsBySlot: [String: [CustomFieldValue]] = [:], portIDsByTemplateID: [ObjectID: ObjectID],
        portCustomFieldsByTemplateID: [ObjectID: [CustomFieldValue]] = [:]
    ) {
        self.deviceID = deviceID
        self.assetCode = assetCode
        self.name = name
        self.rackID = rackID
        self.customFields = customFields
        self.modulesBySlot = modulesBySlot
        self.moduleIDsBySlot = moduleIDsBySlot
        self.moduleCustomFieldsBySlot = moduleCustomFieldsBySlot
        self.portIDsByTemplateID = portIDsByTemplateID
        self.portCustomFieldsByTemplateID = portCustomFieldsByTemplateID
    }
}

public struct DeviceInstantiation: Codable, Hashable, Sendable {
    public var device: Device
    public var modules: [Module]
    public var ports: [Port]

    public init(device: Device, modules: [Module], ports: [Port]) {
        self.device = device
        self.modules = modules
        self.ports = ports
    }
}
