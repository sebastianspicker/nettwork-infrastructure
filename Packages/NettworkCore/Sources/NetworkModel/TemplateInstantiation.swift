import Foundation

public enum TemplateInstantiator {
    /// Revalidates an already-materialized installation against the current
    /// catalog. Production planning uses this before accepting a typed install
    /// operation, so a caller cannot handcraft modules or ports around the UI.
    public static func validate(
        _ installation: DeviceInstantiation, against template: DeviceType,
        moduleTemplates: [ModuleTemplate]
    ) throws {
        try TemplateCatalog.validate(deviceTemplate: template, moduleTemplates: moduleTemplates)
        try validateDevice(installation.device, against: template)
        let knownModules = Dictionary(uniqueKeysWithValues: moduleTemplates.map { ($0.id, $0) })
        try validateCatalogSlots(template.moduleSlots, knownModules: knownModules, templateID: template.id)
        let slots = Dictionary(uniqueKeysWithValues: template.moduleSlots.map { ($0.key, $0) })
        try validateModules(installation.modules, deviceID: installation.device.id, slots: slots, templates: knownModules, requiredSlots: template.moduleSlots)
        let modulesByID = Dictionary(uniqueKeysWithValues: installation.modules.map { ($0.id, $0) })
        try validatePortOwners(installation.ports, deviceID: installation.device.id, modules: modulesByID)
        let directTemplates = Dictionary(uniqueKeysWithValues: template.portTemplates.map { ($0.id, $0) })
        try validatePorts(installation.ports.filter { $0.moduleID == nil }, definitions: directTemplates, errorID: installation.device.id)
        try validateModulePorts(installation, templates: knownModules)
    }

    private static func validateDevice(_ device: Device, against template: DeviceType) throws {
        guard device.typeID == template.id, device.templateSnapshot == DeviceTemplateSnapshot(template: template) else {
            throw TemplateValidationError.incompatibleMigration(device.id)
        }
    }

    private static func validateCatalogSlots(_ slots: [ModuleSlotTemplate], knownModules: [ObjectID: ModuleTemplate], templateID: ObjectID) throws {
        guard slots.allSatisfy({ $0.allowedModuleTemplateIDs.allSatisfy { knownModules[$0] != nil } }) else {
            throw TemplateValidationError.disallowedModule(slot: "catalog", templateID: templateID)
        }
    }

    private static func validateModules(
        _ modules: [Module], deviceID: ObjectID, slots: [String: ModuleSlotTemplate], templates: [ObjectID: ModuleTemplate], requiredSlots: [ModuleSlotTemplate]
    ) throws {
        var installedSlots = Set<String>()
        for module in modules { try validate(module: module, deviceID: deviceID, slots: slots, templates: templates, installedSlots: &installedSlots) }
        for slot in requiredSlots where slot.isRequired && !installedSlots.contains(slot.key) { throw TemplateValidationError.missingRequiredSlot(slot.key) }
    }

    private static func validate(
        module: Module, deviceID: ObjectID, slots: [String: ModuleSlotTemplate], templates: [ObjectID: ModuleTemplate], installedSlots: inout Set<String>
    ) throws {
        guard module.deviceID == deviceID, installedSlots.insert(module.slot).inserted,
            let slot = slots[module.slot], slot.allowedModuleTemplateIDs.contains(module.templateID),
            let template = templates[module.templateID],
            module.templateSnapshot == ModuleTemplateSnapshot(template: template)
        else {
            throw TemplateValidationError.disallowedModule(slot: module.slot, templateID: module.templateID)
        }
    }

    private static func validatePortOwners(_ ports: [Port], deviceID: ObjectID, modules: [ObjectID: Module]) throws {
        for port in ports {
            guard port.deviceID == deviceID else { throw TemplateValidationError.incompatibleMigration(deviceID) }
            if let moduleID = port.moduleID, modules[moduleID] == nil { throw TemplateValidationError.missingInstantiationID(moduleID) }
        }
    }

    private static func validateModulePorts(_ installation: DeviceInstantiation, templates: [ObjectID: ModuleTemplate]) throws {
        for module in installation.modules {
            guard let template = templates[module.templateID] else { throw TemplateValidationError.incompatibleMigration(module.id) }
            let definitions = Dictionary(uniqueKeysWithValues: template.ports.map { ($0.id, $0) })
            try validatePorts(installation.ports.filter { $0.moduleID == module.id }, definitions: definitions, errorID: module.id)
        }
    }

    private static func validatePorts(_ ports: [Port], definitions: [ObjectID: PortTemplate], errorID: ObjectID) throws {
        guard ports.count == definitions.count,
            Set(ports.compactMap(\.templatePortID)) == Set(definitions.keys),
            ports.allSatisfy({ port in port.templatePortID.flatMap { definitions[$0] }.map { portMatchesTemplate(port, $0) } ?? false })
        else {
            throw TemplateValidationError.incompatibleMigration(errorID)
        }
    }

    public static func instantiate(template: DeviceType, request: DeviceInstantiationRequest) throws -> DeviceInstantiation {
        try TemplateCatalog.validate(deviceTemplate: template, moduleTemplates: Array(request.modulesBySlot.values))
        let slots = Dictionary(uniqueKeysWithValues: template.moduleSlots.map { ($0.key, $0) })
        try validate(request: request, slots: slots, requiredSlots: template.moduleSlots)
        var producedIDs = Set<ObjectID>([request.deviceID])
        let device = try instantiateDevice(template: template, request: request)
        var ports = try instantiatePorts(
            template.portTemplates, deviceID: device.id, moduleID: nil, ids: request.portIDsByTemplateID, customFields: request.portCustomFieldsByTemplateID,
            producedIDs: &producedIDs)
        let modules = try instantiateModules(template: template, request: request, deviceID: device.id, ports: &ports, producedIDs: &producedIDs)
        return DeviceInstantiation(device: device, modules: modules, ports: ports)
    }

    private static func validate(request: DeviceInstantiationRequest, slots: [String: ModuleSlotTemplate], requiredSlots: [ModuleSlotTemplate]) throws {
        for (slot, module) in request.modulesBySlot {
            guard let definition = slots[slot] else { throw TemplateValidationError.unknownSlot(slot) }
            guard definition.allowedModuleTemplateIDs.contains(module.id) else {
                throw TemplateValidationError.disallowedModule(slot: slot, templateID: module.id)
            }
        }
        for slot in requiredSlots where slot.isRequired && request.modulesBySlot[slot.key] == nil {
            throw TemplateValidationError.missingRequiredSlot(slot.key)
        }
    }

    private static func instantiateDevice(template: DeviceType, request: DeviceInstantiationRequest) throws -> Device {
        Device(
            id: request.deviceID, assetCode: request.assetCode, name: request.name, typeID: template.id, rackID: request.rackID,
            customFields: try CustomFieldValidator.resolvedValues(
                values: request.customFields,
                against: template.customFieldSchemas), templateSnapshot: DeviceTemplateSnapshot(template: template))
    }

    private static func instantiateModules(
        template: DeviceType, request: DeviceInstantiationRequest, deviceID: ObjectID, ports: inout [Port], producedIDs: inout Set<ObjectID>
    ) throws -> [Module] {
        var modules = [Module]()
        for slot in template.moduleSlots.sorted(by: { $0.key < $1.key }) {
            guard let moduleTemplate = request.modulesBySlot[slot.key] else { continue }
            let module = try instantiateModule(moduleTemplate, slot: slot, request: request, deviceID: deviceID, producedIDs: &producedIDs)
            modules.append(module)
            ports.append(
                contentsOf: try instantiatePorts(
                    moduleTemplate.ports, deviceID: deviceID, moduleID: module.id, ids: request.portIDsByTemplateID,
                    customFields: request.portCustomFieldsByTemplateID, producedIDs: &producedIDs))
        }
        return modules
    }

    private static func instantiateModule(
        _ template: ModuleTemplate, slot: ModuleSlotTemplate, request: DeviceInstantiationRequest, deviceID: ObjectID, producedIDs: inout Set<ObjectID>
    ) throws -> Module {
        guard let id = request.moduleIDsBySlot[slot.key] else { throw TemplateValidationError.missingInstantiationID(template.id) }
        guard producedIDs.insert(id).inserted else { throw TemplateValidationError.duplicateInstantiationID(id) }
        return Module(
            id: id, deviceID: deviceID, templateID: template.id, slot: slot.key, templateSnapshot: ModuleTemplateSnapshot(template: template),
            customFields: try CustomFieldValidator.resolvedValues(
                values: request.moduleCustomFieldsBySlot[slot.key] ?? [], against: template.customFieldSchemas))
    }

    private static func instantiatePorts(
        _ templates: [PortTemplate], deviceID: ObjectID, moduleID: ObjectID?, ids: [ObjectID: ObjectID], customFields: [ObjectID: [CustomFieldValue]],
        producedIDs: inout Set<ObjectID>
    ) throws -> [Port] {
        try templates.sorted { lhs, rhs in
            if lhs.face != rhs.face { return lhs.face.rawValue < rhs.face.rawValue }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }.map { template in
            guard let portID = ids[template.id] else { throw TemplateValidationError.missingInstantiationID(template.id) }
            guard producedIDs.insert(portID).inserted else { throw TemplateValidationError.duplicateInstantiationID(portID) }
            return Port(
                id: portID, deviceID: deviceID, moduleID: moduleID, templatePortID: template.id, label: template.name, medium: template.medium,
                connector: template.connector, face: template.face,
                fiberMode: template.fiberMode,
                customFields: try CustomFieldValidator.resolvedValues(values: customFields[template.id] ?? [], against: template.customFieldSchemas))
        }
    }

    private static func portMatchesTemplate(_ port: Port, _ template: PortTemplate) -> Bool {
        port.label == template.name && port.medium == template.medium && port.connector == template.connector && port.face == template.face
            && port.fiberMode == template.fiberMode
    }
}
