import Foundation

public enum TemplatePortMigrationAction: String, Codable, Hashable, Sendable { case retain, add, remove, reconfigure }

public struct TemplatePortMigrationImpact: Codable, Hashable, Sendable {
    public var templatePortID: ObjectID
    public var action: TemplatePortMigrationAction
    public var requiresCableReview: Bool
    /// Exact current and intended records make every port migration an
    /// auditable compare-and-swap rather than a version-label-only change.
    public var currentPort: Port?
    public var desiredPort: Port?
    public var connectedCableIDs: [ObjectID]

    public init(
        templatePortID: ObjectID, action: TemplatePortMigrationAction, requiresCableReview: Bool,
        currentPort: Port? = nil, desiredPort: Port? = nil, connectedCableIDs: [ObjectID] = []
    ) {
        self.templatePortID = templatePortID
        self.action = action
        self.requiresCableReview = requiresCableReview
        self.currentPort = currentPort
        self.desiredPort = desiredPort
        self.connectedCableIDs = connectedCableIDs.sorted()
    }
}

/// A migration is an auditable decision object. Calling `apply` is the only
/// way a device advances from one immutable snapshot to another.
public struct DeviceTemplateMigrationPlan: Codable, Hashable, Sendable {
    public var deviceID: ObjectID
    public var sourceSnapshot: DeviceTemplateSnapshot
    public var targetSnapshot: DeviceTemplateSnapshot
    public var portImpacts: [TemplatePortMigrationImpact]

    public init(deviceID: ObjectID, sourceSnapshot: DeviceTemplateSnapshot, targetSnapshot: DeviceTemplateSnapshot, portImpacts: [TemplatePortMigrationImpact])
    {
        self.deviceID = deviceID
        self.sourceSnapshot = sourceSnapshot
        self.targetSnapshot = targetSnapshot
        self.portImpacts = portImpacts
    }
}

public enum TemplateMigration {
    public static func plan(
        device: Device, installedPorts: [Port], cables: [Cable], target: DeviceType,
        newPortIDs: [ObjectID: ObjectID]
    ) throws -> DeviceTemplateMigrationPlan {
        guard let source = device.templateSnapshot else { throw TemplateValidationError.missingSnapshot(device.id) }
        guard source.templateID == target.id, target.version > source.version else { throw TemplateValidationError.invalidMigrationVersion(device.id) }
        try TemplateCatalog.validate(portTemplates: source.portTemplates)
        try TemplateCatalog.validate(deviceTemplate: target)
        let targetSnapshot = DeviceTemplateSnapshot(template: target)
        let sourcePorts = Dictionary(uniqueKeysWithValues: source.portTemplates.map { ($0.id, $0) })
        let targetPorts = Dictionary(uniqueKeysWithValues: targetSnapshot.portTemplates.map { ($0.id, $0) })
        let installedByTemplateID = try installedPortsByTemplateID(installedPorts, deviceID: device.id)
        guard Set(installedByTemplateID.keys) == Set(sourcePorts.keys) else {
            throw TemplateValidationError.incompatibleMigration(device.id)
        }
        let ids = Set(sourcePorts.keys).union(targetPorts.keys).sorted()
        let impacts = try ids.map {
            try makeImpact(
                templatePortID: $0, source: sourcePorts[$0], target: targetPorts[$0], installed: installedByTemplateID, deviceID: device.id, cables: cables,
                newPortIDs: newPortIDs)
        }
        return DeviceTemplateMigrationPlan(deviceID: device.id, sourceSnapshot: source, targetSnapshot: targetSnapshot, portImpacts: impacts)
    }

    private static func installedPortsByTemplateID(_ ports: [Port], deviceID: ObjectID) throws -> [ObjectID: Port] {
        var result = [ObjectID: Port]()
        for port in ports where port.deviceID == deviceID && port.moduleID == nil {
            guard let templatePortID = port.templatePortID,
                result.updateValue(port, forKey: templatePortID) == nil
            else { throw TemplateValidationError.incompatibleMigration(deviceID) }
        }
        return result
    }

    private static func makeImpact(
        templatePortID: ObjectID, source: PortTemplate?, target: PortTemplate?, installed: [ObjectID: Port], deviceID: ObjectID, cables: [Cable],
        newPortIDs: [ObjectID: ObjectID]
    ) throws -> TemplatePortMigrationImpact {
        switch (source, target) {
        case let (.none, .some(target)):
            guard let portID = newPortIDs[templatePortID] else { throw TemplateValidationError.missingInstantiationID(templatePortID) }
            return TemplatePortMigrationImpact(
                templatePortID: templatePortID, action: .add, requiresCableReview: false,
                desiredPort: try materializedPort(id: portID, deviceID: deviceID, template: target, customFields: []))
        case (.some, .none):
            let current = try installedPort(templatePortID, installed: installed, deviceID: deviceID)
            return TemplatePortMigrationImpact(
                templatePortID: templatePortID, action: .remove, requiresCableReview: true, currentPort: current,
                connectedCableIDs: connectedCableIDs(for: current.id, in: cables))
        case let (.some(source), .some(target)):
            return try reconfigurationImpact(
                templatePortID: templatePortID, source: source, target: target, installed: installed, deviceID: deviceID, cables: cables)
        case (.none, .none):
            return TemplatePortMigrationImpact(templatePortID: templatePortID, action: .retain, requiresCableReview: false)
        }
    }

    private static func installedPort(_ templatePortID: ObjectID, installed: [ObjectID: Port], deviceID: ObjectID) throws -> Port {
        guard let current = installed[templatePortID] else { throw TemplateValidationError.incompatibleMigration(deviceID) }
        return current
    }

    private static func reconfigurationImpact(
        templatePortID: ObjectID, source: PortTemplate, target: PortTemplate, installed: [ObjectID: Port], deviceID: ObjectID, cables: [Cable]
    ) throws -> TemplatePortMigrationImpact {
        let current = try installedPort(templatePortID, installed: installed, deviceID: deviceID)
        let desired = try materializedPort(id: current.id, deviceID: deviceID, template: target, customFields: current.customFields)
        let changed = source != target || current != desired
        return TemplatePortMigrationImpact(
            templatePortID: templatePortID, action: changed ? .reconfigure : .retain, requiresCableReview: changed, currentPort: current, desiredPort: desired,
            connectedCableIDs: changed ? connectedCableIDs(for: current.id, in: cables) : [])
    }

    /// Compatibility for portless templates only. A caller must provide exact
    /// installed ports and cable state for every migration that has ports.
    public static func plan(device: Device, target: DeviceType) throws -> DeviceTemplateMigrationPlan {
        guard device.templateSnapshot?.portTemplates.isEmpty == true, target.portTemplates.isEmpty else {
            throw TemplateValidationError.incompatibleMigration(device.id)
        }
        return try plan(device: device, installedPorts: [], cables: [], target: target, newPortIDs: [:])
    }

    public static func apply(_ plan: DeviceTemplateMigrationPlan, to device: inout Device) throws {
        guard device.id == plan.deviceID, device.templateSnapshot == plan.sourceSnapshot else { throw TemplateValidationError.incompatibleMigration(device.id) }
        device.templateSnapshot = plan.targetSnapshot
        device.typeID = plan.targetSnapshot.templateID
    }

    private static func materializedPort(
        id: ObjectID, deviceID: ObjectID, template: PortTemplate,
        customFields: [CustomFieldValue]
    ) throws -> Port {
        Port(
            id: id, deviceID: deviceID, templatePortID: template.id, label: template.name,
            medium: template.medium, connector: template.connector, face: template.face,
            fiberMode: template.fiberMode,
            customFields: try CustomFieldValidator.resolvedValues(values: customFields, against: template.customFieldSchemas)
        )
    }

    private static func connectedCableIDs(for portID: ObjectID, in cables: [Cable]) -> [ObjectID] {
        cables.filter { $0.endpointA == portID || $0.endpointB == portID }.map(\.id).sorted()
    }
}
